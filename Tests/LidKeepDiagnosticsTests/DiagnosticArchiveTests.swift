import XCTest
import Darwin
import Dispatch
import LidKeepCore
@testable import LidKeepDiagnostics

final class DiagnosticArchiveTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("Diagnostics") }
    private let mib: UInt64 = 1_048_576

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("lidkeep-archive-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func snapshot(at: Date, processes: [ProcessSample] = [], warnings: [String] = []) -> ResourceSnapshot {
        ResourceSnapshot(timestamp: at, uptime: at.timeIntervalSince1970,
                         context: DiagnosticContext(lidClosed: true, thermal: .nominal, batteryPercent: 40,
                                                    onAC: false, sleepDisabled: true, mode: "active",
                                                    reason: "保持电脑运行", statusFresh: true),
                         totalMemoryBytes: 32 * 1024 * mib, freeMemoryBytes: 4 * 1024 * mib,
                         compressedBytes: 512 * mib, swapUsedBytes: 128 * mib,
                         memoryPressure: "normal", systemCPUPercent: 123, loadAverage: 2.4,
                         processCount: 100, unreadableProcessCount: 1, processListTruncated: false,
                         processes: processes, collectionSeconds: 0.02, warnings: warnings)
    }

    private func names(_ suffix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(suffix) }
    }

    private func headers() throws -> [DiagnosticSession] {
        struct Header: Decodable { let session: DiagnosticSession }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try names(".jsonl").map { name in
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let first = try XCTUnwrap(data.split(separator: 0x0a).first)
            return try decoder.decode(Header.self, from: Data(first)).session
        }
    }

    private func save(_ archive: DiagnosticArchive, kind: String = "manual", at: Date,
                      event: DiagnosticEventKind? = nil) throws -> URL {
        try archive.begin(kind: kind, at: at, event: event)
        try archive.append(snapshot(at: at))
        return try XCTUnwrap(archive.finish(reason: "完成", at: at))
    }

    func testReportDoesNotMergeReusedPIDAndShowsGapsAndGrowth() throws {
        let archive = try DiagnosticArchive(directory: directory)
        let now = Date()
        try archive.begin(kind: "lid", at: now)
        try archive.append(snapshot(at: now, processes: [ProcessSample(pid: 42, startTime: 100, name: "worker", residentBytes: 10 * mib)]))
        try archive.append(snapshot(at: now.addingTimeInterval(30), processes: [ProcessSample(pid: 42, startTime: 100, name: "worker", residentBytes: 30 * mib, cpuPercent: 250)]))
        try archive.append(snapshot(at: now.addingTimeInterval(150), processes: [ProcessSample(pid: 42, startTime: 200, name: "new-worker", residentBytes: 5 * mib, cpuPercent: 1)]))
        let report = try XCTUnwrap(archive.finish(reason: "开盖", at: now.addingTimeInterval(150)))
        let text = try String(contentsOf: report, encoding: .utf8)
        XCTAssertTrue(text.contains("42 / 100"))
        XCTAssertTrue(text.contains("42 / 200"))
        XCTAssertTrue(text.contains("+20.0 MiB"))
        XCTAssertTrue(text.contains("250.0%"))
        XCTAssertTrue(text.contains("120 秒无采样"))
        XCTAssertTrue(text.contains("20.0%"))
        XCTAssertTrue(text.contains("共享页"))
        XCTAssertTrue(text.contains("不能证明泄漏"))
        XCTAssertEqual(archive.latestReportURL(), report)
        let attributes = try FileManager.default.attributesOfItem(atPath: report.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((dirAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testCurrentReportKeepsRecordingAndStartupMarksInterruption() throws {
        let now = Date()
        var archive: DiagnosticArchive? = try DiagnosticArchive(directory: directory)
        try archive!.begin(kind: "lid", at: now)
        try archive!.append(snapshot(at: now))
        let report = try XCTUnwrap(archive!.currentReport())
        XCTAssertTrue(try String(contentsOf: report, encoding: .utf8).contains("仍在采集"))
        try archive!.append(snapshot(at: now.addingTimeInterval(30)))
        archive = nil
        let recovered = try DiagnosticArchive(directory: directory)
        let recoveredURL = try XCTUnwrap(recovered.latestReportURL())
        let text = try String(contentsOf: recoveredURL, encoding: .utf8)
        XCTAssertTrue(text.contains("采集中断"))
        XCTAssertTrue(text.contains("样本数：2"))
        XCTAssertTrue(text.contains("中断时长未知"))
        try recovered.begin(kind: "manual")
        try recovered.append(snapshot(at: Date()))
        XCTAssertNotNil(try recovered.finish(reason: "检查完成"))
    }

    func testSampleLimitRotatesAndContinuesWithSequenceAndPreviousSession() throws {
        let archive = try DiagnosticArchive(directory: directory)
        let now = Date()
        try archive.begin(kind: "系统休眠事件", at: now, event: .sleep)
        for index in 0...DiagnosticArchive.sampleLimit {
            try archive.append(snapshot(at: now.addingTimeInterval(Double(index) * 30)))
        }
        XCTAssertEqual(try names(".jsonl").count, 2)
        XCTAssertTrue(try headers().allSatisfy { $0.event == .sleep }, "Continuation segments retain event classification")
        let report = try XCTUnwrap(archive.currentReport())
        let text = try String(contentsOf: report, encoding: .utf8)
        XCTAssertTrue(text.contains("第 2 段"))
        XCTAssertTrue(text.contains("续接会话"))
        XCTAssertTrue(text.contains("达到 720 次采样上限"))
        XCTAssertTrue(text.contains("样本数：1"))
    }

    func testSessionCountAndAgeRetention() throws {
        let archive = try DiagnosticArchive(directory: directory)
        let now = Date()
        for index in 0..<22 {
            let at = now.addingTimeInterval(Double(index))
            try archive.begin(kind: "manual", at: at)
            try archive.append(snapshot(at: at))
            _ = try archive.finish(reason: "完成", at: at)
        }
        XCTAssertEqual(try names(".jsonl").count, DiagnosticArchive.sessionLimit)
        XCTAssertEqual(try names(".md").count, DiagnosticArchive.sessionLimit)
        try archive.begin(kind: "manual", at: now.addingTimeInterval(DiagnosticArchive.retention + 100))
        XCTAssertEqual(try names(".jsonl").count, 1)
        XCTAssertEqual(try names(".md").count, 0)
    }

    func testWakeDoesNotHideLatestUsefulReportAcrossRestartButNewSleepTakesPriority() throws {
        var archive: DiagnosticArchive? = try DiagnosticArchive(directory: directory)
        let now = Date()
        let manual = try save(archive!, at: now)
        let wake = try save(archive!, kind: "系统唤醒事件", at: now.addingTimeInterval(1), event: .wake)
        XCTAssertNotEqual(wake, manual)
        XCTAssertEqual(archive!.latestReportURL(), manual)
        XCTAssertEqual(try archive!.currentReport(), manual)
        archive = nil
        archive = try DiagnosticArchive(directory: directory)
        XCTAssertEqual(archive!.latestReportURL(), manual)
        let sleep = try save(archive!, kind: "系统休眠事件", at: now.addingTimeInterval(2), event: .sleep)
        _ = try save(archive!, kind: "系统唤醒事件", at: now.addingTimeInterval(3), event: .wake)
        XCTAssertEqual(archive!.latestReportURL(), sleep, "A newer sleep event must not be hidden by an older full report")
        archive = nil
        let recovered = try DiagnosticArchive(directory: directory)
        XCTAssertEqual(recovered.latestReportURL(), sleep)
        XCTAssertEqual(try recovered.currentReport(), sleep)
    }

    func testWakeIsAvailableWhenNoOtherReportExistsIncludingAfterRestart() throws {
        var archive: DiagnosticArchive? = try DiagnosticArchive(directory: directory)
        let wake = try save(archive!, kind: "系统唤醒事件", at: Date(), event: .wake)
        XCTAssertEqual(archive!.latestReportURL(), wake)
        archive = nil
        let recovered = try DiagnosticArchive(directory: directory)
        XCTAssertEqual(try recovered.currentReport(), wake)
    }

    func testEventsHaveSeparateEightSegmentQuotaAndCannotEvictTwentyNormalSessions() throws {
        let archive = try DiagnosticArchive(directory: directory)
        let now = Date()
        var normalIDs: Set<String> = []
        for index in 0..<DiagnosticArchive.sessionLimit {
            normalIDs.insert(try save(archive, at: now.addingTimeInterval(Double(index))).deletingPathExtension().lastPathComponent)
        }
        for index in 0..<12 {
            _ = try save(archive, kind: "系统事件", at: now.addingTimeInterval(Double(30 + index)),
                         event: index.isMultiple(of: 2) ? .sleep : .wake)
        }
        let stored = try headers()
        XCTAssertEqual(Set(stored.filter { $0.event == nil }.map(\.id)), normalIDs)
        XCTAssertEqual(stored.filter { $0.event != nil }.count, DiagnosticArchive.eventLimit)
        XCTAssertEqual(stored.count, DiagnosticArchive.sessionLimit + DiagnosticArchive.eventLimit)
        try archive.begin(kind: "manual", at: now.addingTimeInterval(DiagnosticArchive.retention + 100))
        XCTAssertEqual(try headers().count, 1, "Both categories retain the same seven-day boundary")
    }

    func testBytePressureDeletesNewerEventBeforeOlderNormalSessions() throws {
        let archive = try DiagnosticArchive(directory: directory)
        let now = Date()
        var normalIDs: Set<String> = []
        for index in 0..<4 {
            let report = try save(archive, at: now.addingTimeInterval(Double(index)))
            normalIDs.insert(report.deletingPathExtension().lastPathComponent)
            let record = report.deletingPathExtension().appendingPathExtension("jsonl")
            let originalSize = try Data(contentsOf: record).count
            let handle = try FileHandle(forWritingTo: record)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0x20, count: 6_815_744 - originalSize)) // 6.5 MiB
            try handle.close()
            try Data(repeating: 0x20, count: 1_048_576).write(to: report)
            XCTAssertEqual(chmod(report.path, 0o600), 0)
        }
        let event = try save(archive, kind: "系统唤醒事件", at: now.addingTimeInterval(10), event: .wake)
        let eventRecord = event.deletingPathExtension().appendingPathExtension("jsonl")
        let eventBytes = try Data(contentsOf: eventRecord).count
        try Data(repeating: 0x20, count: 2_097_152 - eventBytes).write(to: event)
        XCTAssertEqual(chmod(event.path, 0o600), 0) // Now exactly 32 MiB across four normal sessions and one event.
        try archive.begin(kind: "manual", at: now.addingTimeInterval(11))
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventRecord.path))
        let stored = try headers()
        XCTAssertTrue(normalIDs.isSubset(of: Set(stored.map(\.id))))
        XCTAssertEqual(stored.count, 5)
    }

    func testLegacySessionWithoutEventFieldRemainsReadableAndPreferredToWake() throws {
        var archive: DiagnosticArchive? = try DiagnosticArchive(directory: directory)
        let now = Date()
        let manual = try save(archive!, at: now)
        archive = nil
        let record = manual.deletingPathExtension().appendingPathExtension("jsonl")
        var lines = try Data(contentsOf: record).split(separator: 0x0a).map { Data($0) }
        var first = try XCTUnwrap(JSONSerialization.jsonObject(with: lines[0]) as? [String: Any])
        var session = try XCTUnwrap(first["session"] as? [String: Any])
        session.removeValue(forKey: "event")
        first["session"] = session
        lines[0] = try JSONSerialization.data(withJSONObject: first)
        var oldData = Data()
        for line in lines { oldData.append(line); oldData.append(0x0a) }
        try oldData.write(to: record)
        XCTAssertEqual(chmod(record.path, 0o600), 0)
        let recovered = try DiagnosticArchive(directory: directory)
        XCTAssertNil(try XCTUnwrap(headers().first).event)
        _ = try save(recovered, kind: "系统唤醒事件", at: now.addingTimeInterval(1), event: .wake)
        XCTAssertEqual(recovered.latestReportURL(), manual)
    }

    func testTotalDiskRetentionIncludesReportsAndNewActiveSession() throws {
        let now = Date()
        // Valid finished records with large, bounded report files exercise pruning
        // without collecting a real machine workload or thousands of samples.
        let archive = try DiagnosticArchive(directory: directory)
        for index in 0..<5 {
            let at = now.addingTimeInterval(Double(index))
            try archive.begin(kind: "manual", at: at)
            try archive.append(snapshot(at: at))
            let report = try XCTUnwrap(archive.finish(reason: "完成", at: at))
            let record = report.deletingPathExtension().appendingPathExtension("jsonl")
            let handle = try FileHandle(forWritingTo: record)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0x20, count: 6 * 1024 * 1024))
            try handle.close()
            // 1 MiB report + 6 MiB record, both counted in the global quota.
            try Data(repeating: 0x20, count: 1024 * 1024).write(to: report)
            XCTAssertEqual(chmod(report.path, 0o600), 0)
        }
        try archive.begin(kind: "manual", at: now.addingTimeInterval(10))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { total, file in total + (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, DiagnosticArchive.totalByteLimit)
        XCTAssertLessThan(try names(".jsonl").count, 6)
    }

    func testRecoverySkipsSessionPrunedWhileCreatingEarlierReportAtCapacity() throws {
        _ = try DiagnosticArchive(directory: directory)
        struct Header: Encodable { let session: DiagnosticSession }
        struct Sample: Encodable { let snapshot: ResourceSnapshot }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let now = Date().addingTimeInterval(-60)
        var identifiers: [String] = []
        // Sixteen interrupted segments total exactly 32 MiB. Replacing the
        // oldest report needs temporary space and removes the next segment.
        for index in 0..<16 {
            let id = UUID().uuidString.lowercased()
            identifiers.append(id)
            let at = now.addingTimeInterval(Double(index))
            let session = DiagnosticSession(id: id, kind: "lid", startedAt: at, segment: 1,
                                            previousID: nil, continuationReason: nil)
            var record = try encoder.encode(Header(session: session))
            record.append(0x0a)
            record.append(try encoder.encode(Sample(snapshot: snapshot(at: at))))
            record.append(0x0a)
            let recordURL = directory.appendingPathComponent(id + ".jsonl")
            let reportURL = directory.appendingPathComponent(id + ".md")
            try record.write(to: recordURL)
            try Data(repeating: 0x20, count: 2 * 1024 * 1024 - record.count).write(to: reportURL)
            XCTAssertEqual(chmod(recordURL.path, 0o600), 0)
            XCTAssertEqual(chmod(reportURL.path, 0o600), 0)
        }
        let recovered = try DiagnosticArchive(directory: directory)
        XCTAssertNotNil(recovered.latestReportURL())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(identifiers[1] + ".jsonl").path))
        XCTAssertEqual(try names(".jsonl").count, 15)
        try recovered.begin(kind: "manual")
        try recovered.append(snapshot(at: Date()))
        XCTAssertNotNil(try recovered.finish(reason: "恢复后检查完成"))
    }

    func testMeasureAppendCostWithMaximumRetainedSessions() throws {
        let archive = try DiagnosticArchive(directory: directory)
        let now = Date()
        for index in 0..<20 {
            let at = now.addingTimeInterval(Double(index))
            try archive.begin(kind: "manual", at: at)
            try archive.append(snapshot(at: at))
            _ = try archive.finish(reason: "完成", at: at)
        }
        try archive.begin(kind: "lid", at: now.addingTimeInterval(21))
        var before = rusage(), after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        var elapsed: [Double] = []
        for index in 0..<40 {
            let sample = snapshot(at: now.addingTimeInterval(30 + Double(index) * 30))
            let start = DispatchTime.now().uptimeNanoseconds
            try archive.append(sample)
            elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        func cpu(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
        }
        elapsed.sort()
        print(String(format: "ARCHIVE_APPEND_BENCHMARK samples=40 sessions=20 p50_ms=%.3f p95_ms=%.3f max_ms=%.3f total_cpu_ms=%.3f",
                     elapsed[20], elapsed[38], elapsed[39], cpu(after) - cpu(before)))
        XCTAssertEqual(try names(".jsonl").count, DiagnosticArchive.sessionLimit)
    }

    func testOversizedSnapshotIsRejectedWithoutAppendingPartialLine() throws {
        let archive = try DiagnosticArchive(directory: directory)
        try archive.begin(kind: "manual")
        let record = directory.appendingPathComponent(try XCTUnwrap(names(".jsonl").first))
        let before = try Data(contentsOf: record)
        XCTAssertThrowsError(try archive.append(snapshot(at: Date(), warnings: [String(repeating: "x", count: DiagnosticArchive.lineLimit)])))
        XCTAssertEqual(try Data(contentsOf: record), before)
        try archive.append(snapshot(at: Date()))
        XCTAssertNotNil(try archive.finish(reason: "完成"))
    }

    func testUnsafeDirectoriesLinksAndFileWritesAreRejected() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let linked = root.appendingPathComponent("linked")
        XCTAssertEqual(symlink(outside.path, linked.path), 0)
        XCTAssertThrowsError(try DiagnosticArchive(directory: linked))
        XCTAssertThrowsError(try DiagnosticArchive(directory: linked.appendingPathComponent("nested")))
        XCTAssertThrowsError(try DiagnosticArchive(directory: URL(string: "https://example.invalid/Diagnostics")!))
        XCTAssertEqual(chmod(outside.path, 0o755), 0)
        XCTAssertThrowsError(try DiagnosticArchive(directory: outside))

        let archive = try DiagnosticArchive(directory: directory)
        try archive.begin(kind: "manual")
        let record = directory.appendingPathComponent(try XCTUnwrap(names(".jsonl").first))
        XCTAssertEqual(chmod(record.path, 0o400), 0)
        XCTAssertThrowsError(try archive.append(snapshot(at: Date())))
        XCTAssertEqual(chmod(record.path, 0o600), 0)
        let linkedRecord = root.appendingPathComponent("linked-record")
        XCTAssertEqual(link(record.path, linkedRecord.path), 0)
        XCTAssertThrowsError(try archive.append(snapshot(at: Date())))
        XCTAssertEqual(unlink(linkedRecord.path), 0)
        try FileManager.default.removeItem(at: record)
        XCTAssertEqual(symlink(outside.path, record.path), 0)
        XCTAssertThrowsError(try archive.append(snapshot(at: Date())))
    }

    func testInterruptedPartialLastLineIsReportedWithoutInventingSamples() throws {
        var archive: DiagnosticArchive? = try DiagnosticArchive(directory: directory)
        try archive!.begin(kind: "lid")
        try archive!.append(snapshot(at: Date()))
        let record = directory.appendingPathComponent(try XCTUnwrap(names(".jsonl").first))
        archive = nil
        let handle = try FileHandle(forWritingTo: record)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"snapshot\":".utf8))
        try handle.close()
        let recovered = try DiagnosticArchive(directory: directory)
        let report = try XCTUnwrap(recovered.latestReportURL())
        let text = try String(contentsOf: report, encoding: .utf8)
        XCTAssertTrue(text.contains("采集中断"))
        XCTAssertTrue(text.contains("未完成或无效记录"))
        XCTAssertTrue(text.contains("样本数：1"))
    }

    func testRecoveryCleansPrivateTemporaryAndOrphanReportsButPreservesUnknownFiles() throws {
        _ = try DiagnosticArchive(directory: directory)
        for suffix in [".tmp", ".md"] {
            let file = directory.appendingPathComponent(UUID().uuidString.lowercased() + suffix)
            try Data("unfinished".utf8).write(to: file)
            XCTAssertEqual(chmod(file.path, 0o600), 0)
        }
        _ = try DiagnosticArchive(directory: directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["archive.lock"])
        let finderMetadata = directory.appendingPathComponent(".DS_Store")
        try Data("Finder metadata".utf8).write(to: finderMetadata)
        do {
            let archive = try DiagnosticArchive(directory: directory)
            try archive.begin(kind: "manual")
            try archive.append(snapshot(at: Date()))
            XCTAssertNotNil(try archive.finish(reason: "完成"))
        }
        XCTAssertEqual(try String(contentsOf: finderMetadata, encoding: .utf8), "Finder metadata")
        let unknown = directory.appendingPathComponent("my-notes.txt")
        try Data("retain me".utf8).write(to: unknown)
        XCTAssertEqual(chmod(unknown.path, 0o600), 0)
        XCTAssertThrowsError(try DiagnosticArchive(directory: directory))
        XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "retain me")
    }

    func testSecondInstanceIsRejectedBeforeTouchingActiveFilesAndReleaseAllowsRecovery() throws {
        var archive: DiagnosticArchive? = try DiagnosticArchive(directory: directory)
        try archive!.begin(kind: "lid")
        try archive!.append(snapshot(at: Date()))
        let record = directory.appendingPathComponent(try XCTUnwrap(names(".jsonl").first))
        let before = try Data(contentsOf: record)
        let temporary = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".tmp")
        try Data("in-flight report".utf8).write(to: temporary)
        XCTAssertEqual(chmod(temporary.path, 0o600), 0)
        let started = Date()
        XCTAssertThrowsError(try DiagnosticArchive(directory: directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("另一个诊断实例正在使用该目录"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(try Data(contentsOf: record), before)
        XCTAssertEqual(try names(".md").count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
        archive = nil
        let recovered = try DiagnosticArchive(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        let report = try XCTUnwrap(recovered.latestReportURL())
        XCTAssertTrue(try String(contentsOf: report, encoding: .utf8).contains("采集中断"))
    }

    func testFailedInitializationReleasesLockAndUnsafeLocksAreRejected() throws {
        _ = try DiagnosticArchive(directory: directory)
        let unknown = directory.appendingPathComponent("unexpected.txt")
        try Data().write(to: unknown)
        XCTAssertThrowsError(try DiagnosticArchive(directory: directory))
        try FileManager.default.removeItem(at: unknown)
        _ = try DiagnosticArchive(directory: directory)
        let lock = directory.appendingPathComponent("archive.lock")
        XCTAssertEqual(chmod(lock.path, 0o644), 0)
        XCTAssertThrowsError(try DiagnosticArchive(directory: directory))
        XCTAssertEqual(chmod(lock.path, 0o600), 0)
        let alias = root.appendingPathComponent("lock-alias")
        XCTAssertEqual(link(lock.path, alias.path), 0)
        XCTAssertThrowsError(try DiagnosticArchive(directory: directory))
        XCTAssertEqual(unlink(alias.path), 0)
        try FileManager.default.removeItem(at: lock)
        XCTAssertEqual(symlink("/dev/null", lock.path), 0)
        XCTAssertThrowsError(try DiagnosticArchive(directory: directory))
    }

    func testOwnProcessRemainsVisibleOutsideTopTwenty() {
        let now = Date()
        let others = (1...25).map { ProcessSample(pid: Int32($0), startTime: 1, name: "heavy-\($0)", residentBytes: 100 * mib) }
        let own = ProcessSample(pid: 1000, startTime: 2, name: "LidKeep", residentBytes: 2 * mib)
        let text = DiagnosticReport.render(session: DiagnosticSession(id: UUID().uuidString, kind: "manual", startedAt: now,
                                                                      segment: 1, previousID: nil, continuationReason: nil),
                                           snapshots: [snapshot(at: now, processes: others + [own])],
                                           ending: DiagnosticEnding(at: now, reason: "完成"), recording: false, interrupted: false, damaged: false)
        XCTAssertTrue(text.contains("LidKeep（PID 1000 / 2）"))
        XCTAssertTrue(text.contains("不能将 App 一行当作三个进程的总和"))
    }
}

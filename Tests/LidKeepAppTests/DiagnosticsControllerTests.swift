import XCTest
import AppKit
import LidKeepCore
import LidKeepDiagnostics
@testable import LidKeepApp

final class DiagnosticsControllerTests: XCTestCase {
    private final class Simulation {
        var lid: Bool? = false
        var date = Date()
        var uptime = 100.0
        var attempts = 0
        var failSampling = false
        func advance(_ seconds: Double) { date.addTimeInterval(seconds); uptime += seconds }
        func sample(_ context: DiagnosticContext) throws -> ResourceSnapshot {
            attempts += 1
            if failSampling { throw NSError(domain: "InjectedDiagnosticFailure", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟采样失败"]) }
            return ResourceSnapshot(timestamp: date, uptime: uptime, context: context,
                                    totalMemoryBytes: 32 * 1024 * 1024 * 1024, freeMemoryBytes: 8 * 1024 * 1024 * 1024,
                                    compressedBytes: 0, swapUsedBytes: 0, memoryPressure: "normal",
                                    systemCPUPercent: attempts > 1 ? 12 : nil, loadAverage: 1,
                                    processCount: 1, unreadableProcessCount: 0, processListTruncated: false,
                                    processes: [ProcessSample(pid: 123, startTime: 456, name: "test-worker", residentBytes: 1_048_576)],
                                    collectionSeconds: 0.001, warnings: [])
        }
    }
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var center: NotificationCenter!
    private var simulation: Simulation!
    private var controller: DiagnosticsController?
    private var states: [DiagnosticUIState] = []

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("lidkeep-controller-tests-" + UUID().uuidString)
        suite = "local.rl.lidkeep.controller-tests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        center = NotificationCenter()
        simulation = Simulation()
    }
    override func tearDownWithError() throws {
        controller?.queue.sync {}
        controller = nil
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func start() {
        let environment = simulation!
        controller = DiagnosticsController(directory: directory, defaults: defaults, notificationCenter: center,
                                           lidReading: { environment.lid }, thermalReading: { .nominal }, wallClock: { environment.date },
                                           uptime: { environment.uptime }, collect: { try environment.sample($0) }, startTimer: false)
        controller?.onChange = { [weak self] state in self?.states.append(state) }
        controller?.start()
        drain()
    }
    private func drain() {
        controller?.queue.sync {}
        let drained = expectation(description: "Main queue receives state updates")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }
    private func tick() {
        controller?.queue.sync { controller?.tick() }
        drain()
    }
    private func records() throws -> [[[String: Any]]] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        return try urls.map { url in
            try Data(contentsOf: url).split(separator: 0x0a).map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
            }
        }
    }
    private func sampleCount() throws -> Int { try records().flatMap { $0 }.filter { $0["snapshot"] != nil }.count }

    func testClosedLidStartsThenSamplesAtThirtySecondsAndOpenLidFinishes() throws {
        start()
        tick()
        XCTAssertFalse(try XCTUnwrap(states.last).recording)
        XCTAssertEqual(simulation.attempts, 0)
        simulation.lid = true
        tick()
        XCTAssertTrue(try XCTUnwrap(states.last).recording)
        XCTAssertEqual(try sampleCount(), 1)
        simulation.advance(29)
        tick()
        XCTAssertEqual(try sampleCount(), 1)
        simulation.advance(1)
        tick()
        XCTAssertEqual(try sampleCount(), 2)
        simulation.lid = false
        simulation.advance(5)
        tick()
        XCTAssertFalse(try XCTUnwrap(states.last).recording)
        XCTAssertEqual(try sampleCount(), 3)
        let session = try XCTUnwrap(records().first)
        XCTAssertEqual((session.first?["session"] as? [String: Any])?["kind"] as? String, "自动合盖记录")
        XCTAssertEqual((session.last?["ending"] as? [String: Any])?["reason"] as? String, "已开盖")
    }

    func testDisabledPreferencePersistsAndClosedLidDoesNotRestartRecording() throws {
        simulation.lid = true
        start()
        tick()
        controller?.setEnabled(false)
        drain()
        XCTAssertFalse(try XCTUnwrap(states.last).enabled)
        XCTAssertFalse(try XCTUnwrap(states.last).recording)
        XCTAssertEqual(defaults.object(forKey: "automaticDiagnostics") as? Bool, false)
        let before = try sampleCount()
        simulation.advance(90)
        tick()
        XCTAssertEqual(try sampleCount(), before)
        controller = nil
        states.removeAll()
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        start()
        tick()
        XCTAssertFalse(try XCTUnwrap(states.last).enabled)
        XCTAssertFalse(try XCTUnwrap(states.last).recording)
        XCTAssertEqual(try sampleCount(), before)
        XCTAssertEqual(try records().count, 1)
    }

    func testSleepFinishesAndWakeResumesAsSeparateSessionWithoutFillingGap() throws {
        simulation.lid = true
        start()
        tick()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        drain()
        XCTAssertFalse(try XCTUnwrap(states.last).recording)
        let before = try sampleCount()
        simulation.advance(120)
        tick()
        XCTAssertEqual(try sampleCount(), before)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        drain()
        tick()
        XCTAssertTrue(try XCTUnwrap(states.last).recording)
        XCTAssertEqual(try sampleCount(), before + 2)
        XCTAssertEqual(try records().count, 3)
        let endings = try records().flatMap { $0 }.compactMap { ($0["ending"] as? [String: Any])?["reason"] as? String }
        XCTAssertEqual(Set(endings), ["系统即将休眠", "系统已唤醒；单次观测，不回填休眠期间数据"])
    }

    func testSleepBeforeFirstLidPollPersistsClosedEventAndDistinctWakeObservation() throws {
        start()
        simulation.lid = true
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        drain() // No timer tick occurred between closing the lid and willSleep.
        var sessions = try records()
        XCTAssertEqual(sessions.count, 1)
        let sleeping = try XCTUnwrap(sessions.first)
        XCTAssertEqual((sleeping.first?["session"] as? [String: Any])?["kind"] as? String, "系统休眠事件")
        let asleepContext = try XCTUnwrap((sleeping[1]["snapshot"] as? [String: Any])?["context"] as? [String: Any])
        XCTAssertEqual(asleepContext["lidClosed"] as? Bool, true)
        XCTAssertNotNil(sleeping.last?["ending"])
        XCTAssertFalse(try XCTUnwrap(states.last).recording)
        simulation.advance(120)
        tick()
        XCTAssertEqual(try sampleCount(), 1, "No samples are invented while sleeping")
        simulation.lid = false
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        drain()
        sessions = try records()
        XCTAssertEqual(sessions.count, 2)
        let waking = try XCTUnwrap(sessions.first { ($0.first?["session"] as? [String: Any])?["kind"] as? String == "系统唤醒事件" })
        let wakeSample = try XCTUnwrap(waking[1]["snapshot"] as? [String: Any])
        XCTAssertEqual((wakeSample["context"] as? [String: Any])?["lidClosed"] as? Bool, false)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let sample = try decoder.decode(ResourceSnapshot.self, from: JSONSerialization.data(withJSONObject: wakeSample))
        XCTAssertEqual(sample.timestamp.timeIntervalSince(simulation.date), 0, accuracy: 1)
        XCTAssertTrue(((waking.last?["ending"] as? [String: Any])?["reason"] as? String)?.contains("不回填") == true)
        XCTAssertEqual(try sampleCount(), 2)
    }

    func testOpenLidWakeKeepsClosedLidReportAccessible() throws {
        simulation.lid = true
        start()
        tick()
        simulation.advance(12)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        drain()
        XCTAssertEqual(try sampleCount(), 2, "Sleep captures one final actual observation")
        simulation.advance(120)
        simulation.lid = false
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        drain()
        let reportReady = expectation(description: "Report points to closed-lid evidence")
        controller?.report { result in
            do {
                let report = try String(contentsOf: result.get(), encoding: .utf8)
                XCTAssertTrue(report.contains("自动合盖记录"))
                XCTAssertTrue(report.contains("系统即将休眠"))
            } catch { XCTFail("Report failed: \(error)") }
            reportReady.fulfill()
        }
        wait(for: [reportReady], timeout: 2)
        XCTAssertEqual(try records().count, 2, "Separate wake observation is still retained")
    }

    func testSleepEventPreservesUnknownLidAndDeduplicatesRepeatedNotifications() throws {
        start()
        simulation.lid = nil
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        drain()
        XCTAssertEqual(try records().count, 1)
        let sleepSample = try XCTUnwrap(records().first?[1]["snapshot"] as? [String: Any])
        XCTAssertNil((sleepSample["context"] as? [String: Any])?["lidClosed"])
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        drain()
        XCTAssertEqual(try records().count, 2)
        XCTAssertEqual(try sampleCount(), 2)
    }

    func testDisabledAutomaticDiagnosticsDoesNotArchiveSleepOrWakeEvents() throws {
        defaults.set(false, forKey: "automaticDiagnostics")
        simulation.lid = true
        start()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        drain()
        tick()
        XCTAssertTrue(try records().isEmpty)
        XCTAssertEqual(simulation.attempts, 0)
    }

    func testManualChecksAreMutuallyExclusiveAndAutomaticTickWaits() throws {
        start()
        let completed = expectation(description: "Manual report finishes")
        let rejected = expectation(description: "Concurrent manual check is rejected")
        controller?.checkNow { result in
            switch result {
            case .success(let url): XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            case .failure(let error): XCTFail("Unexpected first check failure: \(error)")
            }
            completed.fulfill()
        }
        controller?.checkNow { result in
            switch result {
            case .success: XCTFail("Second check must not start another session")
            case .failure(let error): XCTAssertTrue(error.localizedDescription.contains("检查正在进行"))
            }
            rejected.fulfill()
        }
        drain()
        XCTAssertTrue(try XCTUnwrap(states.last).busy)
        simulation.lid = true
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        drain()
        tick()
        XCTAssertEqual(try sampleCount(), 1)
        wait(for: [completed, rejected], timeout: 3)
        drain()
        XCTAssertFalse(try XCTUnwrap(states.last).busy)
        XCTAssertEqual(try records().count, 1)
        XCTAssertEqual(try sampleCount(), 2)
        tick()
        XCTAssertTrue(try XCTUnwrap(states.last).recording)
        XCTAssertEqual(try records().count, 2)
    }

    func testSamplingFailurePausesRetriesAndExplicitEnableRecoversInterruptedArchive() throws {
        simulation.lid = true
        simulation.failSampling = true
        start()
        tick()
        XCTAssertFalse(try XCTUnwrap(states.last).recording)
        XCTAssertTrue(try XCTUnwrap(states.last).message.contains("模拟采样失败"))
        XCTAssertEqual(simulation.attempts, 1)
        simulation.advance(90)
        tick()
        XCTAssertEqual(simulation.attempts, 1, "A failed diagnostic must not repeatedly retry by itself")
        controller?.update(nil)
        controller?.setEnabled(false)
        drain()
        XCTAssertFalse(try XCTUnwrap(states.last).enabled, "Controller remains responsive after diagnostic failure")
        simulation.failSampling = false
        controller?.setEnabled(true)
        drain()
        XCTAssertTrue(try XCTUnwrap(states.last).recording)
        XCTAssertEqual(simulation.attempts, 2)
        let reports = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(reports.first), encoding: .utf8).contains("采集中断"))
    }
}

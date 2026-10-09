import Foundation
import Darwin

public enum DiagnosticEventKind: String, Codable {
    case sleep, wake
}

struct DiagnosticSession: Codable {
    let id: String
    let kind: String
    let startedAt: Date
    let segment: Int
    let previousID: String?
    let continuationReason: String?
    var event: DiagnosticEventKind? = nil
}

struct DiagnosticEnding: Codable {
    let at: Date
    let reason: String
}

private struct ArchiveRecord: Codable {
    var session: DiagnosticSession?
    var snapshot: ResourceSnapshot?
    var ending: DiagnosticEnding?
}

public struct DiagnosticArchiveError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private final class ArchiveDescriptor {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { close(value) }
}

/// Call on one serial queue. This archive has no timers, threads, or power-control access.
public final class DiagnosticArchive {
    public let directory: URL
    static let sampleLimit = 720
    static let lineLimit = 64 * 1024
    static let sessionByteLimit = 8 * 1024 * 1024
    static let reportByteLimit = 2 * 1024 * 1024
    static let totalByteLimit = 32 * 1024 * 1024
    static let sessionLimit = 20
    static let eventLimit = 8
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private struct Active {
        let session: DiagnosticSession
        var count: Int
        var bytes: Int
    }
    private struct Entry {
        let session: DiagnosticSession
        let bytes: Int
    }
    private let directoryHandle: ArchiveDescriptor
    private let lockHandle: ArchiveDescriptor
    private var directoryFD: Int32 { directoryHandle.value }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var active: Active?

    public init(directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.pathComponents.contains(".."), !directory.pathComponents.contains(".") else {
            throw DiagnosticArchiveError("诊断目录路径无效。")
        }
        self.directory = directory
        directoryHandle = ArchiveDescriptor(try Self.openDirectory(directory.path))
        lockHandle = try Self.openLock(directoryHandle.value)
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
        try prune(now: Date())
        try recoverInterruptedSessions()
        try prune(now: Date())
    }

    public func begin(kind: String, at: Date = Date(), event: DiagnosticEventKind? = nil) throws {
        if active != nil { _ = try finish(reason: "开始新的检查", at: at) }
        try start(kind: kind, at: at, segment: 1, previousID: nil, continuationReason: nil, event: event)
    }

    public func append(_ snapshot: ResourceSnapshot) throws {
        guard var current = active else { throw DiagnosticArchiveError("尚未开始诊断采集。") }
        let line = try encode(ArchiveRecord(snapshot: snapshot))
        if current.count >= Self.sampleLimit || current.bytes + line.count + Self.lineLimit > Self.sessionByteLimit {
            let reason = current.count >= Self.sampleLimit ? "达到 720 次采样上限，继续下一段" : "达到单段容量上限，继续下一段"
            _ = try finish(reason: reason, at: snapshot.timestamp)
            try start(kind: current.session.kind, at: snapshot.timestamp, segment: current.session.segment + 1,
                      previousID: current.session.id, continuationReason: reason, event: current.session.event)
            current = active!
        }
        try prune(now: snapshot.timestamp, reserving: line.count)
        try appendLine(line, name: current.session.id + ".jsonl", expectedSize: current.bytes)
        current.count += 1
        current.bytes += line.count
        active = current
    }

    @discardableResult
    public func finish(reason: String, at: Date = Date()) throws -> URL? {
        guard let current = active else { return latestReportURL() }
        let ending = DiagnosticEnding(at: at, reason: reason)
        let line = try encode(ArchiveRecord(ending: ending))
        try prune(now: at, reserving: line.count)
        try appendLine(line, name: current.session.id + ".jsonl", expectedSize: current.bytes)
        active = nil
        let url = try makeReport(id: current.session.id)
        try prune(now: at)
        return url
    }

    /// Produces a readable snapshot without ending the current recording.
    public func currentReport() throws -> URL? {
        guard let current = active else { return latestReportURL() }
        let url = try makeReport(id: current.session.id, recording: true)
        return url
    }

    public func latestReportURL() -> URL? {
        // Wake-only observations complement a useful report instead of hiding it.
        // Resolve from retained metadata so restart and retention use the same rule.
        guard let candidates = try? entries().sorted(by: {
            if ($0.session.event == .wake) != ($1.session.event == .wake) { return $0.session.event != .wake }
            return $0.session.startedAt > $1.session.startedAt
        }) else { return nil }
        for entry in candidates {
            let name = entry.session.id + ".md"
            if (try? metadata(name)) != nil { return directory.appendingPathComponent(name) }
        }
        return nil
    }

    private func start(kind: String, at: Date, segment: Int, previousID: String?, continuationReason: String?,
                       event: DiagnosticEventKind?) throws {
        let session = DiagnosticSession(id: UUID().uuidString.lowercased(), kind: String(kind.prefix(120)),
                                        startedAt: at, segment: segment, previousID: previousID,
                                        continuationReason: continuationReason, event: event)
        let line = try encode(ArchiveRecord(session: session))
        try prune(now: at, reserving: line.count, addingSession: true, addingEvent: event)
        try create(line, name: session.id + ".jsonl")
        active = Active(session: session, count: 0, bytes: line.count)
    }

    private func encode(_ record: ArchiveRecord) throws -> Data {
        var data = try encoder.encode(record)
        data.append(0x0a)
        guard data.count <= Self.lineLimit else { throw DiagnosticArchiveError("单次诊断记录超过 64 KiB；本次记录未写入。") }
        return data
    }

    private func readRecords(_ id: String) throws -> (DiagnosticSession, [ResourceSnapshot], DiagnosticEnding?, Bool) {
        let data = try read(id + ".jsonl", limit: Self.sessionByteLimit)
        let lines = data.split(separator: 0x0a, omittingEmptySubsequences: false)
        guard let first = lines.first, first.count <= Self.lineLimit,
              let session = try decoder.decode(ArchiveRecord.self, from: Data(first)).session,
              session.id == id else { throw DiagnosticArchiveError("诊断记录的会话头无效。") }
        var snapshots: [ResourceSnapshot] = []
        var ending: DiagnosticEnding?
        var damaged = false
        for line in lines.dropFirst() where !line.isEmpty {
            guard line.count <= Self.lineLimit, ending == nil,
                  let record = try? decoder.decode(ArchiveRecord.self, from: Data(line)) else {
                damaged = true; continue
            }
            if let snapshot = record.snapshot, snapshots.count < Self.sampleLimit { snapshots.append(snapshot) }
            else if let value = record.ending { ending = value }
            else { damaged = true }
        }
        return (session, snapshots, ending, damaged)
    }

    private func makeReport(id: String, recording: Bool = false, interrupted: Bool = false) throws -> URL {
        let (session, snapshots, ending, damaged) = try readRecords(id)
        let report = DiagnosticReport.render(session: session, snapshots: snapshots, ending: ending,
                                             recording: recording, interrupted: interrupted || (ending == nil && !recording),
                                             damaged: damaged)
        let data = Data(report.utf8)
        guard data.count <= Self.reportByteLimit else { throw DiagnosticArchiveError("诊断报告超过容量上限。") }
        try prune(now: Date(), reserving: data.count, protecting: id)
        let name = id + ".md"
        _ = try metadata(name)
        let temporary = UUID().uuidString.lowercased() + ".tmp"
        try create(data, name: temporary)
        defer { unlinkat(directoryFD, temporary, 0) }
        guard renameat(directoryFD, temporary, directoryFD, name) == 0 else {
            throw DiagnosticArchiveError("无法保存诊断报告。")
        }
        guard fsync(directoryFD) == 0 else { throw DiagnosticArchiveError("无法同步诊断目录。") }
        return directory.appendingPathComponent(name)
    }

    private func recoverInterruptedSessions() throws {
        let sessions = try entries().sorted { $0.session.startedAt < $1.session.startedAt }
        for entry in sessions {
            // An earlier report may have pruned this segment to reserve space.
            // Missing files are expected here; unsafe metadata still throws.
            guard try metadata(entry.session.id + ".jsonl") != nil else { continue }
            let (_, _, ending, _) = try readRecords(entry.session.id)
            let reportExists = try metadata(entry.session.id + ".md") != nil
            if ending == nil || !reportExists {
                _ = try makeReport(id: entry.session.id, interrupted: ending == nil)
            }
        }
    }

    private func entries() throws -> [Entry] {
        var result: [Entry] = []
        let names = try filenames()
        let nameSet = Set(names)
        for name in names where name.hasSuffix(".md") {
            if !nameSet.contains(String(name.dropLast(3)) + ".jsonl") {
                // Only our UUID-named, same-user 0600 regular files reach here.
                guard unlinkat(directoryFD, name, 0) == 0 else {
                    throw DiagnosticArchiveError("无法清理缺少原始记录的旧诊断报告。")
                }
            }
        }
        for name in names {
            guard name.hasSuffix(".jsonl") else { continue }
            let id = String(name.dropLast(6))
            guard UUID(uuidString: id) != nil else { throw DiagnosticArchiveError("诊断目录存在未知文件。") }
            let file = try openFile(name, flags: O_RDONLY)
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(file, &buffer, buffer.count)
            close(file)
            guard count > 0, let newline = buffer.prefix(count).firstIndex(of: 0x0a),
                  let session = try decoder.decode(ArchiveRecord.self, from: Data(buffer[..<newline])).session,
                  session.id == id else { throw DiagnosticArchiveError("诊断会话头无法读取。") }
            let bytes = Int(try metadata(name)!.st_size) + Int(try metadata(id + ".md")?.st_size ?? 0)
            result.append(Entry(session: session, bytes: bytes))
        }
        return result
    }

    private func prune(now: Date, reserving bytes: Int = 0, addingSession: Bool = false,
                       addingEvent: DiagnosticEventKind? = nil, protecting id: String? = nil) throws {
        let all = try entries().sorted {
            if ($0.session.event != nil) != ($1.session.event != nil) { return $0.session.event != nil }
            return $0.session.startedAt < $1.session.startedAt
        }
        var count = all.filter { $0.session.event == nil }.count + (addingSession && addingEvent == nil ? 1 : 0)
        var events = all.filter { $0.session.event != nil }.count + (addingSession && addingEvent != nil ? 1 : 0)
        var size = all.reduce(0) { $0 + $1.bytes } + bytes
        for entry in all {
            guard entry.session.id != active?.session.id, entry.session.id != id else { continue }
            let event = entry.session.event != nil
            let overCount = event ? events > Self.eventLimit : count > Self.sessionLimit
            if now.timeIntervalSince(entry.session.startedAt) > Self.retention || overCount || size > Self.totalByteLimit {
                for suffix in [".md", ".jsonl"] {
                    let name = entry.session.id + suffix
                    if try metadata(name) != nil, unlinkat(directoryFD, name, 0) != 0 {
                        throw DiagnosticArchiveError("无法清理过期诊断记录。")
                    }
                }
                if event { events -= 1 } else { count -= 1 }
                size -= entry.bytes
            }
        }
        guard size <= Self.totalByteLimit, count <= Self.sessionLimit, events <= Self.eventLimit else {
            throw DiagnosticArchiveError("诊断存储达到容量上限。")
        }
    }

    private static func openDirectory(_ path: String) throws -> Int32 {
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw DiagnosticArchiveError("无法访问诊断目录。") }
        do {
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { throw DiagnosticArchiveError("诊断目录不能是根目录。") }
            for component in components {
                guard component != ".", component != ".." else { throw DiagnosticArchiveError("诊断目录路径无效。") }
                var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(current, component, 0o700) == 0 else { throw DiagnosticArchiveError("无法创建诊断目录。") }
                    next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw DiagnosticArchiveError("诊断目录不可访问，或路径包含符号链接（\(component)，errno \(errno)）。") }
                close(current); current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                throw DiagnosticArchiveError("诊断目录必须属于当前用户且权限为 0700。")
            }
            return current
        } catch { close(current); throw error }
    }

    private static func openLock(_ directory: Int32) throws -> ArchiveDescriptor {
        let file = openat(directory, "archive.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw DiagnosticArchiveError("无法打开诊断目录锁。") }
        let handle = ArchiveDescriptor(file)
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size == 0 else {
            throw DiagnosticArchiveError("诊断目录锁权限不安全。")
        }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
            throw DiagnosticArchiveError("另一个诊断实例正在使用该目录，未修改任何记录。")
        }
        var pathInfo = stat()
        guard fstatat(directory, "archive.lock", &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              pathInfo.st_dev == info.st_dev, pathInfo.st_ino == info.st_ino else {
            throw DiagnosticArchiveError("诊断目录锁发生变化。")
        }
        return handle
    }

    private func filenames() throws -> [String] {
        // openat creates a new directory offset; dup would share readdir's offset.
        let copied = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copied >= 0, let stream = fdopendir(copied) else {
            if copied >= 0 { close(copied) }
            throw DiagnosticArchiveError("无法列出诊断记录。")
        }
        defer { closedir(stream) }
        var names: [String] = []
        var foundLock = false
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            // Finder may add this after the user opens the diagnostics folder.
            // It is not an archive record: never read, delete, or follow it.
            if name == "." || name == ".." || name == ".DS_Store" { continue }
            if name == "archive.lock" {
                var held = stat()
                guard let info = try metadata(name), info.st_size == 0, fstat(lockHandle.value, &held) == 0,
                      info.st_dev == held.st_dev, info.st_ino == held.st_ino else {
                    throw DiagnosticArchiveError("诊断目录锁发生变化，已停止写入。")
                }
                foundLock = true
                continue
            }
            let ext = (name as NSString).pathExtension
            guard ["jsonl", "md", "tmp"].contains(ext), UUID(uuidString: (name as NSString).deletingPathExtension) != nil else {
                throw DiagnosticArchiveError("诊断目录存在未知文件；未自动删除。")
            }
            _ = try metadata(name)
            if ext == "tmp" {
                guard unlinkat(directoryFD, name, 0) == 0 else { throw DiagnosticArchiveError("无法清理未完成的报告。") }
            } else { names.append(name) }
        }
        guard foundLock else { throw DiagnosticArchiveError("诊断目录锁已丢失，已停止写入。") }
        return names
    }

    private func metadata(_ name: String) throws -> stat? {
        guard !name.contains("/"), !name.hasPrefix(".") else { throw DiagnosticArchiveError("诊断文件名无效。") }
        var info = stat()
        if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw DiagnosticArchiveError("无法读取诊断文件状态。")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else {
            throw DiagnosticArchiveError("诊断文件权限不安全，已停止写入。")
        }
        return info
    }

    private func openFile(_ name: String, flags: Int32) throws -> Int32 {
        guard try metadata(name) != nil else { throw DiagnosticArchiveError("诊断文件已不存在。") }
        let file = openat(directoryFD, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw DiagnosticArchiveError("无法打开诊断文件。") }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else {
            close(file); throw DiagnosticArchiveError("诊断文件在读取时发生变化。")
        }
        return file
    }

    private func create(_ data: Data, name: String) throws {
        let file = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw DiagnosticArchiveError("无法创建诊断文件。") }
        defer { close(file) }
        do { try write(data, to: file) }
        catch { unlinkat(directoryFD, name, 0); throw error }
        guard fsync(directoryFD) == 0 else { throw DiagnosticArchiveError("无法同步诊断目录。") }
    }

    private func appendLine(_ data: Data, name: String, expectedSize: Int) throws {
        let file = try openFile(name, flags: O_WRONLY | O_APPEND)
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size == expectedSize else {
            throw DiagnosticArchiveError("诊断文件大小意外改变，已停止追加。")
        }
        try write(data, to: file)
    }

    private func write(_ data: Data, to file: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DiagnosticArchiveError("诊断写入失败；磁盘可能已满或不可用。") }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw DiagnosticArchiveError("诊断文件同步失败。") }
    }

    private func read(_ name: String, limit: Int) throws -> Data {
        let file = try openFile(name, flags: O_RDONLY)
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size >= 0, info.st_size <= limit else {
            throw DiagnosticArchiveError("诊断文件超过读取上限。")
        }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.read(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DiagnosticArchiveError("诊断文件未完整读取。") }
                offset += count
            }
        }
        return data
    }
}

import Foundation
import Darwin
import LidKeepCore

struct ServiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Ownership: Codable {
    var boot: String
    var baseline: Int
    var createdAt: Date
}
struct SafetyLatch: Codable, Equatable {
    var id = UUID().uuidString
    var boot: String
    var reason: String
    var sleepRequested: Bool
    var sleepToken: String?
    var requestToken: String? { sleepRequested ? (sleepToken ?? id) : nil }
    var revision = 0
    var acknowledgment: String { "\(id):\(revision)" }
}
struct DesiredState: Codable {
    var boot: String
    var session: String
    var monotonic: Double
    var guiHeartbeat: Double?
    var guiUID: uid_t?
    var wantsAwake: Bool
    var mode: RunMode
    var stopPercent: Double
    var testDeadline: Double?
    var acknowledgedSafety: String?
    var sleepToken: String?
}
struct GuardianState: Codable {
    var boot: String
    var monotonic: Double
    var sleepDisabled: Bool?
    var error: String?
    var diagnostic: ServiceResourceCounter? = nil
}
struct SleepReceipts: Codable { var tokens: [String] = [] }

/// Files are accessed relative to a root-owned, private directory descriptor. Atomic
/// replacements are durable before any privileged power command is allowed.
final class SecureStore {
    let directory: String
    private let fd: Int32
    let boot: String
    init(directory: String = LidKeepPaths.stateDirectory, requireRoot: Bool = true, testBoot: String? = nil) throws {
        self.directory = directory
        if requireRoot && geteuid() != 0 { throw ServiceError("电源服务必须由管理员安装并以 root 运行。") }
        var state = stat()
        if lstat(directory, &state) != 0 {
            guard errno == ENOENT, mkdir(directory, 0o700) == 0 else { throw ServiceError("无法创建安全状态目录。") }
        }
        guard lstat(directory, &state) == 0,
              (state.st_mode & S_IFMT) == S_IFDIR,
              state.st_uid == (requireRoot ? 0 : geteuid()),
              state.st_mode & 0o077 == 0 else { throw ServiceError("状态目录所有者或权限不安全。") }
        fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError("无法打开状态目录。") }
        if !requireRoot, let testBoot { boot = testBoot; return }
        do { boot = try BootSessionID.read() }
        catch { close(fd); throw error }
    }
    deinit { close(fd) }
    private func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }
    func exists(_ name: String) throws -> Bool {
        guard validName(name) else { throw ServiceError("无效状态文件名。") }
        for _ in 0..<3 {
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return false }
                throw ServiceError("无法检查状态文件 \(name)。")
            }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
                  info.st_mode & 0o077 == 0, info.st_nlink <= 1 else {
                throw ServiceError("状态文件 \(name) 的权限不安全。")
            }
            if info.st_nlink == 1 { return true }
            // Atomic replacement can unlink the resolved vnode before getattr.
            // Recheck the name rather than mistaking that old inode for bad permissions.
        }
        throw ServiceError("状态文件 \(name) 正在连续替换，无法确认当前状态。")
    }
    func data(_ name: String, limit: Int = 262_144) throws -> Data? {
        guard validName(name) else { throw ServiceError("无效状态文件名。") }
        // Validate the opened inode, not an earlier path lookup. O_NONBLOCK also
        // prevents an unexpected FIFO from blocking before we reject its type.
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw ServiceError("无法读取 \(name)。")
        }
        defer { close(file) }
        return try readSnapshot(file, name: name, limit: limit)
    }
    /// The caller owns this descriptor. A writer may already have atomically
    /// replaced its directory entry; that unlinked inode is still a valid snapshot.
    func readSnapshot(_ file: Int32, name: String, limit: Int = 262_144) throws -> Data {
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size >= 0, info.st_size <= limit,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_nlink <= 1, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ServiceError("状态文件 \(name) 无效或过大。")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var count = 0
        while count < bytes.count {
            let remaining = bytes.count - count
            let result = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(file, raw.baseAddress!.advanced(by: count), remaining)
            }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw ServiceError("读取 \(name) 不完整。") }
            count += result
        }
        return Data(bytes)
    }
    func read<T: Decodable>(_ name: String, as: T.Type) throws -> T? {
        guard let data = try data(name) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ServiceError("状态文件 \(name) 损坏：\(error.localizedDescription)") }
    }
    func write<T: Encodable>(_ object: T, to name: String) throws {
        try write(JSONEncoder().encode(object), to: name)
    }
    func write(_ data: Data, to name: String) throws {
        guard validName(name) else { throw ServiceError("无效状态文件名。") }
        _ = try exists(name)
        let temporary = ".\(name).\(UUID().uuidString)"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw ServiceError("无法准备状态更新。") }
        defer { close(file); unlinkat(fd, temporary, 0) }
        var count = 0
        while count < data.count {
            let result = data.withUnsafeBytes { raw in Darwin.write(file, raw.baseAddress!.advanced(by: count), data.count - count) }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw ServiceError("无法写入 \(name)。") }
            count += result
        }
        guard fsync(file) == 0, renameat(fd, temporary, fd, name) == 0, fsync(fd) == 0 else {
            throw ServiceError("无法持久保存 \(name)。")
        }
    }
    func remove(_ name: String) throws {
        if try exists(name) {
            guard unlinkat(fd, name, 0) == 0, fsync(fd) == 0 else { throw ServiceError("无法删除 \(name)。") }
        }
    }
    func withLock<T>(timeout: Double = 9, _ work: () throws -> T) throws -> T {
        let file = openat(fd, "power.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw ServiceError("无法打开电源锁。") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ServiceError("电源锁权限不安全。")
        }
        let deadline = Monotonic.now + timeout
        while flock(file, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EINTR), Monotonic.now < deadline else {
                throw ServiceError("电源锁超时；后台可能无响应。")
            }
            usleep(20_000)
        }
        defer { flock(file, LOCK_UN) }
        return try work()
    }
    /// Creates one protection episode without ever overwriting a newer reason.
    /// This has its own short metadata lock, never the privileged-command lock.
    private func withSafetyLock<T>(_ work: () throws -> T) throws -> T {
        let file = openat(fd, "safety.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw ServiceError("无法创建保护锁。") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ServiceError("保护锁权限不安全。")
        }
        let deadline = Monotonic.now + 3
        while flock(file, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EINTR), Monotonic.now < deadline else {
                throw ServiceError("保护锁超时。")
            }
            usleep(10_000)
        }
        defer { flock(file, LOCK_UN) }
        return try work()
    }
    func latch(_ reason: String, sleep: Bool = false, token: String? = nil) throws -> SafetyLatch {
        try withSafetyLock {
            if var existing = try read("safety.json", as: SafetyLatch.self), existing.boot == boot {
                let requestedToken = sleep ? (token ?? existing.requestToken ?? existing.id) : existing.sleepToken
                if (sleep && !existing.sleepRequested) || existing.reason != reason || existing.sleepToken != requestedToken {
                    existing.sleepRequested = existing.sleepRequested || sleep
                    existing.sleepToken = requestedToken
                    existing.reason = reason
                    existing.revision += 1
                    try write(existing, to: "safety.json")
                }
                return existing
            }
            var value = SafetyLatch(boot: boot, reason: reason, sleepRequested: sleep)
            if sleep { value.sleepToken = token ?? value.id }
            try write(value, to: "safety.json")
            return value
        }
    }
    /// Intent survives restoring ownership and either service restarting. Only a
    /// durable receipt consumes it; old-boot intent never sleeps a new session.
    func pendingSleepRequest() throws -> String? {
        guard let latch = try read("safety.json", as: SafetyLatch.self), latch.boot == boot,
              let token = latch.requestToken else { return nil }
        let receipts = try read("sleep-receipt.json", as: SleepReceipts.self)
        return receipts?.tokens.contains(token) == true ? nil : token
    }
    @discardableResult
    func removeLatch(ifMatching expected: SafetyLatch) throws -> Bool {
        try withSafetyLock {
            guard let latest = try read("safety.json", as: SafetyLatch.self), latest == expected else { return false }
            try remove("safety.json")
            return true
        }
    }
    func log(_ event: String, _ fields: [String: String] = [:]) {
        // Separate writers have separate bounded files, so records never interleave.
        let name = ProcessInfo.processInfo.arguments.contains("--watchdog") ? "watchdog-events.jsonl" : "daemon-events.jsonl"
        var object = fields; object["event"] = event
        object["time"] = ISO8601DateFormatter().string(from: Date())
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        line.append(10)
        do {
            var data = try self.data(name, limit: 1_100_000) ?? Data()
            if data.count > 1_000_000 { try write(data, to: name + ".previous"); data = Data() }
            data.append(line); try write(data, to: name)
        } catch { fputs("LidKeep logging: \(error.localizedDescription)\n", stderr) }
    }
    static func identity() throws -> IdentityManifest {
        for path in ["/Library", "/Library/Application Support", LidKeepPaths.support, LidKeepPaths.identity] {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
                  (info.st_mode & S_IFMT) == (path == LidKeepPaths.identity ? S_IFREG : S_IFDIR) else {
                throw ServiceError("身份清单或其父目录权限不安全：\(path)")
            }
        }
        let file = open(LidKeepPaths.identity, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw ServiceError("身份清单不可读。") }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        let data = try handle.read(upToCount: 16_385) ?? Data()
        guard data.count <= 16_384 else { throw ServiceError("身份清单过大。") }
        let manifest = try JSONDecoder().decode(IdentityManifest.self, from: data)
        guard !manifest.clientRequirement.isEmpty, !manifest.serviceRequirement.isEmpty,
              manifest.clientRequirement.hasPrefix("cdhash H\""), manifest.serviceRequirement.hasPrefix("cdhash H\"") else {
            throw ServiceError("安装身份必须绑定本机代码签名哈希。")
        }
        return manifest
    }
}

import Foundation
import Darwin
import LidKeepCore

struct CommandResult { let status: Int32; let output: String }
protocol CommandRunning { func run(_ arguments: [String]) throws -> CommandResult }

/// Only the fixed Apple binary is executable; arguments never come from XPC.
struct PMSetRunner: CommandRunning {
    func run(_ arguments: [String]) throws -> CommandResult {
        guard [["-g"], ["-a", "disablesleep", "1"], ["-a", "disablesleep", "0"], ["sleepnow"]].contains(arguments) else {
            throw ServiceError("不允许的电源命令。")
        }
        // Foundation may retain autoreleased Process/Pipe objects on a long-lived
        // dispatch queue. Bound their lifetime and close both handles explicitly.
        return try autoreleasepool { try runScoped(arguments) }
    }
    private func runScoped(_ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading, writer = pipe.fileHandleForWriting
        defer { try? reader.close(); try? writer.close() }
        process.standardOutput = pipe; process.standardError = pipe
        let readFD = reader.fileDescriptor
        func systemError(_ operation: String, _ code: Int32 = errno) -> ServiceError {
            ServiceError("pmset \(operation) 失败（errno \(code)）：\(String(cString: strerror(code)))")
        }
        let flags = fcntl(readFD, F_GETFL)
        guard flags >= 0 else { throw systemError("fcntl(F_GETFL)") }
        guard fcntl(readFD, F_SETFL, flags | O_NONBLOCK) == 0 else { throw systemError("fcntl(F_SETFL)") }
        do { try process.run() }
        catch {
            let detail = error as NSError
            throw ServiceError("pmset 启动失败（\(detail.domain) \(detail.code)）：\(detail.localizedDescription)")
        }
        // Process closes a Pipe's parent write end on launch. The defer also
        // covers failed launch, normal completion, read error and timeout.
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        func drain() throws {
            // Bound each drain pass even if a child continuously writes output.
            for _ in 0..<16 {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress!, $0.count) }
                if count > 0 {
                    if output.count < 65_536 { output.append(contentsOf: bytes.prefix(min(count, 65_536 - output.count))) }
                } else if count == 0 { return }
                else {
                    let code = errno
                    if code == EINTR { continue }
                    if code == EAGAIN || code == EWOULDBLOCK { return }
                    throw systemError("read", code)
                }
            }
        }
        func stopChild() -> Bool {
            for signal in [SIGTERM, SIGKILL] {
                if !process.isRunning { return true }
                if kill(process.processIdentifier, signal) != 0 && errno != ESRCH { return false }
                let deadline = Monotonic.now + 0.3
                while process.isRunning && Monotonic.now < deadline { usleep(10_000) }
            }
            return !process.isRunning
        }
        do {
            let deadline = Monotonic.now + 3
            while process.isRunning && Monotonic.now < deadline { try drain(); usleep(20_000) }
            guard !process.isRunning else { throw ServiceError("pmset 命令超时；状态需要恢复核对。") }
            try drain()
            return CommandResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
        } catch {
            guard stopChild() else { throw ServiceError("\(error.localizedDescription)；无法在限时内确认子进程退出。") }
            throw error
        }
    }
}

final class PowerController {
    let store: SecureStore
    let runner: CommandRunning
    init(store: SecureStore, runner: CommandRunning = PMSetRunner()) { self.store = store; self.runner = runner }
    static func parseSleepDisabled(_ text: String) throws -> Bool {
        let matches = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }
            .filter { $0.first == "SleepDisabled" }
        guard matches.count == 1, matches[0].count == 2,
              matches[0][1] == "0" || matches[0][1] == "1" else {
            throw ServiceError("pmset 未返回唯一有效的 SleepDisabled，不能确认实际状态。")
        }
        return matches[0][1] == "1"
    }
    static func checkCommand(_ result: CommandResult) throws {
        let lower = result.output.lowercased()
        guard result.status == 0, !["error", "unable", "failed", "failure", "must run", "not permitted", "permission denied"].contains(where: lower.contains) else {
            throw ServiceError("pmset 拒绝请求：\(result.output.prefix(200))")
        }
    }
    func readActual() throws -> Bool {
        let result = try runner.run(["-g"])
        guard result.status == 0 else { throw ServiceError("无法读取系统休眠设置。") }
        return try Self.parseSleepDisabled(result.output)
    }
    /// Caller holds power.lock. Journal survives failed command/readback or restart.
    func restoreLocked() throws {
        guard let owned = try store.read("ownership.json", as: Ownership.self) else { return }
        guard owned.baseline == 0 else { throw ServiceError("接管前的休眠状态不是 0；拒绝覆盖未知设置。") }
        // A trusted ownership journal already authorizes restoration. A failed
        // preliminary read must never prevent the attempt to re-enable sleep.
        let result = try runner.run(["-a", "disablesleep", "0"])
        try Self.checkCommand(result)
        guard try !readActual() else { throw ServiceError("恢复命令后 SleepDisabled 仍为 1。") }
        try store.remove("ownership.json")
        store.log("restored")
    }
    func restore() throws { try store.withLock { try restoreLocked() } }
    /// Must be inside the shared lock AFTER a fresh desired/latch/power check.
    func enableLocked(preflight: () throws -> Void = {}) throws {
        if let owned = try store.read("ownership.json", as: Ownership.self), owned.baseline != 0 {
            throw ServiceError("所有权记录基线无效，拒绝启用。")
        }
        if try readActual() {
            guard try store.read("ownership.json", as: Ownership.self)?.baseline == 0 else {
                throw ServiceError("系统已被其他工具设置为禁用休眠；LidKeep 未接管，也不会覆盖。")
            }
            try preflight()
            return
        }
        if try store.read("ownership.json", as: Ownership.self) == nil {
            try store.write(Ownership(boot: store.boot, baseline: 0, createdAt: Date()), to: "ownership.json")
        }
        try preflight()
        let result = try runner.run(["-a", "disablesleep", "1"])
        try Self.checkCommand(result)
        guard try readActual() else {
            throw ServiceError("启用后无法确认 SleepDisabled=1；将恢复正常休眠。")
        }
        store.log("enabled")
    }
    func sleepLocked(token: String) throws {
        try restoreLocked()
        guard try !readActual() else { throw ServiceError("正常休眠尚未恢复，未请求整机休眠。") }
        var receipts = try store.read("sleep-receipt.json", as: SleepReceipts.self) ?? SleepReceipts()
        guard !receipts.tokens.contains(token) else { return }
        // Commit intent first: a crash or manually waking never retries this episode.
        receipts.tokens = Array((receipts.tokens + [token]).suffix(64))
        try store.write(receipts, to: "sleep-receipt.json")
        let result = try runner.run(["sleepnow"])
        try Self.checkCommand(result)
        store.log("sleep-requested", ["token": token])
    }
}

import Foundation
import Darwin
import LidKeepCore

/// A trusted root record includes the process birth time, boot, path and role,
/// so recovery never kills a process merely because a stale PID was reused.
struct ProcessIdentity: Codable, Equatable {
    let pid: pid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let boot: String
    let path: String
    let role: String
    static func current(boot: String, role: String) throws -> ProcessIdentity {
        try inspect(getpid(), boot: boot, role: role)
    }
    private static func inspect(_ pid: pid_t, boot: String, role: String) throws -> ProcessIdentity {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_uid == 0, info.pbi_ruid == 0 else { throw ServiceError("无法验证后台进程身份。") }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { throw ServiceError("无法读取后台可执行文件。") }
        return ProcessIdentity(pid: pid, startedSeconds: info.pbi_start_tvsec,
                               startedMicroseconds: info.pbi_start_tvusec, boot: boot,
                               path: String(cString: buffer), role: role)
    }
    /// Called only when a watchdog heartbeat has expired AND recovery cannot obtain its lock.
    func terminateHungWatchdog(store: SecureStore) throws {
        guard role == "--watchdog", boot == store.boot, path == LidKeepPaths.helper, pid != getpid(),
              let latest = try store.read("guardian.json", as: GuardianState.self),
              latest.boot != store.boot || Monotonic.now - latest.monotonic > LidKeepPaths.leaseSeconds else {
            throw ServiceError("监护身份或失联条件不匹配，未终止进程。")
        }
        guard try Self.inspect(pid, boot: boot, role: role) == self, try hasRoleArgument() else {
            throw ServiceError("监护 PID 已失效或被复用，未终止进程。")
        }
        // Revalidate birth time immediately before signalling.
        guard try Self.inspect(pid, boot: boot, role: role) == self else { throw ServiceError("监护进程已改变。") }
        guard kill(pid, SIGKILL) == 0 || errno == ESRCH else { throw ServiceError("无法终止无响应监护进程。") }
        store.log("watchdog-killed-after-expired-lease", ["pid": String(pid)])
    }
    private func hasRoleArgument() throws -> Bool {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return false }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc == 2 else { return false }
        var offset = 4
        // Skip executable path and alignment NULs before argv[0].
        while offset < size && bytes[offset] != 0 { offset += 1 }
        while offset < size && bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            let start = offset
            while offset < size && bytes[offset] != 0 { offset += 1 }
            guard offset < size else { return false }
            arguments.append(String(decoding: bytes[start..<offset], as: UTF8.self)); offset += 1
        }
        return arguments.count == 2 && arguments[1] == role
    }
}

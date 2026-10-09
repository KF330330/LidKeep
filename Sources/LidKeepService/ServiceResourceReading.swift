import Foundation
import Darwin
import LidKeepCore

/// Each installed service reports only its own resource counters through existing status.
enum ServiceResourceReading {
    /// Read first: another service may publish a heartbeat after an environment snapshot.
    static func readGuardian(read: () throws -> GuardianState?, clock: () -> Double = { Monotonic.now }) rethrows
        -> (guardian: GuardianState?, checkedAt: Double) {
        let guardian = try read()
        return (guardian, clock())
    }

    static func guardianReady(_ guardian: GuardianState?, boot: String, now: Double) -> Bool {
        guard let guardian, guardian.boot == boot, now >= guardian.monotonic,
              now - guardian.monotonic <= LidKeepPaths.leaseSeconds, guardian.error == nil else { return false }
        return true
    }

    static func includingFreshGuardian(own: ServiceResourceCounter?, guardian: GuardianState?,
                                       boot: String, now: Double) -> [ServiceResourceCounter] {
        var resources = own.map { [$0] } ?? []
        if let guardian, guardian.boot == boot, now >= guardian.monotonic,
           now - guardian.monotonic <= 15, let counter = guardian.diagnostic {
            resources.append(counter)
        }
        return resources
    }

    static func current(name: String) -> ServiceResourceCounter? {
        guard name == "lidkeep-daemon" || name == "lidkeep-watchdog" else { return nil }
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(getpid(), PROC_PIDTASKALLINFO, 0, $0, size)
        }
        guard result == size, info.pbsd.pbi_pid == UInt32(getpid()),
              info.pbsd.pbi_start_tvsec > 0, info.pbsd.pbi_start_tvusec < 1_000_000 else { return nil }
        let seconds = info.pbsd.pbi_start_tvsec.multipliedReportingOverflow(by: 1_000_000)
        let start = seconds.partialValue.addingReportingOverflow(info.pbsd.pbi_start_tvusec)
        let cpu = info.ptinfo.pti_total_user.addingReportingOverflow(info.ptinfo.pti_total_system)
        guard !seconds.overflow, !start.overflow, !cpu.overflow else { return nil }
        return ServiceResourceCounter(pid: getpid(), startTime: start.partialValue, name: name,
                                      residentBytes: info.ptinfo.pti_resident_size, cpuTicks: cpu.partialValue,
                                      sampledUptime: ProcessInfo.processInfo.systemUptime)
    }
}

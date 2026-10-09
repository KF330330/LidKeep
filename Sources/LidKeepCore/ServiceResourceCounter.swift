import Foundation

/// A service reports only its own counters through the existing authenticated status path.
public struct ServiceResourceCounter: Codable {
    public var pid: Int32
    public var startTime: UInt64
    public var name: String
    public var residentBytes: UInt64
    /// Cumulative user + system CPU time in Mach ticks.
    public var cpuTicks: UInt64
    public var sampledUptime: Double

    public init(pid: Int32, startTime: UInt64, name: String, residentBytes: UInt64,
                cpuTicks: UInt64, sampledUptime: Double) {
        self.pid = pid; self.startTime = startTime; self.name = name
        self.residentBytes = residentBytes; self.cpuTicks = cpuTicks; self.sampledUptime = sampledUptime
    }
}

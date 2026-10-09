import Foundation
import LidKeepCore

public struct DiagnosticContext: Codable {
    public var lidClosed: Bool?
    public var thermal: ThermalLevel
    public var batteryPercent: Double?
    public var onAC: Bool?
    public var sleepDisabled: Bool?
    public var mode: String?
    public var reason: String?
    public var statusFresh: Bool
    public var serviceProcesses: [ServiceResourceCounter]?

    public init(lidClosed: Bool?, thermal: ThermalLevel, batteryPercent: Double?, onAC: Bool?,
                sleepDisabled: Bool?, mode: String?, reason: String?, statusFresh: Bool,
                serviceProcesses: [ServiceResourceCounter]? = nil) {
        self.lidClosed = lidClosed; self.thermal = thermal; self.batteryPercent = batteryPercent
        self.onAC = onAC; self.sleepDisabled = sleepDisabled; self.mode = mode
        self.reason = reason; self.statusFresh = statusFresh
        self.serviceProcesses = serviceProcesses
    }
}

public struct ProcessSample: Codable {
    public var pid: Int32
    /// Process creation time in microseconds since the Unix epoch; protects against PID reuse.
    public var startTime: UInt64
    public var name: String
    /// Resident memory, not Activity Monitor's memory footprint; shared pages can overlap.
    public var residentBytes: UInt64
    /// 100% is one fully occupied CPU core. The first observation has no rate.
    public var cpuPercent: Double?
    public var memoryDeltaBytes: Int64?

    public init(pid: Int32, startTime: UInt64, name: String, residentBytes: UInt64,
                cpuPercent: Double? = nil, memoryDeltaBytes: Int64? = nil) {
        self.pid = pid; self.startTime = startTime; self.name = name
        self.residentBytes = residentBytes; self.cpuPercent = cpuPercent
        self.memoryDeltaBytes = memoryDeltaBytes
    }
}

public struct ResourceSnapshot: Codable {
    public var timestamp: Date
    public var uptime: Double
    public var context: DiagnosticContext
    public var totalMemoryBytes: UInt64
    /// Truly free VM pages; this is not macOS's reclaimable/available memory estimate.
    public var freeMemoryBytes: UInt64?
    public var compressedBytes: UInt64?
    public var swapUsedBytes: UInt64?
    /// normal, warning, critical, or unknown.
    public var memoryPressure: String
    /// Across all logical cores, using the same 100%-per-core scale as processes.
    public var systemCPUPercent: Double?
    public var loadAverage: Double?
    public var processCount: Int
    public var unreadableProcessCount: Int
    public var processListTruncated: Bool
    public var processes: [ProcessSample]
    public var collectionSeconds: Double
    public var warnings: [String]

    public init(timestamp: Date, uptime: Double, context: DiagnosticContext, totalMemoryBytes: UInt64,
                freeMemoryBytes: UInt64?, compressedBytes: UInt64?, swapUsedBytes: UInt64?,
                memoryPressure: String, systemCPUPercent: Double?, loadAverage: Double?,
                processCount: Int, unreadableProcessCount: Int, processListTruncated: Bool,
                processes: [ProcessSample], collectionSeconds: Double, warnings: [String]) {
        self.timestamp = timestamp; self.uptime = uptime; self.context = context
        self.totalMemoryBytes = totalMemoryBytes; self.freeMemoryBytes = freeMemoryBytes
        self.compressedBytes = compressedBytes; self.swapUsedBytes = swapUsedBytes
        self.memoryPressure = memoryPressure; self.systemCPUPercent = systemCPUPercent
        self.loadAverage = loadAverage; self.processCount = processCount
        self.unreadableProcessCount = unreadableProcessCount; self.processListTruncated = processListTruncated
        self.processes = processes; self.collectionSeconds = collectionSeconds; self.warnings = warnings
    }
}

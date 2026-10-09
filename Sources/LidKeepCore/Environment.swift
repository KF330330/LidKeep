import Foundation
import Darwin

public enum Monotonic {
    public static var now: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}

public struct Environment: Codable {
    public var now: Double
    public var batteryPercent: Double?
    public var onAC: Bool
    public var thermal: ThermalLevel
    public var lidClosed: Bool?
    public var externalDisplayCount: Int?
    public var networkConnected: Bool
    public init(now: Double, batteryPercent: Double?, onAC: Bool, thermal: ThermalLevel,
                lidClosed: Bool? = nil, externalDisplayCount: Int? = nil, networkConnected: Bool = false) {
        self.now = now; self.batteryPercent = batteryPercent; self.onAC = onAC
        self.thermal = thermal; self.lidClosed = lidClosed
        self.externalDisplayCount = externalDisplayCount; self.networkConnected = networkConnected
    }
    public var validBattery: Bool {
        guard let value = batteryPercent else { return false }
        return value.isFinite && value >= 0 && value <= 100
    }
}

public struct Decision {
    public var keepAwake: Bool
    public var requestSleep: Bool
    public var mode: RunMode
    public var reason: String
    public init(_ keepAwake: Bool, sleep: Bool = false, mode: RunMode, reason: String) {
        self.keepAwake = keepAwake; self.requestSleep = sleep
        self.mode = mode; self.reason = reason
    }
}

public struct PolicyError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

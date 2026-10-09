import Foundation

public enum LidKeepPaths {
    public static let service = "local.rl.lidkeep.daemon"
    public static let watchdog = "local.rl.lidkeep.watchdog"
    public static let app = "/Applications/LidKeep.app"
    public static let helper = "/Library/PrivilegedHelperTools/local.rl.lidkeep.service"
    public static let support = "/Library/Application Support/LidKeep"
    public static let identity = support + "/identity.json"
    public static let stateDirectory = "/var/db/local.rl.lidkeep"
    public static let leaseSeconds: Double = 30
    public static let sampleSeconds: Double = 5
    public static let testSeconds: Double = 180
}

@objc public protocol LidKeepXPC {
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void)
}

public enum Command: String, Codable {
    case status, heartbeat, setEnabled, setThresholds, sleepNow
    case beginTest, confirmTest, cancelTest
}

public struct Request: Codable {
    public var command: Command
    public var enabled: Bool?
    public var stopPercent: Double?
    public var resumePercent: Double?
    public var testSucceeded: Bool?
    public init(_ command: Command, enabled: Bool? = nil, stopPercent: Double? = nil,
                resumePercent: Double? = nil, testSucceeded: Bool? = nil) {
        self.command = command; self.enabled = enabled
        self.stopPercent = stopPercent; self.resumePercent = resumePercent
        self.testSucceeded = testSucceeded
    }
}

public struct Response: Codable {
    public var status: RuntimeStatus?
    public var error: String?
    public init(status: RuntimeStatus? = nil, error: String? = nil) {
        self.status = status; self.error = error
    }
}

public struct IdentityManifest: Codable {
    public var clientRequirement: String
    public var serviceRequirement: String
    public init(clientRequirement: String, serviceRequirement: String) {
        self.clientRequirement = clientRequirement; self.serviceRequirement = serviceRequirement
    }
}

public enum ThermalLevel: String, Codable {
    case nominal, fair, serious, critical, unknown
    public var dangerous: Bool { self == .serious || self == .critical || self == .unknown }
    public var label: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "略高"
        case .serious: return "高温"
        case .critical: return "严重高温"
        case .unknown: return "未知"
        }
    }
}

public struct Preferences: Codable, Equatable {
    public var enabled = true
    public var stopPercent: Double = 10
    public var resumePercent: Double = 20
    public init() {}
    public static func validThresholds(stop: Double, resume: Double) -> Bool {
        stop.isFinite && resume.isFinite && stop >= 1 && stop < 100 && resume <= 100 && resume > stop
    }
}

public enum RunMode: String, Codable {
    case disabled, awaitingValidation, active, protected, recovering, testing, awaitingConfirmation, fault
    public var label: String {
        switch self {
        case .disabled: return "已手动关闭"
        case .awaitingValidation: return "等待合盖验收"
        case .active: return "合盖运行中"
        case .protected: return "保护已触发"
        case .recovering: return "等待恢复条件"
        case .testing: return "短时合盖测试中"
        case .awaitingConfirmation: return "待确认测试结果"
        case .fault: return "后台故障"
        }
    }
}

public struct RuntimeStatus: Codable {
    public var preferences: Preferences
    public var mode: RunMode
    public var reason: String
    public var batteryPercent: Double?
    public var onAC: Bool
    public var thermal: ThermalLevel
    public var sleepDisabled: Bool?
    public var verified: Bool
    public var testRemainingSeconds: Int?
    public var testEvidence: String?
    public var serviceProcesses: [ServiceResourceCounter]?
    public var updatedAt: Date
    public init(preferences: Preferences, mode: RunMode, reason: String,
                batteryPercent: Double?, onAC: Bool, thermal: ThermalLevel,
                sleepDisabled: Bool?, verified: Bool,
                testRemainingSeconds: Int? = nil, testEvidence: String? = nil,
                serviceProcesses: [ServiceResourceCounter]? = nil) {
        self.preferences = preferences; self.mode = mode; self.reason = reason
        self.batteryPercent = batteryPercent; self.onAC = onAC; self.thermal = thermal
        self.sleepDisabled = sleepDisabled; self.verified = verified
        self.testRemainingSeconds = testRemainingSeconds; self.testEvidence = testEvidence
        self.serviceProcesses = serviceProcesses
        self.updatedAt = Date()
    }
}

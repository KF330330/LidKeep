import Foundation

/// Pure, persistable policy. This type never changes system power settings.
public struct PolicyEngine: Codable {
    public var preferences = Preferences()
    public var verified = false
    public var verificationFingerprint: String?
    public private(set) var mode: RunMode = .awaitingValidation
    public private(set) var reason = "首次使用需完成 3 分钟合盖验收，当前未修改休眠设置。"
    public private(set) var testRemainingSeconds: Int?
    public private(set) var testEvidence: String?
    public var testDeadline: Double? { trial?.deadline }

    private var protectionLatched = false
    private var nominalSince: Double?
    private var wasKeepingAwake = false
    private var trial: Trial?
    private var pendingProof = false

    public init() {}

    /// Monotonic timestamps and in-flight trials cannot survive a process restart.
    public mutating func restart() {
        if trial != nil || pendingProof { failTrial("后台重启，未确认的测试结果无效，请重新测试。") }
        nominalSince = nil
        if wasKeepingAwake { protectionLatched = true }
        wasKeepingAwake = false
        mode = preferences.enabled ? (verified ? .recovering : .awaitingValidation) : .disabled
    }

    /// Disruptions invalidate the current enable intent; subsequent ticks must recover normally.
    @discardableResult
    public mutating func interrupt(reason: String) -> Decision {
        if trial != nil { failTrial(reason) }
        protectionLatched = true
        nominalSince = nil
        return output(false, mode: .fault, reason: reason)
    }

    public mutating func observedSleep() {
        if trial != nil { failTrial("测试期间发生系统休眠，合盖持续运行未通过。") }
        protectionLatched = true
        nominalSince = nil
        wasKeepingAwake = false
    }

    public mutating func evaluate(_ environment: Environment) -> Decision {
        guard preferences.enabled else {
            nominalSince = nil
            return output(false, mode: .disabled, reason: "已手动关闭；重新登录或重启不会自动开启。")
        }
        guard Preferences.validThresholds(stop: preferences.stopPercent, resume: preferences.resumePercent) else {
            return interrupt(reason: "电量阈值配置无效，保持停用。")
        }
        if !environment.validBattery {
            if trial != nil { failTrial("无法读取有效电池电量，测试停止。") }
            protectionLatched = true
            nominalSince = nil
            return output(false, mode: .protected, reason: "无法读取有效电池电量，已撤销保活。")
        }
        if environment.thermal.dangerous || environment.batteryPercent! < preferences.stopPercent {
            let shouldSleep = wasKeepingAwake
            let explanation = environment.thermal.dangerous
                ? "系统热状态为\(environment.thermal.label)，已进入保护。"
                : "电量低于 \(number(preferences.stopPercent))%，已进入保护。"
            if trial != nil { failTrial(explanation) }
            protectionLatched = true
            nominalSince = nil
            return output(false, sleep: shouldSleep, mode: .protected, reason: explanation)
        }
        if protectionLatched {
            guard environment.batteryPercent! >= preferences.resumePercent,
                  environment.thermal == .nominal else {
                nominalSince = nil
                return output(false, mode: .recovering,
                              reason: "等待电量达到 \(number(preferences.resumePercent))% 且系统热状态正常。")
            }
            if nominalSince == nil || environment.now < nominalSince! { nominalSince = environment.now }
            let remaining = 60 - (environment.now - nominalSince!)
            if remaining > 0 {
                return output(false, mode: .recovering,
                              reason: "恢复条件已满足，正常热状态还需保持 \(Int(ceil(remaining))) 秒。")
            }
            protectionLatched = false
            nominalSince = nil
        }

        if var running = trial {
            if let error = running.sample(environment) {
                failTrial(error)
                return output(false, mode: .awaitingValidation, reason: error)
            }
            trial = running
            testRemainingSeconds = max(0, Int(ceil(running.deadline - environment.now)))
            testEvidence = running.summary
            if environment.now >= running.deadline {
                trial = nil
                testRemainingSeconds = nil
                pendingProof = running.longestClosed >= 60
                if pendingProof {
                    testEvidence = running.summary + "\n自动回退已请求；请开盖核对 AI 任务、屏幕及锁屏后确认。"
                    return output(false, mode: .awaitingConfirmation,
                                  reason: "短时测试结束，等待你确认实际任务持续运行。")
                }
                return output(false, mode: .awaitingValidation,
                              reason: "未记录到至少 60 秒连续合盖，请重新测试。")
            }
            return output(true, mode: .testing, reason: "短时测试中；到期自动解除保活，尚未批准默认常开。")
        }
        if pendingProof {
            return output(false, mode: .awaitingConfirmation, reason: "测试已结束，等待人工核对结果。")
        }
        guard verified else {
            return output(false, mode: .awaitingValidation,
                          reason: "尚未通过本机合盖验收，默认常开暂不生效。")
        }
        return output(true, mode: .active, reason: "保持电脑运行；低电量、过热或后台失联时停止。")
    }

    public mutating func handle(_ request: Request, environment: Environment) throws -> Decision {
        switch request.command {
        case .status, .heartbeat:
            break
        case .setEnabled:
            guard let enabled = request.enabled else { throw PolicyError("缺少开关值。") }
            preferences.enabled = enabled
            if !enabled {
                if trial != nil || pendingProof { failTrial("手动关闭，测试取消。") }
                nominalSince = nil
            }
        case .setThresholds:
            guard let stop = request.stopPercent, let resume = request.resumePercent,
                  Preferences.validThresholds(stop: stop, resume: resume) else {
                throw PolicyError("停止阈值须在 1–99% 之间，恢复阈值须更高且不超过 100%。")
            }
            preferences.stopPercent = stop
            preferences.resumePercent = resume
            nominalSince = nil
        case .sleepNow:
            if trial != nil || pendingProof { failTrial("主动休眠，测试取消。") }
            protectionLatched = true
            nominalSince = nil
            return output(false, sleep: true, mode: .protected, reason: "已请求立即休眠。")
        case .beginTest:
            guard trial == nil else { throw PolicyError("已有短时测试正在运行。") }
            guard environment.validBattery, environment.batteryPercent! >= preferences.resumePercent,
                  environment.thermal == .nominal else {
                throw PolicyError("测试前请确保电量达到恢复阈值，且系统热状态正常。")
            }
            guard !environment.onAC, environment.externalDisplayCount == 0,
                  environment.lidClosed == false, environment.networkConnected else {
                throw PolicyError("请先拔掉电源和外接显示器，保持开盖并连接手机热点，再开始测试。")
            }
            preferences.enabled = true
            verified = false
            verificationFingerprint = nil
            protectionLatched = false
            nominalSince = nil
            pendingProof = false
            testEvidence = nil
            trial = Trial(started: environment.now)
        case .confirmTest:
            guard pendingProof, let succeeded = request.testSucceeded else {
                throw PolicyError("没有等待确认的合盖测试。")
            }
            pendingProof = false
            verified = succeeded
            if !succeeded {
                verificationFingerprint = nil
                testEvidence = (testEvidence ?? "") + "\n人工确认未通过，保持默认常开禁用。"
            }
        case .cancelTest:
            guard trial != nil || pendingProof else { throw PolicyError("没有正在进行的测试。") }
            failTrial("测试已取消，已请求恢复正常休眠。")
        }
        return evaluate(environment)
    }

    private mutating func output(_ awake: Bool, sleep: Bool = false, mode: RunMode, reason: String) -> Decision {
        self.mode = mode
        self.reason = reason
        wasKeepingAwake = awake
        return Decision(awake, sleep: sleep, mode: mode, reason: reason)
    }

    private mutating func failTrial(_ message: String) {
        let evidence = trial?.summary ?? testEvidence ?? ""
        testEvidence = evidence + "\n" + message
        trial = nil
        pendingProof = false
        testRemainingSeconds = nil
        verified = false
        verificationFingerprint = nil
    }

    private func number(_ value: Double) -> String { String(format: "%g", value) }
}

private struct Trial: Codable {
    var started: Double
    var lastSample: Double?
    var closedSince: Double?
    var longestClosed: Double = 0
    var samples = 0
    var deadline: Double { started + LidKeepPaths.testSeconds }
    var summary: String {
        "有效采样 \(samples) 次；最长连续合盖 \(Int(longestClosed)) 秒；全程检查电池供电、无外屏及网络路径。"
    }

    mutating func sample(_ environment: Environment) -> String? {
        guard !environment.onAC else { return "测试期间接入电源，电池合盖验收无效。" }
        guard environment.externalDisplayCount == 0 else { return "测试期间存在外接显示器或无法确认显示器状态。" }
        guard environment.networkConnected else { return "测试期间网络路径中断，请检查手机热点后重试。" }
        guard let closed = environment.lidClosed else { return "无法读取合盖状态，不能确认兼容性。" }
        guard environment.now >= started,
              lastSample == nil || (environment.now >= lastSample! && environment.now - lastSample! <= 15) else {
            return "测试采样中断超过 15 秒或时间异常，不能证明持续运行。"
        }
        if closed {
            if closedSince == nil { closedSince = environment.now }
            longestClosed = max(longestClosed, min(environment.now, deadline) - closedSince!)
        } else {
            closedSince = nil
        }
        samples += 1
        lastSample = environment.now
        return nil
    }
}

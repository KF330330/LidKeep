import Foundation
import Darwin
import LidKeepCore

final class ClientEndpoint: NSObject, LidKeepXPC {
    weak var daemon: Daemon?
    weak var connection: NSXPCConnection?
    let id = UUID().uuidString
    init(daemon: Daemon, connection: NSXPCConnection) { self.daemon = daemon; self.connection = connection }
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        guard let daemon, let connection else { reply(Self.encode(Response(error: "连接已失效。"))); return }
        daemon.receive(data, connection: connection, id: id, reply: reply)
    }
    static func encode(_ response: Response) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data("{\"error\":\"状态编码失败。\"}".utf8)
    }
}

final class Daemon: NSObject, NSXPCListenerDelegate {
    private let store: SecureStore
    private let power: PowerController
    private let manifest: IdentityManifest
    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "local.rl.lidkeep.daemon.serial")
    private let session = UUID().uuidString
    private var engine: PolicyEngine
    private var listener: NSXPCListener?
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var guiHeartbeat: Double?
    private var guiUID: uid_t?
    private var owner: String?
    private var acknowledgedSafety: String?
    private var lastFault: String?
    private var recoveryPending = false
    private var pendingSleep: String?
    private var lastDesired: DesiredState?
    private var stopped = false

    init(store: SecureStore, manifest: IdentityManifest, power: PowerController? = nil) throws {
        self.store = store; self.manifest = manifest; self.power = power ?? PowerController(store: store)
        self.engine = try store.read("policy.json", as: PolicyEngine.self) ?? PolicyEngine()
        super.init()
    }
    func start() throws {
        _ = try store.latch("主服务启动，先恢复遗留休眠设置。")
        try power.restore()
        engine.restart()
        if engine.verified && engine.verificationFingerprint != SystemSampler.fingerprint {
            engine.verified = false; engine.verificationFingerprint = nil
            _ = engine.interrupt(reason: "硬件或系统版本已改变，请重新完成合盖验收。")
        }
        try store.write(engine, to: "policy.json")
        // Publish a harmless state before accepting connections. No old GUI lease survives.
        let environment = sampler.sample()
        try publish(engine.evaluate(environment), environment: environment)
        let listener = NSXPCListener(machServiceName: LidKeepPaths.service)
        listener.setConnectionCodeSigningRequirement(manifest.clientRequirement)
        listener.delegate = self; listener.resume(); self.listener = listener
        sampler.changed = { [weak self] in self?.queue.async { self?.tick() } }
        sampler.sleepEvent = { [weak self] wake, acknowledge in
            guard let self else { acknowledge(); return }
            self.queue.async {
                defer { acknowledge() }
                self.store.log(wake ? "system-wake" : "system-will-sleep")
                self.guiHeartbeat = nil; self.owner = nil; self.guiUID = nil
                self.engine.observedSleep()
                do {
                    let latch = try self.store.latch(wake ? "系统已唤醒，等待菜单栏心跳和恢复条件。" : "系统即将休眠，已撤销保活。")
                    self.acknowledgedSafety = latch.acknowledgment
                    let decision = self.engine.interrupt(reason: latch.reason)
                    try self.publish(decision, environment: self.sampler.sample())
                    try self.power.restore()
                } catch { self.fail(error) }
            }
        }
        sampler.subscribe()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: LidKeepPaths.sampleSeconds, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }; timer.resume(); self.timer = timer
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.stopped = true
                do {
                    _ = try self.store.latch("主服务退出，已撤销保活。")
                    _ = self.engine.interrupt(reason: "后台已停止。")
                    try self.store.write(self.engine, to: "policy.json")
                    try self.power.restore()
                } catch { self.store.log("shutdown-restore-error", ["error": error.localizedDescription]) }
                exit(0)
            }
            source.resume(); signals.append(source)
        }
        store.log("daemon-started", ["fingerprint": SystemSampler.fingerprint])
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let console = SystemSampler.consoleUID, connection.effectiveUserIdentifier == console else { return false }
        connection.setCodeSigningRequirement(manifest.clientRequirement)
        let endpoint = ClientEndpoint(daemon: self, connection: connection)
        connection.exportedInterface = NSXPCInterface(with: LidKeepXPC.self)
        connection.exportedObject = endpoint
        let id = endpoint.id
        let disconnected = { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.owner == id else { return }
                self.store.log("gui-disconnected")
                self.owner = nil; self.guiHeartbeat = nil; self.guiUID = nil
                do {
                    let latch = try self.store.latch("菜单栏连接已断开，已撤销保活。")
                    self.acknowledgedSafety = latch.acknowledgment
                    try self.publish(self.engine.interrupt(reason: latch.reason), environment: self.sampler.sample())
                    try self.power.restore()
                } catch { self.fail(error) }
            }
        }
        connection.invalidationHandler = disconnected
        connection.interruptionHandler = disconnected
        connection.resume()
        return true
    }
    func receive(_ data: Data, connection: NSXPCConnection, id: String, reply: @escaping (Data) -> Void) {
        queue.async {
            guard data.count <= 4096, let console = SystemSampler.consoleUID,
                  connection.effectiveUserIdentifier == console else {
                reply(ClientEndpoint.encode(Response(error: "请求过大或当前用户无权访问。"))); return
            }
            do {
                let request = try JSONDecoder().decode(Request.self, from: data)
                if request.command == .heartbeat {
                    self.owner = id; self.guiUID = console; self.guiHeartbeat = Monotonic.now
                }
                let environment = self.sampler.sample()
                try self.observeSafety()
                var decision = try self.engine.handle(request, environment: environment)
                if request.command == .confirmTest && self.engine.verified {
                    self.engine.verificationFingerprint = SystemSampler.fingerprint
                }
                decision = try self.enforceRuntime(decision, environment: environment)
                // Every explicit button press is a new sleep request; only automatic
                // protection is deduplicated across the entire recovery episode.
                let manualToken = request.command == .sleepNow ? "manual-" + UUID().uuidString : nil
                try self.publish(decision, environment: environment, explicitSleepToken: manualToken)
                reply(ClientEndpoint.encode(Response(status: self.status(environment))))
            } catch {
                if error is PolicyError || error is DecodingError {
                    reply(ClientEndpoint.encode(Response(status: self.status(self.sampler.sample()), error: error.localizedDescription)))
                } else {
                    self.fail(error)
                    reply(ClientEndpoint.encode(Response(status: self.status(self.sampler.sample()), error: error.localizedDescription)))
                }
            }
        }
    }
    private func observeSafety() throws {
        guard let latch = try store.read("safety.json", as: SafetyLatch.self) else { return }
        let newlyObserved = acknowledgedSafety != latch.acknowledgment
        if newlyObserved {
            acknowledgedSafety = latch.acknowledgment
            _ = engine.interrupt(reason: latch.reason)
        }
        if let pending = try store.pendingSleepRequest() {
            pendingSleep = pending
        } else if latch.requestToken != nil {
            // Intent is not proof of dispatch: only the durable receipt allows us
            // to classify the guardian's sleep request as already consumed.
            if pendingSleep == latch.requestToken { pendingSleep = nil }
            if newlyObserved && latch.boot == store.boot { engine.observedSleep() }
        }
    }
    func enforceRuntime(_ decision: Decision, environment: Environment) throws -> Decision {
        if try store.exists("maintenance") { return engine.interrupt(reason: "安装、升级或卸载维护中，已停止保活。") }
        if recoveryPending {
            try power.restore()
            guard try !power.readActual() else { throw ServiceError("故障恢复尚未确认，继续停止保活。") }
            recoveryPending = false
            return engine.interrupt(reason: "故障后已确认恢复正常休眠，等待恢复条件持续满足。")
        }
        guard decision.keepAwake else { return decision }
        guard let gui = guiHeartbeat, environment.now >= gui, environment.now - gui <= LidKeepPaths.leaseSeconds,
              guiUID == SystemSampler.consoleUID, owner != nil else {
            return engine.interrupt(reason: "菜单栏心跳已失联，已撤销保活。")
        }
        let observation = try ServiceResourceReading.readGuardian(read: { try store.read("guardian.json", as: GuardianState.self) })
        guard ServiceResourceReading.guardianReady(observation.guardian, boot: store.boot, now: observation.checkedAt) else {
            return engine.interrupt(reason: "独立监护未就绪或已失联，已撤销保活。")
        }
        return decision
    }
    private func publish(_ decision: Decision, environment: Environment, explicitSleepToken: String? = nil) throws {
        if decision.requestSleep {
            let latch = try store.latch(decision.reason, sleep: true, token: explicitSleepToken)
            acknowledgedSafety = latch.acknowledgment; pendingSleep = latch.requestToken
        }
        if let token = pendingSleep, let receipts = try store.read("sleep-receipt.json", as: SleepReceipts.self), receipts.tokens.contains(token) {
            pendingSleep = nil
        }
        try store.write(engine, to: "policy.json")
        let desired = DesiredState(boot: store.boot, session: session, monotonic: Monotonic.now,
                                   guiHeartbeat: guiHeartbeat, guiUID: guiUID, wantsAwake: decision.keepAwake,
                                   mode: decision.mode, stopPercent: engine.preferences.stopPercent,
                                   testDeadline: engine.testDeadline, acknowledgedSafety: acknowledgedSafety,
                                   sleepToken: pendingSleep)
        // Publishing power intent shares the command lock; a queued guardian can
        // only read the newest intent, never an earlier copy saved in a callback.
        try store.withLock {
            try store.write(desired, to: "desired.json")
            if !desired.wantsAwake {
                try power.restoreLocked()
                // Manual/low/thermal requests remain possible while guardian is down.
                if let token = pendingSleep, try !store.exists("maintenance") { try power.sleepLocked(token: token) }
            }
        }
        if lastDesired?.mode != desired.mode || lastDesired?.wantsAwake != desired.wantsAwake {
            store.log("policy-transition", ["from": lastDesired?.mode.rawValue ?? "startup",
                                             "to": desired.mode.rawValue,
                                             "wantsAwake": String(desired.wantsAwake),
                                             "reason": decision.reason])
        }
        lastDesired = desired; lastFault = nil
        if decision.mode == .testing {
            store.log("trial-sample", ["battery": environment.batteryPercent.map(String.init(describing:)) ?? "unknown",
                                        "lid": environment.lidClosed.map(String.init) ?? "unknown",
                                        "externalDisplays": environment.externalDisplayCount.map(String.init) ?? "unknown",
                                        "network": String(environment.networkConnected), "mono": String(environment.now)])
        }
    }
    private func tick() {
        guard !stopped else { return }
        do {
            try observeSafety()
            let environment = sampler.sample()
            let decision = try enforceRuntime(engine.evaluate(environment), environment: environment)
            if !decision.keepAwake && lastDesired?.wantsAwake == true {
                // Safety is published before waiting for a potentially stuck writer.
                let latch = try store.latch(decision.reason, sleep: decision.requestSleep)
                acknowledgedSafety = latch.acknowledgment
            }
            try publish(decision, environment: environment)
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        var failures = [error.localizedDescription]
        recoveryPending = true
        guiHeartbeat = nil; guiUID = nil; owner = nil
        _ = engine.interrupt(reason: error.localizedDescription)
        // A metadata failure must not skip the independent power restoration.
        do {
            let latch = try store.latch(error.localizedDescription)
            acknowledgedSafety = latch.acknowledgment
        } catch { failures.append("保护记录失败：\(error.localizedDescription)") }
        do { try store.write(engine, to: "policy.json") }
        catch { failures.append("策略保存失败：\(error.localizedDescription)") }
        let safe = DesiredState(boot: store.boot, session: session, monotonic: Monotonic.now,
                                guiHeartbeat: nil, guiUID: nil, wantsAwake: false, mode: .fault,
                                stopPercent: engine.preferences.stopPercent, testDeadline: nil,
                                acknowledgedSafety: acknowledgedSafety, sleepToken: pendingSleep)
        do {
            try store.withLock {
                do { try store.write(safe, to: "desired.json"); lastDesired = safe }
                catch { failures.append("撤销请求保存失败：\(error.localizedDescription)") }
                try power.restoreLocked()
            }
        } catch {
            // Keep the existing hung-writer recovery, but never depend on a
            // successful metadata update before attempting restoration.
            do {
                if let process = try store.read("guardian-process.json", as: ProcessIdentity.self) {
                    try process.terminateHungWatchdog(store: store)
                    try power.restore()
                } else { throw error }
            } catch { failures.append("恢复失败：\(error.localizedDescription)") }
        }
        lastFault = failures.joined(separator: "; ")
        store.log("daemon-fault", ["error": lastFault ?? "unknown"])
    }
    func status(_ environment: Environment) -> RuntimeStatus {
        var actual: Bool?
        var mode = engine.mode
        var reason = lastFault ?? engine.reason
        do {
            actual = try power.readActual()
            let owned = try store.read("ownership.json", as: Ownership.self) != nil
            if mode == .active || mode == .testing {
                if actual != true || !owned { mode = .fault; reason = "等待监护确认电源设置；当前尚未确认保活生效。" }
            } else if actual == true {
                mode = .fault
                reason = owned ? "保活尚未撤销；正在重试恢复正常休眠。" : "其他工具已禁用系统休眠，LidKeep 没有接管该设置。"
            }
        } catch {
            fail(ServiceError("无法核对实际休眠设置：\(error.localizedDescription)"))
            mode = .fault; reason = lastFault ?? engine.reason
            // Remain unknown for this response; only a subsequent successful
            // observation can claim that restoration actually took effect.
            actual = nil
        }
        if lastFault != nil { mode = .fault }
        let own = ServiceResourceReading.current(name: "lidkeep-daemon")
        let observation = try? ServiceResourceReading.readGuardian(read: { try store.read("guardian.json", as: GuardianState.self) })
        let resources = ServiceResourceReading.includingFreshGuardian(
            own: own, guardian: observation?.guardian,
            boot: store.boot, now: observation?.checkedAt ?? Monotonic.now)
        return RuntimeStatus(preferences: engine.preferences, mode: mode, reason: reason,
                             batteryPercent: environment.batteryPercent, onAC: environment.onAC,
                             thermal: environment.thermal, sleepDisabled: actual, verified: engine.verified,
                             testRemainingSeconds: engine.testRemainingSeconds, testEvidence: engine.testEvidence,
                             serviceProcesses: resources)
    }
}

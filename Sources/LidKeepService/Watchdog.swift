import Foundation
import Darwin
import LidKeepCore

final class Watchdog {
    private let store: SecureStore
    private let power: PowerController
    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "local.rl.lidkeep.watchdog.serial")
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var lastActual: Bool?
    private var lastError: String?
    private var stopped = false
    private var recoveryFailures = 0
    private let restartAfterFailure: () -> Void
    private let sampleOverride: (() -> Environment)?
    private let consoleUser: () -> uid_t?
    init(store: SecureStore, power: PowerController? = nil,
         sample: (() -> Environment)? = nil, consoleUser: @escaping () -> uid_t? = { SystemSampler.consoleUID },
         restartAfterFailure: @escaping () -> Void = { exit(EXIT_FAILURE) }) {
        self.store = store; self.power = power ?? PowerController(store: store)
        self.sampleOverride = sample; self.consoleUser = consoleUser
        self.restartAfterFailure = restartAfterFailure
    }
    private func environment() -> Environment { sampleOverride?() ?? sampler.sample() }
    func start() throws {
        try store.write(ProcessIdentity.current(boot: store.boot, role: "--watchdog"), to: "guardian-process.json")
        _ = try store.latch("独立监护已重启；先恢复正常休眠，再重新确认保活条件。")
        try power.restore()
        try heartbeat()
        sampler.changed = { [weak self] in self?.queue.async { self?.tick() } }
        sampler.sleepEvent = { [weak self] wake, acknowledge in
            guard let self else { acknowledge(); return }
            self.queue.async {
                defer { acknowledge() }
                do {
                    _ = try self.store.latch(wake ? "系统刚唤醒，等待新心跳和恢复条件。" : "系统即将休眠，已撤销保活。")
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
                do { _ = try self.store.latch("独立监护退出，已撤销保活。"); try self.power.restore() }
                catch { self.store.log("shutdown-restore-error", ["error": error.localizedDescription]) }
                exit(0)
            }
            source.resume(); signals.append(source)
        }
    }
    private func heartbeat() throws {
        try store.write(GuardianState(boot: store.boot, monotonic: Monotonic.now,
                                      sleepDisabled: lastActual, error: lastError,
                                      diagnostic: ServiceResourceReading.current(name: "lidkeep-watchdog")), to: "guardian.json")
    }
    private func tick() {
        guard !stopped else { return }
        do {
            // A heartbeat before bounded operations allows the daemon to distinguish
            // routine command work from a guardian that has stopped responding.
            try heartbeat()
            try store.withLock { try reconcileLocked() }
            lastActual = try power.readActual()
            lastError = nil
            recoveryFailures = 0
            try heartbeat()
        } catch { fail(error) }
    }
    func fail(_ error: Error) {
        lastError = error.localizedDescription
        do { _ = try store.latch(lastError!) }
        catch { lastError = "\(lastError!); 保护记录失败：\(error.localizedDescription)" }
        do {
            try power.restore()
            lastActual = try power.readActual()
            recoveryFailures = 0
        } catch {
            lastError = "\(lastError!); 恢复失败：\(error.localizedDescription)"; lastActual = nil
            recoveryFailures += 1
        }
        try? heartbeat()
        store.log("watchdog-fault", ["error": lastError ?? "unknown"])
        if recoveryFailures >= 3 {
            // A live heartbeat cannot repair an exhausted process. launchd will
            // create a fresh writer, whose startup restores before accepting intent.
            stopped = true
            store.log("watchdog-restart-after-recovery-failure")
            restartAfterFailure()
        }
    }
    private func valid(_ desired: DesiredState, now: Double) -> Bool {
        guard desired.boot == store.boot, now >= desired.monotonic,
              now - desired.monotonic <= LidKeepPaths.leaseSeconds,
              let gui = desired.guiHeartbeat, now >= gui, now - gui <= LidKeepPaths.leaseSeconds,
              desired.guiUID != nil, desired.guiUID == consoleUser(),
              desired.stopPercent.isFinite, desired.stopPercent >= 1, desired.stopPercent < 100 else { return false }
        return true
    }
    func reconcileLocked() throws {
        if try store.exists("maintenance") { try power.restoreLocked(); return }
        // Finish a durable sleep intent even if a prior process restored ownership
        // and died before dispatch, or the primary/GUI lease has since expired.
        if let token = try store.pendingSleepRequest() {
            try power.sleepLocked(token: token)
            return
        }
        let desired = try store.read("desired.json", as: DesiredState.self)
        let environment = self.environment()
        let stop = desired.flatMap { value -> Double? in
            value.stopPercent.isFinite && value.stopPercent >= 1 && value.stopPercent < 100 ? value.stopPercent : nil
        } ?? 10
        let owned = try store.read("ownership.json", as: Ownership.self) != nil
        if !environment.validBattery {
            _ = try store.latch("监护无法读取有效电池数据，已撤销保活。")
            try power.restoreLocked(); return
        }
        if environment.thermal.dangerous || environment.batteryPercent! < stop {
            // The independent monitor sleeps only while LidKeep owns the setting.
            // This prevents waking a manually resumed computer causing a sleep loop.
            let reason = environment.thermal.dangerous ? "监护检测到高温或未知热状态。" : "监护检测到低电量。"
            let latch = try store.latch(reason, sleep: owned)
            try power.restoreLocked()
            if let token = latch.requestToken { try power.sleepLocked(token: token) }
            return
        }
        guard let desired, valid(desired, now: environment.now) else {
            _ = try store.latch("主服务或菜单栏心跳失联，已撤销保活。")
            try power.restoreLocked(); return
        }
        if let deadline = desired.testDeadline, !deadline.isFinite || environment.now >= deadline {
            // Expected trial expiry is an automatic rollback, not a failure latch:
            // the policy must still be able to expose its collected evidence.
            try power.restoreLocked(); return
        }
        if let token = desired.sleepToken {
            try power.sleepLocked(token: token)
            return
        }
        if !desired.wantsAwake { try power.restoreLocked(); return }
        if let latch = try store.read("safety.json", as: SafetyLatch.self) {
            guard desired.acknowledgedSafety == latch.acknowledgment else { try power.restoreLocked(); return }
            // The serial policy explicitly processed this latch and completed its
            // recovery dwell (or the user explicitly initiated a new safe trial).
            guard desired.mode == .active || desired.mode == .testing else { try power.restoreLocked(); return }
            guard try store.removeLatch(ifMatching: latch) else { try power.restoreLocked(); return }
        }
        // Check AGAIN inside the command lock immediately before changing power.
        // There is no queued copy of an enable request outside this lock.
        let latest = self.environment()
        guard latest.validBattery, !latest.thermal.dangerous, latest.batteryPercent! >= desired.stopPercent,
              valid(desired, now: latest.now), try !store.exists("maintenance"),
              try store.read("safety.json", as: SafetyLatch.self) == nil else {
            try power.restoreLocked(); return
        }
        try power.enableLocked {
            let newest = self.environment()
            guard newest.validBattery, !newest.thermal.dangerous, newest.batteryPercent! >= desired.stopPercent,
                  self.valid(desired, now: newest.now), try !self.store.exists("maintenance"),
                  try self.store.read("safety.json", as: SafetyLatch.self) == nil else {
                throw ServiceError("电源命令前保护条件已改变，已取消开启。")
            }
        }
    }
}

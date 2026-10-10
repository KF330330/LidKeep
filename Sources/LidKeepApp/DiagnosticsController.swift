import AppKit
import IOKit
import LidKeepCore
import LidKeepDiagnostics

struct DiagnosticUIState {
    var enabled: Bool
    var recording = false
    var busy = false
    var message = "合盖诊断：待命"
}

/// Resource collection and disk IO never run on the GUI heartbeat or power queues.
final class DiagnosticsController {
    var onChange: ((DiagnosticUIState) -> Void)?
    let directory: URL
    // Internal access permits deterministic tests on the actual serial queue.
    let queue = DispatchQueue(label: "local.rl.lidkeep.diagnostics", qos: .utility)
    private let sampler = ResourceSampler()
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let readLid: () -> Bool?
    private let readThermal: () -> ThermalLevel
    private let wallClock: () -> Date
    private let uptime: () -> Double
    private let collect: ((DiagnosticContext) throws -> ResourceSnapshot)?
    private let startTimer: Bool
    private var archive: DiagnosticArchive?
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var status: RuntimeStatus?
    private var state: DiagnosticUIState
    private var lastSample: Double?
    private var manual = false
    private var failed = false
    private var previousThermal: ThermalLevel?
    private var previousMode: String?
    private var systemSleeping = false

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LidKeep/Diagnostics", isDirectory: true),
         defaults: UserDefaults = .standard, notificationCenter: NotificationCenter? = nil,
         lidReading: (() -> Bool?)? = nil, thermalReading: (() -> ThermalLevel)? = nil,
         wallClock: @escaping () -> Date = Date.init,
         uptime: @escaping () -> Double = { Monotonic.now },
         collect: ((DiagnosticContext) throws -> ResourceSnapshot)? = nil, startTimer: Bool = true) {
        self.directory = directory; self.defaults = defaults
        self.notificationCenter = notificationCenter ?? NSWorkspace.shared.notificationCenter
        self.readLid = lidReading ?? Self.lidClosed
        self.readThermal = thermalReading ?? Self.thermalLevel
        self.wallClock = wallClock; self.uptime = uptime; self.collect = collect; self.startTimer = startTimer
        let value = defaults.object(forKey: "automaticDiagnostics") as? Bool ?? true
        state = DiagnosticUIState(enabled: value)
    }

    deinit {
        timer?.cancel()
        observers.forEach { notificationCenter.removeObserver($0) }
    }

    func start() {
        let center = notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    let sleeping = note.name == NSWorkspace.willSleepNotification
                    let transitioned = self.systemSleeping != sleeping
                    self.systemSleeping = sleeping
                    guard transitioned, !self.manual, self.state.enabled, !self.failed,
                          let archive = self.archive else { return }
                    do {
                        if self.state.recording {
                            if sleeping { try self.capture() }
                            try self.finish(sleeping
                                            ? "系统即将休眠" : "系统已唤醒；此前采集可能存在缺口")
                        } else {
                            // Sleep can arrive before the five-second lid poll. Keep
                            // a bounded event with the actual observation, even when
                            // no closed-lid session has started; never fill the gap.
                            self.sampler.reset()
                            try archive.begin(kind: sleeping ? "系统休眠事件" : "系统唤醒事件",
                                              at: self.wallClock(), event: sleeping ? .sleep : .wake)
                            try self.capture()
                            try self.finish(sleeping ? "系统即将休眠；事件处理时单次观测"
                                            : "系统已唤醒；单次观测，不回填休眠期间数据")
                        }
                    } catch { self.recordError(error) }
                }
            })
        }
        queue.async { [weak self] in
            guard let self else { return }
            do { self.archive = try DiagnosticArchive(directory: self.directory) }
            catch { self.recordError(error) }
            if self.startTimer {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: 5, leeway: .seconds(1))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer
                timer.resume()
            }
            self.publish()
        }
    }

    func update(_ status: RuntimeStatus?) {
        queue.async { [weak self] in self?.status = status }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "automaticDiagnostics")
        queue.async { [weak self] in
            guard let self else { return }
            self.state.enabled = enabled
            do {
                if !enabled, self.state.recording, !self.manual { try self.finish("用户关闭自动诊断") }
                if enabled, self.failed {
                    self.archive = try DiagnosticArchive(directory: self.directory)
                    self.failed = false
                }
                self.state.message = enabled ? "合盖诊断：待命" : "自动合盖诊断已关闭"
                self.tick()
                self.publish()
            } catch { self.recordError(error) }
        }
    }

    func checkNow(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.manual else { self.deliver(.failure(DiagnosticFailure("检查正在进行，请稍候。")), completion); return }
            do {
                if self.archive == nil { self.archive = try DiagnosticArchive(directory: self.directory) }
                self.failed = false
                if self.state.recording {
                    try self.capture()
                    guard let url = try self.archive?.currentReport() else { throw DiagnosticFailure("尚无报告。") }
                    self.deliver(.success(url), completion)
                    return
                }
                self.manual = true
                self.state.busy = true
                self.state.message = "正在检查内存与 CPU…"
                self.sampler.reset()
                try self.archive?.begin(kind: "手动检查", at: self.wallClock())
                try self.capture()
                self.publish()
                // Two real samples are needed for CPU deltas; no busy waiting.
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self else { return }
                    defer { self.manual = false; self.state.busy = false; self.publish() }
                    do {
                        try self.capture()
                        guard let url = try self.archive?.finish(reason: "手动检查完成", at: self.wallClock()) else { throw DiagnosticFailure("未生成报告。") }
                        self.state.message = "检查完成 · 可查看诊断报告"
                        self.deliver(.success(url), completion)
                    } catch { self.recordError(error); self.deliver(.failure(error), completion) }
                }
            } catch {
                self.manual = false; self.state.busy = false
                self.recordError(error); self.deliver(.failure(error), completion)
            }
        }
    }

    func report(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard let url = try self.archive?.currentReport() else {
                    throw DiagnosticFailure("还没有诊断记录。可以先点“立即检查内存与 CPU”，或合盖后再查看。")
                }
                self.deliver(.success(url), completion)
            } catch { self.deliver(.failure(error), completion) }
        }
    }

    func tick() {
        guard !manual, !failed, !systemSleeping else { return }
        do {
            let lid = readLid()
            if state.enabled, lid == true, !state.recording {
                sampler.reset()
                try archive?.begin(kind: "自动合盖记录", at: wallClock())
                state.recording = true
                try capture()
            } else if state.recording, lid == false {
                try capture()
                try finish("已开盖")
            } else if state.recording, uptime() - (lastSample ?? 0) >= 30 {
                try capture()
            } else if state.recording, uptime() - (lastSample ?? 0) >= 5 {
                let current = context()
                if current.thermal != previousThermal || current.mode != previousMode { try capture() }
            }
            publish()
        } catch { recordError(error) }
    }

    private func capture() throws {
        let snapshot = try autoreleasepool { try collect?(context()) ?? sampler.sample(context: context()) }
        try archive?.append(snapshot)
        lastSample = uptime()
        previousThermal = snapshot.context.thermal
        previousMode = snapshot.context.mode
        if state.recording {
            let time = DateFormatter.localizedString(from: snapshot.timestamp, dateStyle: .none, timeStyle: .short)
            state.message = "正在记录合盖资源 · 最近 \(time)"
        }
    }

    private func context() -> DiagnosticContext {
        let fresh = status.map { (-5...15).contains(wallClock().timeIntervalSince($0.updatedAt)) } ?? false
        return DiagnosticContext(lidClosed: readLid(), thermal: readThermal(),
                                 batteryPercent: fresh ? status?.batteryPercent : nil,
                                 onAC: fresh ? status?.onAC : nil,
                                 sleepDisabled: fresh ? status?.sleepDisabled : nil,
                                 mode: fresh ? status?.mode.rawValue : nil,
                                 reason: fresh ? status?.reason : "电源后台状态缺失或过期",
                                 statusFresh: fresh, serviceProcesses: fresh ? status?.serviceProcesses : nil)
    }

    private func finish(_ reason: String) throws {
        _ = try archive?.finish(reason: reason, at: wallClock())
        state.recording = false
        lastSample = nil
        state.message = "合盖诊断已保存 · 可查看报告"
        publish()
    }

    private func recordError(_ error: Error) {
        failed = true
        state.recording = false
        archive = nil // A retry recovers the unfinished file as interrupted.
        state.message = "诊断暂停：\(error.localizedDescription)"
        publish()
    }

    private func publish() {
        let value = state
        DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
    }

    private func deliver(_ result: Result<URL, Error>, _ completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                             kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    private static func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }
}

private struct DiagnosticFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

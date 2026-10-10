import Foundation
import LidKeepCore
import UserNotifications

enum AlertPermission: Equatable { case allowed, denied, notDetermined, failed(String) }

protocol AlertPosting: AnyObject {
    func requestAuthorization(_ completion: @escaping (AlertPermission) -> Void)
    func currentPermission(_ completion: @escaping (AlertPermission) -> Void)
    /// nil: the system accepted the request; otherwise an error description, including missing permission.
    func post(title: String, body: String, completion: @escaping (String?) -> Void)
}

/// Main-queue only. Lid-closed fair-thermal reminder; never changes power settings.
final class ThermalAlertController {
    var onChange: ((_ enabled: Bool, _ message: String) -> Void)?
    private(set) var enabled: Bool
    private let defaults: UserDefaults
    private let poster: AlertPosting
    private let lidReading: () -> Bool?
    private let uptime: () -> Double
    private let wallClock: () -> Date
    private var policy = ThermalAlertPolicy()
    private var permission = AlertPermission.notDetermined
    private var lastDeliveredText: String?

    init(defaults: UserDefaults = .standard, poster: AlertPosting,
         lidReading: @escaping () -> Bool?,
         uptime: @escaping () -> Double = { Monotonic.now },
         wallClock: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.poster = poster; self.lidReading = lidReading
        self.uptime = uptime; self.wallClock = wallClock
        enabled = defaults.object(forKey: "thermalAlertEnabled") as? Bool ?? true
        // Keep the 30-minute interval across app restarts; a clock set backwards counts as recent.
        if let date = defaults.object(forKey: "thermalAlertLastDelivered") as? Date {
            let elapsed = wallClock().timeIntervalSince(date)
            if elapsed < ThermalAlertPolicy.minimumIntervalSeconds {
                policy.restoreLastAlert(at: uptime() - max(0, elapsed))
            }
            lastDeliveredText = Self.deliveredText(date)
        }
    }

    func start() {
        if enabled { requestAuthorization() } else { publish() }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "thermalAlertEnabled")
        self.enabled = enabled
        if enabled {
            requestAuthorization()
        } else {
            policy.reset()
            publish()
        }
    }

    func observe(_ status: RuntimeStatus?) {
        guard enabled else { return }
        let fresh = status.map { abs(wallClock().timeIntervalSince($0.updatedAt)) <= 15 } ?? false
        let keepingAwake = status?.sleepDisabled == true && (status?.mode == .active || status?.mode == .testing)
        let observation = ThermalAlertPolicy.classify(lidClosed: lidReading(), statusFresh: fresh,
                                                      keepingAwake: keepingAwake, thermal: status?.thermal ?? .unknown)
        guard let duration = policy.observe(now: uptime(), observation) else { return }
        let start = DateFormatter.localizedString(from: wallClock().addingTimeInterval(-duration),
                                                  dateStyle: .none, timeStyle: .short)
        let body = "已持续约 \(Int(duration / 60)) 分钟（自 \(start) 起）。LidKeep 仍保持电脑运行，尚未达到高温保护；建议检查散热或减少后台任务。"
        poster.post(title: "合盖运行时系统热状态略高", body: body) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.policy.failed(at: self.uptime())
                    self.onChange?(self.enabled, "热状态提醒发送失败，5 分钟后若仍偏高会重试：\(error)")
                } else {
                    self.policy.delivered(at: self.uptime())
                    // Success implies the poster saw an authorized notification setting.
                    self.permission = .allowed
                    let now = self.wallClock()
                    self.defaults.set(now, forKey: "thermalAlertLastDelivered")
                    self.lastDeliveredText = Self.deliveredText(now)
                    self.publish()
                }
            }
        }
    }

    func refreshPermission() {
        poster.currentPermission { [weak self] permission in
            DispatchQueue.main.async {
                guard let self else { return }
                self.permission = permission
                self.publish()
            }
        }
    }

    /// Bypasses the policy and never affects the automatic reminder interval.
    func sendTest() {
        poster.currentPermission { [weak self] permission in
            DispatchQueue.main.async {
                guard let self else { return }
                guard permission == .notDetermined else { self.postTest(permission); return }
                self.poster.requestAuthorization { [weak self] permission in
                    DispatchQueue.main.async { self?.postTest(permission) }
                }
            }
        }
    }

    private func postTest(_ permission: AlertPermission) {
        self.permission = permission
        guard permission == .allowed else { publish(showPermission: true); return }
        poster.post(title: "LidKeep 测试通知", body: "合盖运行时热状态「略高」持续 5 分钟，LidKeep 会这样提醒你。") { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.onChange?(self.enabled, "测试通知发送失败：\(error)") }
                else { self.publish(showPermission: true) }
            }
        }
    }

    private func requestAuthorization() {
        poster.requestAuthorization { [weak self] permission in
            DispatchQueue.main.async {
                guard let self else { return }
                self.permission = permission
                self.publish()
            }
        }
    }

    // Test results report the permission even while automatic reminders are off.
    private func publish(showPermission: Bool = false) {
        var message: String
        if !enabled && !showPermission {
            message = "已关闭热状态提醒。"
        } else {
            switch permission {
            case .allowed: message = "已允许通知。提醒为静音通知，合盖时屏幕关闭，开盖后可在通知中心查看。"
            case .denied: message = "通知权限未开启：请到「系统设置 → 通知 → LidKeep 合盖运行」允许通知。"
            case .notDetermined: message = "尚未获得通知权限；勾选开关后系统会询问。"
            case .failed(let reason): message = "无法使用系统通知：\(reason)"
            }
        }
        if let lastDeliveredText { message += "\n上次热状态提醒：\(lastDeliveredText)（已送达通知中心）" }
        onChange?(enabled, message)
    }

    // Includes the date so a reminder from an earlier day is not mistaken for today's.
    private static func deliveredText(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .medium)
    }
}

/// Real notification sender. Never constructed in tests: xctest has no regular app bundle.
final class SystemAlertPoster: NSObject, AlertPosting, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization(_ completion: @escaping (AlertPermission) -> Void) {
        // No sound: reminders stay silent.
        center.requestAuthorization(options: [.alert]) { _, error in
            if let error { completion(.failed(error.localizedDescription)); return }
            self.currentPermission(completion)
        }
    }

    func currentPermission(_ completion: @escaping (AlertPermission) -> Void) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional: completion(.allowed)
            case .denied: completion(.denied)
            case .notDetermined: completion(.notDetermined)
            @unknown default: completion(.failed("未知的通知权限状态"))
            }
        }
    }

    func post(title: String, body: String, completion: @escaping (String?) -> Void) {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                completion("通知权限未开启")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil
            let request = UNNotificationRequest(identifier: "local.rl.lidkeep.thermal." + UUID().uuidString,
                                                content: content, trigger: nil)
            self.center.add(request) { error in completion(error?.localizedDescription) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

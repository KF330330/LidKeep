import AppKit
import LidKeepCore
import ServiceManagement

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    var saveThresholds: ((Double, Double, @escaping (String?) -> Void) -> Void)?
    private let stopField = NSTextField(string: "10")
    private let resumeField = NSTextField(string: "20")
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录时启动 LidKeep", target: nil, action: nil)
    private let loginFeedback = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "保存电量设置", target: nil, action: nil)
    private var dirty = false
    private var saving = false
    private var connected = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LidKeep 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 16
        body.translatesAutoresizingMaskIntoConstraints = false
        let description = NSTextField(wrappingLabelWithString: "低于停止阈值时解除保活并休眠。达到恢复阈值且温度持续正常 60 秒后恢复。")
        description.preferredMaxLayoutWidth = 414
        body.addArrangedSubview(description)
        body.addArrangedSubview(row(label: "停止电量（%）", field: stopField))
        body.addArrangedSubview(row(label: "恢复电量（%）", field: resumeField))
        loginCheckbox.target = self
        loginCheckbox.action = #selector(changeLogin)
        body.addArrangedSubview(loginCheckbox)
        loginFeedback.textColor = .secondaryLabelColor
        loginFeedback.preferredMaxLayoutWidth = 414
        loginFeedback.maximumNumberOfLines = 3
        body.addArrangedSubview(loginFeedback)
        saveButton.target = self
        saveButton.action = #selector(save)
        body.addArrangedSubview(saveButton)
        feedback.textColor = .secondaryLabelColor
        feedback.preferredMaxLayoutWidth = 414
        body.addArrangedSubview(feedback)
        window.contentView!.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            body.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            body.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        for field in [stopField, resumeField] {
            NotificationCenter.default.addObserver(self, selector: #selector(fieldChanged),
                                                   name: NSControl.textDidChangeNotification, object: field)
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func row(label: String, field: NSTextField) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.widthAnchor.constraint(equalToConstant: 160).isActive = true
        field.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let row = NSStackView(views: [title, field])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    func open(preferences: Preferences?, connected: Bool) {
        if !saving { dirty = false }
        update(preferences: preferences, connected: connected)
        feedback.stringValue = connected ? "" : "后台未连接，安装并连接后可保存电量设置。"
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(preferences: Preferences?, connected: Bool) {
        self.connected = connected
        if !dirty, !saving, let preferences {
            stopField.stringValue = Self.format(preferences.stopPercent)
            resumeField.stringValue = Self.format(preferences.resumePercent)
        }
        updateSaveControls()
        let state = SMAppService.mainApp.status
        loginCheckbox.state = state == .enabled || state == .requiresApproval ? .on : .off
        loginCheckbox.isEnabled = Bundle.main.bundlePath == LidKeepPaths.app
        updateLoginFeedback()
    }

    private func updateSaveControls() {
        saveButton.isEnabled = connected && !saving
        stopField.isEnabled = connected && !saving
        resumeField.isEnabled = connected && !saving
        saveButton.title = saving ? "正在保存…" : "保存电量设置"
    }

    func recordLoginError(_ message: String) {
        UserDefaults.standard.set(message, forKey: "loginRegistrationError")
        updateLoginFeedback()
    }

    private func updateLoginFeedback() {
        if let error = UserDefaults.standard.string(forKey: "loginRegistrationError") {
            loginFeedback.stringValue = "上次登录启动设置失败，可在此重试：\(error)"
        } else if SMAppService.mainApp.status == .requiresApproval {
            loginFeedback.stringValue = "请在系统设置 → 通用 → 登录项中允许 LidKeep。"
        } else {
            loginFeedback.stringValue = ""
        }
        loginFeedback.toolTip = loginFeedback.stringValue
    }

    @objc private func fieldChanged() { dirty = true }

    @objc private func save() {
        guard connected, !saving, let saveThresholds else { return }
        guard let stop = Double(stopField.stringValue), let resume = Double(resumeField.stringValue),
              Preferences.validThresholds(stop: stop, resume: resume) else {
            feedback.stringValue = "停止电量须至少 1%，恢复电量须更高且不超过 100%。"
            return
        }
        saving = true
        updateSaveControls()
        saveThresholds(stop, resume) { [weak self] error in
            guard let self else { return }
            self.saving = false
            self.feedback.stringValue = error ?? "电量设置已保存。"
            if error == nil { self.dirty = false }
            self.updateSaveControls()
        }
    }

    @objc private func changeLogin() {
        let enabled = loginCheckbox.state == .on
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(enabled, forKey: "loginLaunchRequested")
            UserDefaults.standard.removeObject(forKey: "loginRegistrationError")
            updateLoginFeedback()
        } catch {
            loginCheckbox.state = enabled ? .off : .on
            recordLoginError(error.localizedDescription)
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

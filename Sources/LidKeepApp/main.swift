import AppKit
import LidKeepCore
import ServiceManagement
import LidKeepDiagnostics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = ServiceClient()
    private let settings = SettingsWindow()
    private let diagnostics = DiagnosticsController()
    private let diagnosticsWindow = DiagnosticsWindow()
    private var diagnosticState = DiagnosticUIState(enabled: true)
    private var thermalAlerts: ThermalAlertController?
    private let diagnosticHeadline = NSMenuItem(title: "合盖诊断：正在准备…", action: nil, keyEquivalent: "")
    private var diagnosticToggle: NSMenuItem!
    private var diagnosticCheck: NSMenuItem!
    private var item: NSStatusItem!
    private var status: RuntimeStatus?
    private var unavailableReason = "正在连接后台…"
    private var heartbeat: Timer?
    private var activity: NSObjectProtocol?
    private var commandPending = false
    private var terminating = false
    private let headline = NSMenuItem(title: "正在连接后台…", action: nil, keyEquivalent: "")
    private let batteryItem = NSMenuItem(title: "电量：未知", action: nil, keyEquivalent: "")
    private let thermalItem = NSMenuItem(title: "温度：未知", action: nil, keyEquivalent: "")
    private let reasonItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let evidenceItem = NSMenuItem(title: "尚无合盖测试记录", action: nil, keyEquivalent: "")
    private var toggleItem: NSMenuItem!
    private var beginItem: NSMenuItem!
    private var confirmItem: NSMenuItem!
    private var cancelItem: NSMenuItem!
    private var sleepItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        client.onStatus = { [weak self] status, error in
            guard let self, !self.terminating else { return }
            self.status = status
            self.diagnostics.update(status)
            if let error { self.unavailableReason = error }
            self.render()
        }
        diagnostics.onChange = { [weak self] state in
            guard let self else { return }
            self.diagnosticState = state
            self.diagnosticHeadline.title = self.clipped(state.message)
            self.diagnosticHeadline.toolTip = state.message
            self.diagnosticToggle.state = state.enabled ? .on : .off
            self.diagnosticCheck.isEnabled = !state.busy
        }
        diagnosticsWindow.refresh = { [weak self] in self?.showDiagnosticReport() }
        diagnostics.start()
        settings.saveThresholds = { [weak self] stop, resume, completion in
            guard let self else { completion("程序已退出"); return }
            self.client.send(Request(.setThresholds, stopPercent: stop, resumePercent: resume)) { result in
                switch result {
                case .success: completion(nil)
                case .failure(let error): completion(error.localizedDescription)
                }
            }
        }
        // Created at launch only, so tests never touch the notification center or create windows.
        let thermalAlerts = ThermalAlertController(poster: SystemAlertPoster(), presenter: ThermalAlertDialog(), lidReading: DiagnosticsController.lidClosed)
        thermalAlerts.onChange = { [weak self] enabled, message in
            self?.settings.updateThermalAlert(enabled: enabled, message: message)
        }
        settings.thermalAlertChanged = { [weak thermalAlerts] enabled in thermalAlerts?.setEnabled(enabled) }
        settings.sendTestAlert = { [weak thermalAlerts] in thermalAlerts?.sendTest() }
        settings.sendDelayedTestAlert = { [weak thermalAlerts] in thermalAlerts?.sendDelayedTest() }
        self.thermalAlerts = thermalAlerts
        thermalAlerts.start()
        // Keep the lease sender out of App Nap without asserting against display or system sleep.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "发送合盖保护心跳")
        registerLoginDefault()
        heartbeat = Timer(timeInterval: LidKeepPaths.sampleSeconds, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        heartbeat?.invalidate()
        heartbeat = nil
        client.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func registerLoginDefault() {
        guard Bundle.main.bundlePath == LidKeepPaths.app,
              UserDefaults.standard.object(forKey: "loginLaunchRequested") == nil else { return }
        // One registration attempt: a later user change in System Settings must stay authoritative.
        UserDefaults.standard.set(true, forKey: "loginLaunchRequested")
        if SMAppService.mainApp.status == .notRegistered {
            do { try SMAppService.mainApp.register() }
            catch { settings.recordLoginError(error.localizedDescription) }
        }
    }

    private func buildMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = Bundle.main.url(forResource: "StatusIcon", withExtension: "pdf")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "infinity", accessibilityDescription: "LidKeep")
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true
        item.button?.imagePosition = .imageOnly
        item.button?.image = icon
        item.button?.title = ""
        item.button?.setAccessibilityLabel("LidKeep")
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in [headline, batteryItem, thermalItem, reasonItem] {
            entry.isEnabled = false
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        toggleItem = add("启用合盖运行", #selector(toggle), to: menu)
        sleepItem = add("立即休眠", #selector(sleepNow), to: menu)
        menu.addItem(.separator())
        beginItem = add("开始 3 分钟合盖测试…", #selector(beginTest), to: menu)
        confirmItem = add("确认合盖测试结果…", #selector(confirmTest), to: menu)
        cancelItem = add("取消当前测试", #selector(cancelTest), to: menu)
        evidenceItem.isEnabled = false
        menu.addItem(evidenceItem)
        menu.addItem(.separator())
        diagnosticHeadline.isEnabled = false
        menu.addItem(diagnosticHeadline)
        diagnosticToggle = add("自动记录合盖诊断", #selector(toggleDiagnostics), to: menu)
        diagnosticCheck = add("立即检查内存与 CPU…", #selector(checkDiagnostics), to: menu)
        add("查看最近诊断报告…", #selector(showDiagnosticReport), to: menu)
        add("打开诊断文件夹", #selector(openDiagnosticsFolder), to: menu)
        menu.addItem(.separator())
        add("设置…", #selector(openSettings), to: menu).keyEquivalent = ","
        add("使用说明…", #selector(showHelp), to: menu)
        menu.addItem(.separator())
        add("退出 LidKeep", #selector(quit), to: menu).keyEquivalent = "q"
        item.menu = menu
        render()
    }

    @discardableResult private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    private func tick() {
        guard !terminating else { return }
        if let status, Date().timeIntervalSince(status.updatedAt) > 15 {
            self.status = nil
            unavailableReason = "后台状态已过期；正在重连"
            render()
        }
        thermalAlerts?.observe(status)
        client.send(Request(.heartbeat))
    }

    private func render() {
        guard item != nil else { return }
        let connected = status != nil
        let trialInProgress = status?.mode == .testing || status?.testRemainingSeconds != nil
        toggleItem.isEnabled = connected && !commandPending
        sleepItem.isEnabled = connected && !commandPending
        beginItem.isEnabled = connected && !commandPending
            && !trialInProgress && status?.mode != .awaitingConfirmation
        cancelItem.isEnabled = !commandPending && trialInProgress
        confirmItem.isEnabled = !commandPending && status?.mode == .awaitingConfirmation
        settings.update(preferences: status?.preferences, connected: connected)
        guard let status else {
            item.button?.toolTip = "LidKeep：后台未连接，无法确认保活状态"
            item.button?.setAccessibilityLabel("LidKeep：后台未连接，保活状态未知")
            headline.title = "后台未连接 · 保活状态未知"
            reasonItem.title = clipped(unavailableReason)
            reasonItem.toolTip = unavailableReason
            batteryItem.title = "电量：未知"
            thermalItem.title = "系统热状态：未知"
            toggleItem.state = .off
            evidenceItem.title = "连接后台后显示测试记录"
            return
        }
        let effective = status.sleepDisabled == true
        var displayedReason = status.reason
        if status.mode == .active && effective {
            headline.title = "合盖运行已开启"
        } else if status.mode == .active {
            headline.title = "保活状态不一致，请检查后台"
        } else if status.mode == .testing && effective {
            let remaining = max(0, status.testRemainingSeconds ?? 0)
            headline.title = "合盖测试中 · 剩余 \(remaining) 秒"
        } else if trialInProgress && !effective {
            headline.title = "测试尚未生效 · 等待电源状态确认"
            displayedReason = "请保持开盖，点击菜单栏 ∞，确认菜单顶部显示“合盖测试中”后再锁屏合盖。"
        } else {
            headline.title = status.mode.label
        }
        item.button?.toolTip = "LidKeep：\(headline.title)\n\(displayedReason)"
        item.button?.setAccessibilityLabel("LidKeep：\(headline.title)")
        let battery = status.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "未知"
        batteryItem.title = "电量：\(battery) · \(status.onAC ? "已接电源" : "电池供电")"
        thermalItem.title = "系统热状态：\(status.thermal.label)"
        reasonItem.title = clipped(displayedReason)
        reasonItem.toolTip = displayedReason
        toggleItem.state = status.preferences.enabled ? .on : .off
        toggleItem.title = status.verified ? "启用合盖运行" : "启用合盖运行（需先通过验收）"
        evidenceItem.title = clipped(status.testEvidence ?? "尚无合盖测试记录")
        evidenceItem.toolTip = status.testEvidence
    }

    private func clipped(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " · ")
        return singleLine.count > 65 ? String(singleLine.prefix(65)) + "…" : singleLine
    }

    private func perform(_ request: Request) {
        commandPending = true
        render()
        client.send(request) { [weak self] result in
            guard let self else { return }
            self.commandPending = false
            self.render()
            if case .failure(let error) = result { self.showError(error.localizedDescription) }
        }
    }

    @objc private func toggle() {
        guard let status else { return }
        perform(Request(.setEnabled, enabled: !status.preferences.enabled))
    }

    @objc private func sleepNow() { perform(Request(.sleepNow)) }
    @objc private func cancelTest() { perform(Request(.cancelTest)) }

    @objc private func beginTest() {
        guard status != nil else { return }
        let alert = NSAlert()
        alert.messageText = "开始短时合盖兼容性测试"
        alert.informativeText = "请拔掉电源、断开所有外接显示器，连接手机热点，并在 Codex 或 Claude Code 中启动一个可核对进度的任务。\n\n点击开始后，点击菜单栏 ∞，确认菜单顶部显示“合盖测试中”，再锁屏（Control-Command-Q）并合盖至少 60 秒，然后打开电脑。测试最长 180 秒，结束后自动恢复正常休眠设置。你需要确认 AI 任务和网络实际持续工作，才会启用长期保活。\n\n测试时放在通风处，不要装进包内。"
        alert.addButton(withTitle: "开始测试")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { perform(Request(.beginTest)) }
    }

    @objc private func confirmTest() {
        guard status?.mode == .awaitingConfirmation else { return }
        let alert = NSAlert()
        alert.messageText = "确认真实合盖测试结果"
        alert.informativeText = "\(status?.testEvidence ?? "请核对测试期间的实际运行情况。")\n\n三项全部确认后才能通过验收。任何一项未通过，请选择“测试未通过”。"
        let checks = [
            "合盖至少 60 秒，AI 任务持续推进",
            "电池供电、无外接显示器，手机热点持续联网",
            "合盖时屏幕熄灭，打开后仍需解锁"
        ].map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
        let stack = NSStackView(views: checks)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 430, height: 94)
        alert.accessoryView = stack
        alert.addButton(withTitle: "确认通过")
        alert.addButton(withTitle: "测试未通过")
        alert.addButton(withTitle: "稍后确认")
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        // Recheck the current mode: a fault or expired lease may arrive while the alert is open.
        guard status?.mode == .awaitingConfirmation else { return }
        if result == .alertFirstButtonReturn {
            guard checks.allSatisfy({ $0.state == .on }) else {
                showError("尚未确认全部测试条件，验收状态未改变。")
                return
            }
            perform(Request(.confirmTest, testSucceeded: true))
        } else if result == .alertSecondButtonReturn {
            perform(Request(.confirmTest, testSucceeded: false))
        }
    }

    @objc private func openSettings() {
        thermalAlerts?.refreshPermission()
        settings.open(preferences: status?.preferences, connected: status != nil)
    }

    @objc private func toggleDiagnostics() { diagnostics.setEnabled(!diagnosticState.enabled) }

    @objc private func checkDiagnostics() {
        diagnostics.checkNow { [weak self] result in self?.presentDiagnostic(result) }
    }

    @objc private func showDiagnosticReport() {
        diagnostics.report { [weak self] result in self?.presentDiagnostic(result) }
    }

    private func presentDiagnostic(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error): showError(error.localizedDescription)
        case .success(let url):
            // Bounded report IO is kept off the GUI heartbeat queue.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let data = try file.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
                    guard data.count <= 2 * 1024 * 1024, let report = String(data: data, encoding: .utf8) else {
                        throw NSError(domain: "LidKeep", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "诊断报告过大或编码无效。"])
                    }
                    DispatchQueue.main.async { self?.diagnosticsWindow.show(report) }
                } catch { DispatchQueue.main.async { self?.showError(error.localizedDescription) } }
            }
        }
    }

    @objc private func openDiagnosticsFolder() { NSWorkspace.shared.open(diagnostics.directory) }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "LidKeep · 合盖运行"
        alert.informativeText = "首次使用请运行 LidKeep 安装包，并完成菜单中的 3 分钟合盖测试。只有验收通过才会开启长期保活。\n\n低于停止电量或系统高温时，后台先解除保活，再请求休眠。用户唤醒后不会反复被强制休眠；达到恢复电量且温度正常 60 秒后恢复。手动关闭状态会保留。\n\n合盖运行时若系统热状态「略高」持续 5 分钟，会在屏幕中央弹窗提醒（无提示音，两次至少间隔 30 分钟），并在通知中心留一条记录；可在设置中关闭。\n\n退出 App 或心跳失联后，后台会解除保活（最迟约 30 秒，外加检查间隔）。菜单中的状态来自后台；“未连接”表示当前状态未知。\n\n合盖运行需要持续联网，并应保持通风。程序不控制 AI 会话，也不会自动解决网络中断、授权等待或请求失败。"
        alert.addButton(withTitle: "知道了")
        if let readme = Bundle.main.url(forResource: "README", withExtension: "md") {
            alert.addButton(withTitle: "打开完整说明")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(readme) }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func showError(_ message: String) {
        guard !terminating else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "操作未完成"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// Exercise the installed executable without AppKit, login registration or XPC.
if Array(CommandLine.arguments.dropFirst()) == ["--self-check"] {
    print("LidKeep executable check OK")
    exit(0)
}
// A bounded local diagnostic export, without launching the menu, XPC, or changing power.
let diagnosticArguments = Array(CommandLine.arguments.dropFirst())
if diagnosticArguments.count == 2, diagnosticArguments[0] == "--diagnostics-check" {
    do {
        let archive = try DiagnosticArchive(directory: URL(fileURLWithPath: diagnosticArguments[1], isDirectory: true))
        let sampler = ResourceSampler()
        let context = DiagnosticContext(lidClosed: nil, thermal: .unknown, batteryPercent: nil,
                                        onAC: nil, sleepDisabled: nil, mode: nil,
                                        reason: "命令行资源检查未连接电源后台", statusFresh: false)
        try archive.begin(kind: "手动命令行检查")
        try archive.append(try sampler.sample(context: context))
        Thread.sleep(forTimeInterval: 1)
        try archive.append(try sampler.sample(context: context))
        if let report = try archive.finish(reason: "检查完成") { print(report.path) }
        exit(0)
    } catch { fputs("LidKeep diagnostics: \(error.localizedDescription)\n", stderr); exit(1) }
}
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()

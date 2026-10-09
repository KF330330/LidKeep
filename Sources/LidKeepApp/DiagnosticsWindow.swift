import AppKit
import UniformTypeIdentifiers

final class DiagnosticsWindow: NSWindowController {
    var refresh: (() -> Void)?
    private let text = NSTextView()
    private var reportText = ""

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "LidKeep · 合盖资源诊断"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let body = NSStackView()
        body.orientation = .vertical; body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView()
        let refreshButton = NSButton(title: "刷新报告", target: self, action: #selector(reload))
        let exportButton = NSButton(title: "导出报告…", target: self, action: #selector(exportReport))
        buttons.addArrangedSubview(refreshButton); buttons.addArrangedSubview(exportButton)
        body.addArrangedSubview(buttons)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        text.isEditable = false; text.isSelectable = true; text.usesFindPanel = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        body.addArrangedSubview(scroll)
        let note = NSTextField(wrappingLabelWithString: "报告仅保存在本机。高占用表示观测结果，不能单独证明内存泄漏；采样缺口会标为未知。")
        note.textColor = .secondaryLabelColor
        body.addArrangedSubview(note)
        window.contentView!.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18),
            body.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16),
            body.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])
        window.minSize = NSSize(width: 600, height: 420)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ content: String) {
        reportText = content; text.string = content
        showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func reload() { refresh?() }

    @objc private func exportReport() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "LidKeep-诊断报告.md"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try self.reportText.write(to: url, atomically: true, encoding: .utf8) }
            catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: window)
            }
        }
    }
}

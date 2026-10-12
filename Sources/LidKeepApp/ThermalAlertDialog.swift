import AppKit

/// Centered, non-modal reminder window. A modal session would stall the heartbeat timer on the main run loop.
final class ThermalAlertDialog: NSWindowController, AlertPresenting {
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LidKeep 提醒"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
        let icon = NSImageView(image: NSImage(named: NSImage.cautionName)!)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .boldSystemFont(ofSize: 15)
        bodyLabel.preferredMaxLayoutWidth = 330
        let button = NSButton(title: "知道了", target: self, action: #selector(acknowledge))
        button.keyEquivalent = "\r"
        let text = NSStackView(views: [titleLabel, bodyLabel, button])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 10
        text.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(icon)
        content.addSubview(text)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            icon.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            text.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            text.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Replaces any reminder already on screen instead of stacking windows.
    func present(title: String, body: String) {
        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        // Fixed width; the height follows the wrapped body so no text is clipped.
        let height = window.contentView?.fittingSize.height ?? 180
        window.setContentSize(NSSize(width: 440, height: height))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func acknowledge() { window?.orderOut(nil) }
}

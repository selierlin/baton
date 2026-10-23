import AppKit

/// 提示框的统一入口。
///
/// ### 为什么不用 `NSAlert.runModal()`
///
/// Baton 是 `.accessory` 应用，实测（macOS 15）从状态栏菜单项触发时**无法激活自己**：
/// `setActivationPolicy(.regular)` + `activate()` 连等 2 秒，`NSApp.isActive` 依然是 false。
/// 而 `runModal` 会先占住主线程：窗口停在「已 order 但没上屏」的状态，
/// 菜单也被模态循环吃掉 —— 用户看到的就是「点一下，整个 App 卡死」。
///
/// 所以这里改成**非模态浮动面板**：`orderFrontRegardless()` + `.floating` 级，
/// 和贴图窗口同一套机制（贴图在前台是别的 App 时也能显示）。
/// 不阻塞主线程、不要求激活，按 Esc 等同取消。
@MainActor
public enum ModalAlert {
    /// 弹一个提示，返回用户点的按钮下标。`cancelIndex` 用于 Esc 与关闭。
    public static func show(title: String,
                            message: String,
                            buttons: [String],
                            cancelIndex: Int,
                            name: String,
                            above overlay: NSWindow? = nil) async -> Int {
        // 菜单动作是在追踪会话收尾阶段执行的，让出一轮再弹，避免和新窗口抢 order
        await yieldMainTurn()
        ActionLog.modal("open", "name=\(name) policy=\(policyName) overlay=\(overlay != nil)")

        let panel = AlertPanel(title: title, message: message,
                               titles: buttons, cancelIndex: cancelIndex)
        panel.level = overlay?.level ?? .floating
        let started = Date()
        let index = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            panel.onFinish = { index in continuation.resume(returning: index) }
            panel.present()
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        ActionLog.modal("close", "name=\(name) response=\(index) ms=\(elapsed)")
        return index
    }

    /// 确认框：返回 `true` 表示用户点了主动作。
    public static func confirm(title: String,
                               message: String,
                               confirm confirmTitle: String,
                               cancel cancelTitle: String = "取消",
                               name: String,
                               above overlay: NSWindow? = nil) async -> Bool {
        await show(title: title, message: message,
                   buttons: [confirmTitle, cancelTitle], cancelIndex: 1,
                   name: name, above: overlay) == 0
    }

    /// 只提示，不要结果。
    public static func notify(title: String,
                              message: String,
                              name: String,
                              above overlay: NSWindow? = nil) {
        Task { @MainActor in
            _ = await show(title: title, message: message, buttons: ["好"],
                           cancelIndex: 0, name: name, above: overlay)
        }
    }

    /// 同步模态：**只给「调用时 Baton 已经是前台」的入口用**（例如覆盖层里的按钮）。
    /// 菜单动作里绝对不能用，会卡死。
    @discardableResult
    public static func runInline(_ alert: NSAlert,
                                 name: String,
                                 above overlay: NSWindow? = nil) -> NSApplication.ModalResponse {
        guard NSApp.isActive else {
            // 不是前台就别进模态循环，否则就是一个没人看得见的框
            ActionLog.fail("modal.notActive", "name=\(name)")
            return .abort
        }
        if let busy = NSApp.modalWindow {
            ActionLog.fail("modal.nested", "name=\(name) blockedBy=\(busy.title)")
            return .abort
        }
        if let overlay { alert.window.level = overlay.level }
        ActionLog.modal("open", "name=\(name) inline=1")
        let started = Date()
        HangWatchdog.shared.modalEntered()
        let response = alert.runModal()
        HangWatchdog.shared.modalExited()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        ActionLog.modal("close", "name=\(name) response=\(response.rawValue) ms=\(elapsed)")
        return response
    }

    // MARK: - 内部

    private static func yieldMainTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static var policyName: String {
        switch NSApp.activationPolicy() {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }
}

/// 仿系统警示框的浮动面板。非模态：显示期间主线程照常跑，App 不会「卡死」。
@MainActor
final class AlertPanel: NSPanel {
    var onFinish: ((Int) -> Void)?

    private let cancelIndex: Int
    private var finished = false

    init(title: String, message: String, titles: [String], cancelIndex: Int) {
        self.cancelIndex = cancelIndex
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 140),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        build(title: title, message: message, titles: titles)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present() {
        center()
        orderFrontRegardless()
        makeKey()
        if !isVisible { ActionLog.fail("alert.invisible") }
    }

    override func cancelOperation(_ sender: Any?) {
        finish(cancelIndex)
    }

    // MARK: - 布局

    private func build(title: String, message: String, titles: [String]) {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        // 纯视觉模糊在浅色背景上仍然能看穿到下面的文字，正文读起来很累；
        // 压一层接近不透明的底色，保留毛玻璃的边缘感又不牺牲可读性。
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill",
                             accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.preferredMaxLayoutWidth = 300

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.preferredMaxLayoutWidth = 300

        let text = NSStackView(views: [titleLabel, messageLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6

        let head = NSStackView(views: [icon, text])
        head.orientation = .horizontal
        head.alignment = .top
        head.spacing = 10

        var buttons: [NSButton] = []
        for (index, title) in titles.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(buttonTapped(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            // 主动作走 Return，取消项走 Esc
            if index == 0 {
                button.keyEquivalent = "\r"
            } else if index == cancelIndex {
                button.keyEquivalent = "\u{1b}"
            }
            buttons.append(button)
        }

        let row = NSStackView(views: buttons.reversed())
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        // 不用 NSStackView 的 edgeInsets 收边：垂直栈的 alignment 会对齐到栈的边界而不是内容区，
        // 结果按钮行会顶出面板右缘被圆角裁掉。这里用普通容器 + 显式约束，边距是多少就是多少。
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        head.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(head)
        content.addSubview(row)

        effect.addSubview(tint)
        effect.addSubview(content)
        contentView = effect
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            effect.widthAnchor.constraint(equalToConstant: 380),

            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -16),

            head.topAnchor.constraint(equalTo: content.topAnchor),
            head.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            head.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),

            row.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // 高度按内容算：message 可能是两三行，写死高度会截字
        effect.layoutSubtreeIfNeeded()
        let height = head.fittingSize.height + 18 + row.fittingSize.height + 18 + 16
        setContentSize(NSSize(width: 380, height: max(height, 120)))
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        finish(sender.tag)
    }

    private func finish(_ index: Int) {
        guard !finished else { return }
        finished = true
        orderOut(nil)
        onFinish?(index)
        onFinish = nil
    }
}

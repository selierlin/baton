import AppKit

/// 延迟截图的倒计时面板。
///
/// 不抢焦点：用户这几秒往往要去打开菜单、切页面，面板弹成 key 反而打断操作。
/// Esc 用全局监听收——面板不是 key window，键盘事件到不了它。
@MainActor
public final class CountdownHUD: NSPanel {
    public var onFinish: (() -> Void)?
    public var onCancel: (() -> Void)?

    private var remaining: Int
    private var timer: Timer?
    private var escMonitor: Any?
    private var localMonitor: Any?
    private let numberLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    public init(seconds: Int, screen: NSScreen? = nil) {
        self.remaining = max(1, seconds)
        let target = screen ?? NSScreen.main
        let visible = target?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 220, height: 124)
        let frame = CGRect(x: visible.midX - size.width / 2,
                           y: visible.midY - size.height / 2 + visible.height * 0.18,
                           width: size.width,
                           height: size.height)

        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 54, weight: .semibold)
        numberLabel.alignment = .center
        numberLabel.textColor = .labelColor
        numberLabel.stringValue = "\(remaining)"

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.alignment = .center
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.stringValue = "秒后截图 · 按 Esc 取消"

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .inline
        cancel.isBordered = false

        let stack = NSStackView(views: [numberLabel, hintLabel, cancel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        contentView = effect
    }

    public func start() {
        orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // 面板不激活，普通键盘事件不会送进来，只能走全局监听
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.cancel() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel()
            return nil
        }
    }

    public func dismiss() {
        timer?.invalidate()
        timer = nil
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        escMonitor = nil
        localMonitor = nil
        orderOut(nil)
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            dismiss()
            onFinish?()
            return
        }
        numberLabel.stringValue = "\(remaining)"
    }

    @objc private func cancelTapped() { cancel() }

    private func cancel() {
        guard timer != nil else { return }
        dismiss()
        onCancel?()
    }
}

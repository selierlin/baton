import AppKit

/// 录制中的浮动控制条：红点 + 计时 + 停止 / 取消。
///
/// 和倒计时面板同一套路：`.nonactivatingPanel`，不抢焦点——录制时用户要回去操作
/// 被录的 App，控制条一激活就把人家切走了。所以 Esc 只能靠全局监听收。
@MainActor
public final class RecordingBar: NSPanel {
    public var onStop: (() -> Void)?
    public var onCancel: (() -> Void)?
    /// 参数是「切换后是否暂停」
    public var onTogglePause: ((Bool) -> Void)?

    private let dot = NSView()
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let hintLabel = NSTextField(labelWithString: "")
    private var pauseButton: NSButton?
    private let titleText: String
    private var timer: Timer?
    /// 已暂停累计的时长：暂停时把 runningSince 结算进来，继续时重新起算
    private var accumulated: TimeInterval = 0
    private var runningSince: Date?
    private var escMonitor: Any?

    public init(title: String, screen: NSScreen? = nil, globalRect: CGRect? = nil) {
        self.titleText = title
        let target = screen ?? NSScreen.main
        let visible = target?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 260, height: 44)
        let frame = CGRect(x: visible.midX - size.width / 2,
                           y: visible.maxY - size.height - 12,
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        timeLabel.textColor = .labelColor
        // 计时器每秒改一次宽度，固定宽度免得整条面板跟着抖
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.stringValue = title
        // 标题吃掉多余宽度，把停止/取消顶到右边
        hintLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let pause = iconButton("pause.fill", tooltip: "暂停录制", action: #selector(pauseTapped))
        pauseButton = pause
        let stop = iconButton("stop.fill", tooltip: "停止并保存（Esc）", action: #selector(stopTapped))
        let cancel = iconButton("xmark", tooltip: "取消录制（不保存）", action: #selector(cancelTapped))

        let stack = NSStackView(views: [dot, timeLabel, hintLabel, pause, stop, cancel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        if let globalRect {
            place(near: globalRect, screen: target ?? NSScreen.main, size: size)
        }
    }

    /// 贴着选区放：优先正下方，下边放不下就翻到上方；左右夹在屏幕内。
    ///
    /// 坐标要从 CG 的左上原点换到 Cocoa 的左下原点，`mainScreenHeight` 的算法
    /// 和覆盖层保持一致，否则多屏时工具条会跑到另一块屏上。
    private func place(near globalRect: CGRect, screen: NSScreen?, size: CGSize) {
        guard let screen else { return }
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let gap: CGFloat = 10
        let top = mainScreenHeight - globalRect.minY          // 选区上边
        let bottom = mainScreenHeight - globalRect.maxY       // 选区下边

        var y = bottom - gap - size.height
        if y < screen.visibleFrame.minY {
            y = top + gap
        }
        // 上下都塞不下（整屏选区）：压到屏幕顶部，别盖住选区中央
        if y + size.height > screen.visibleFrame.maxY {
            y = screen.visibleFrame.maxY - size.height - 8
        }
        var x = globalRect.midX - size.width / 2
        x = max(screen.visibleFrame.minX + 8,
                min(x, screen.visibleFrame.maxX - size.width - 8))
        setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    public func start() {
        accumulated = 0
        runningSince = Date()
        orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // 不激活的面板收不到键盘，停止键只能全局监听
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.stopTapped() }
        }
    }

    public func dismiss() {
        timer?.invalidate()
        timer = nil
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        orderOut(nil)
    }

    /// 录到一半流断了：面板别装没事，改成报错状态等用户点掉。
    public func showFailure(_ text: String) {
        timer?.invalidate()
        timer = nil
        dot.layer?.backgroundColor = NSColor.systemGray.cgColor
        hintLabel.stringValue = text
    }

    private func tick() {
        let total = accumulated + (runningSince.map { Date().timeIntervalSince($0) } ?? 0)
        let seconds = Int(total)
        timeLabel.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// 录到一半的暂停：计时停住、红点变橙、按钮切成播放。
    private func setPaused(_ paused: Bool) {
        if paused {
            if let runningSince {
                accumulated += Date().timeIntervalSince(runningSince)
                self.runningSince = nil
            }
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            hintLabel.stringValue = "已暂停"
            pauseButton?.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "继续录制")
            pauseButton?.toolTip = "继续录制"
        } else {
            runningSince = Date()
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            hintLabel.stringValue = titleText
            pauseButton?.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "暂停录制")
            pauseButton?.toolTip = "暂停录制"
        }
        tick()
    }

    @objc private func pauseTapped() {
        let next = runningSince != nil
        setPaused(next)
        onTogglePause?(next)
    }

    @objc private func stopTapped() {
        guard timer != nil else { return }
        onStop?()
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    private func iconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.toolTip = tooltip
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }
}

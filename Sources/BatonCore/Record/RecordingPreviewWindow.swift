import AppKit
import AVKit

/// 录制结束后的预览窗。
///
/// 只弹一条「已保存」提示的话，用户没法确认到底录进去了什么——尤其是窗口/区域录制
/// 这种容易框错目标的场景。这里给一个能直接播放的预览，附带复制、定位、删除，
/// 关掉就等于确认收货（文件已经落盘，不需要再点保存）。
@MainActor
public final class RecordingPreviewWindow: NSPanel {
    private let url: URL
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    private var keyMonitor: Any?

    /// 用户点了删除；外部据此更新菜单/状态
    public var onDelete: ((URL) -> Void)?

    public init(url: URL, duration: Int, screen: NSScreen? = nil) {
        self.url = url
        self.player = AVPlayer(url: url)

        let contentSize = CGSize(width: 480, height: 318)
        let target = screen ?? NSScreen.main
        let visible = target?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: visible.midX - contentSize.width / 2,
                            y: visible.minY + 96)

        super.init(contentRect: CGRect(origin: origin, size: contentSize),
                   styleMask: [.titled, .closable],
                   backing: .buffered,
                   defer: false)

        // 标题就带时长，不再自绘一行，免得和系统标题栏重复
        title = "录制完成 · \(Self.durationText(duration))"
        isFloatingPanel = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .windowBackgroundColor

        let nameLabel = NSTextField(labelWithString: url.lastPathComponent)
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle

        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false

        let reveal = Self.actionButton("在 Finder 中显示", #selector(revealTapped), target: self)
        let copy = Self.actionButton("复制", #selector(copyTapped), target: self)
        let delete = Self.actionButton("删除", #selector(deleteTapped), target: self)
        delete.contentTintColor = .systemRed
        let done = Self.actionButton("完成", #selector(doneTapped), target: self)
        done.keyEquivalent = "\r"

        let actions = NSStackView(views: [reveal, copy, NSView(), delete, done])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10
        actions.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [nameLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(header)
        root.addSubview(playerView)
        root.addSubview(actions)
        contentView = root

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),

            playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            playerView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            playerView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),

            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            actions.heightAnchor.constraint(equalToConstant: 24),
        ])

        // 停在第一帧：不自动播，免得突然出声/跳帧；想看得自己点播放
        player.seek(to: CMTime(seconds: 0.05, preferredTimescale: 600))
    }

    public func show() {
        // 菜单栏应用（accessory）在别人前台时，makeKeyAndOrderFront 不一定能把窗推上来
        orderFrontRegardless()
        makeKey()
        NSApp.activate(ignoringOtherApps: true)

        // 空格播放/暂停，Esc 关掉——播放器自己吃不到键盘（面板焦点在按钮上）
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 49: // space
                if self.player.rate > 0 { self.player.pause() } else { self.player.play() }
                return nil
            case 53: // esc
                self.close()
                return nil
            default:
                return event
            }
        }
    }

    public override func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        player.pause()
        super.close()
    }

    // MARK: - 动作

    @objc private func revealTapped() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyTapped() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    @objc private func deleteTapped() {
        Task { [weak self] in
            guard let self else { return }
            let confirmed = await ModalAlert.confirm(title: "删除这段录制？",
                                                     message: "文件会移到废纸篓，可以从废纸篓恢复。",
                                                     confirm: "移到废纸篓",
                                                     name: "record.preview.delete",
                                                     above: self)
            guard confirmed else { return }
            NSWorkspace.shared.recycle([self.url]) { _, _ in }
            ActionLog.result("record.preview.delete", "file=\(self.url.lastPathComponent)")
            self.onDelete?(self.url)
            self.close()
        }
    }

    @objc private func doneTapped() {
        close()
    }

    // MARK: - 小工具

    private static func actionButton(_ title: String, _ action: Selector,
                                     target: AnyObject) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private static func durationText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

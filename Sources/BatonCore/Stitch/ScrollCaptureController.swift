import AppKit
import CoreGraphics

/// 长截图的采集阶段：覆盖层让路（透明 + 鼠标穿透），定时抓帧，停手自动收尾。
///
/// 为什么不监听滚动事件：滚轮落在下层 App 里，覆盖层已经穿透，拿不到；
/// 而「抓两帧比一比有没有前进」本身就是最可靠的停手信号，还省掉一次权限。
@MainActor
public final class ScrollCaptureController {
    public enum End: Sendable {
        case finished(CGImage)
        case cancelled
        case failed(String)
    }

    /// 抓帧间隔。
    ///
    /// 手在滚的时候必须抓得够密：间隔一大，两帧就没有重叠区，
    /// 中间那段从来没被拍到过，谁也补不回来（实测「滚太快中间漏一段」）。
    /// 复用 `RegionCaptureSession` 后单帧约 42ms（含 SCK 合成），
    /// 所以滚动期间压到 90ms，位移基本落在 1/4 屏内；停手后放松回 500ms。
    private static let activeInterval = Duration.milliseconds(90)
    private static let idleInterval = Duration.milliseconds(500)
    /// 上一帧前进过，多久之内算「还在滚」。
    private static let activeWindow: TimeInterval = 1.2

    /// 多久没有新内容算停手。
    ///
    /// 原来是「连续 4 次没进展」× 500ms = 2 秒：滚轮用户滚一屏、松手看一眼画面，
    /// 还没等再滚就被判定停手——正是实测「长图停在一屏」的现象之一。
    /// 改成按时间算，抓帧频率变化也不影响手感。
    private static let idleTimeout: TimeInterval = 4

    /// 整场最长时长（秒）。循环里按 `Date` 差值判断，不参与 sleep，故用 TimeInterval。
    private static let hardTimeout: TimeInterval = 90

    /// 超速状态最多续命几帧。90ms × 37 ≈ 3.3 秒，加上 4 秒停手判定，
    /// 一次连续猛甩能撑 7 秒左右；再久就按「用户可能已经切走了」处理。
    private static let overspeedGraceTicks = 37

    /// 回滚状态最多续命几帧。
    ///
    /// 滚到页面底部时系统会持续回弹几十帧，过去每一帧 `retreated` 都把停手时间重置，
    /// 结果明明已经不动了也不收尾，只能干等 90 秒硬超时（实测复现）。
    /// 给回滚也加一个上限：回滚本身不让停手判定打断，但最多宽限 3 秒。
    private static let retreatGraceTicks = 33

    private let selection: CaptureSelection
    private let overlay: OverlayController
    private var hud: ScrollHUD?
    private var finishRequested = false
    private var cancelRequested = false

    public init(selection: CaptureSelection, overlay: OverlayController) {
        self.selection = selection
        self.overlay = overlay
    }

    public func run() async -> End {
        guard let capturer = try? await RegionCaptureSession(rect: selection.globalRect,
                                                             display: selection.display),
              let first = try? await capturer.capture() else {
            return .failed("抓取首帧失败")
        }
        guard let session = ScrollCaptureSession(first: first) else {
            return .failed("首帧尺寸不可用")
        }

        overlay.enterScrollMode()
        restoreFocusUnderSelection()
        let hud = ScrollHUD(frame: hudFrame())
        hud.onFinish = { [weak self] in self?.finishRequested = true }
        hud.onCancel = { [weak self] in self?.cancelRequested = true }
        hud.update(thumbnail: session.thumbnail(), height: session.totalHeight, hint: "滚动页面开始截取")
        hud.orderFrontRegardless()
        self.hud = hud
        let trace = StitchTrace(session: session)

        let started = Date()
        var lastAdvanceAt = Date.distantPast
        var lastHudUpdate = Date.distantPast
        var advanced = false
        var misses = 0
        var overspeedTicks = 0
        var retreatTicks = 0

        while true {
            if cancelRequested { break }
            if finishRequested { break }
            if Date().timeIntervalSince(started) > Self.hardTimeout { break }

            let scrolling = Date().timeIntervalSince(lastAdvanceAt) < Self.activeWindow
            try? await Task.sleep(for: scrolling ? Self.activeInterval : Self.idleInterval)

            guard let frame = try? await capturer.capture() else {
                continue
            }
            let result = session.append(frame)
            trace.record(result, total: session.totalHeight,
                         gap: session.hasGap, retreating: session.isWaitingForForward)

            // 连续接不上多半是滚太快：两帧位移超过了拼接器 0.75 屏的能力边界。
            // 这时候要当场让用户看见，而不是等他截完了才发现中间断了一截。
            misses = (result.advanced || result.retreated || result.stationary) ? 0 : misses + 1
            let overspeed = misses >= 2

            let hint: String
            let warning: Bool
            if overspeed {
                hint = "滚得太快了，这一段可能没拍到 · 慢一点"
                warning = true
            } else if session.hasGap {
                hint = "已留下断点标记 · 可继续，或重截这一段"
                warning = true
            } else {
                hint = "继续滚动，停手 4 秒自动完成"
                warning = false
            }

            if result.retreated {
                // 用户往回翻：别让停手计时把他打断，翻完还能继续往下截。
                // 但回弹会连发几十帧，不能无限续命，所以按帧数封顶。
                retreatTicks += 1
                if retreatTicks <= Self.retreatGraceTicks {
                    lastAdvanceAt = Date()
                } else if Date().timeIntervalSince(lastAdvanceAt) > Self.idleTimeout {
                    break
                }
                hud.update(thumbnail: nil, height: session.totalHeight,
                           hint: "回滚中，长图只累计向下的内容", warning: false)
            } else if result.advanced {
                retreatTicks = 0
                advanced = true
                overspeedTicks = 0
                lastAdvanceAt = Date()
                // 缩略图每次都要把整张长图 makeImage + 降采样，跟帧率绑一起会白烧 CPU
                if Date().timeIntervalSince(lastHudUpdate) > 0.3 {
                    lastHudUpdate = Date()
                    hud.update(thumbnail: session.thumbnail(),
                               height: result.totalHeight,
                               hint: hint, warning: warning)
                } else {
                    hud.update(thumbnail: nil, height: result.totalHeight,
                               hint: hint, warning: warning)
                }
            } else if advanced {
                // 超速时画面确实在动，不刷新停手时间的话，用户甩超过 4 秒会被强制收尾
                // （甩动幅度越大越容易触发，正好是最需要继续采的时候）。
                // 但也不能无限续命——切走页面同样是「画面变了但拼不上」，所以只宽限 3 秒。
                if overspeed {
                    overspeedTicks += 1
                    if overspeedTicks <= Self.overspeedGraceTicks { lastAdvanceAt = Date() }
                } else {
                    overspeedTicks = 0
                    // 真正停住了，之前的回滚宽限可以作废
                    retreatTicks = 0
                }
                if Date().timeIntervalSince(lastAdvanceAt) > Self.idleTimeout { break }
                hud.update(thumbnail: session.thumbnail(),
                           height: session.totalHeight,
                           hint: hint, warning: warning)
            } else {
                retreatTicks = 0
            }

            if result.reachedLimit { break }
            if !advanced, Date().timeIntervalSince(started) > 8 {
                hud.update(thumbnail: session.thumbnail(),
                           height: session.totalHeight,
                           hint: "未检测到滚动，请把鼠标移到选区内滚动")
            }
        }

        hud.dismiss()
        self.hud = nil
        overlay.dismiss()
        trace.close(finalHeight: session.totalHeight, gap: session.hasGap)

        if cancelRequested { return .cancelled }
        guard advanced, let image = session.image() else {
            return .failed("没有检测到滚动内容")
        }
        return .finished(image)
    }

    /// 把焦点还给「选区底下那个 App」。
    ///
    /// 框选阶段 Baton 会 `NSApp.activate()` 抢前台，覆盖窗又是常驻最上层。
    /// 之后投递的滚动事件——尤其是平滑滚动插值出来的合成事件——会落到 Baton 自己的窗口上，
    /// 下层页面一动不动，看起来就是「长截图检测不到滚动」。实测 `front=BatonApp` 时
    /// 发出的 30 帧全部无效，把焦点还给 Safari 后立刻正常。
    private func restoreFocusUnderSelection() {
        let center = CGPoint(x: selection.globalRect.midX, y: selection.globalRect.midY)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return }

        for info in windows {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  owner != ProcessInfo.processInfo.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.contains(center),
                  let app = NSRunningApplication(processIdentifier: owner) else {
                continue
            }
            app.activate()
            return
        }
    }

    private func hudFrame() -> CGRect {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == selection.display.displayID
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // 选区是 CG 全局坐标（左上原点），面板用 Cocoa 全局坐标（左下原点）
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = CaptureGeometry.cocoaRect(fromGlobal: selection.globalRect,
                                              mainScreenHeight: mainHeight)

        let size = CGSize(width: 236, height: 200)
        let gap: CGFloat = 12
        // 优先贴选区右侧，右边放不下就翻到左侧，再不行夹在屏内
        var x = cocoa.maxX + gap
        if x + size.width > visible.maxX {
            x = cocoa.minX - gap - size.width
        }
        x = min(max(visible.minX + 8, x), visible.maxX - size.width - 8)
        let y = min(max(visible.minY + 8, cocoa.maxY - size.height), visible.maxY - size.height - 8)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

// MARK: - 诊断日志

/// 每轮长截图写一份逐帧日志到 `~/Library/Logs/Baton/stitch-*.log`。
///
/// 拼接出问题时用户只能描述「中间漏了一段」，没有帧级数据就只能猜。
/// 这里记时间、位移、误差、累计高度、缺口/回滚状态，事后能直接看出是哪一帧丢的。
@MainActor
private final class StitchTrace {
    private let url: URL
    private var handle: FileHandle?
    private let start = Date()

    init(session: ScrollCaptureSession) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Baton", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        url = dir.appendingPathComponent("stitch-\(formatter.string(from: start)).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        write("start frame=\(session.totalHeight)px")
    }

    func record(_ result: ScrollCaptureSession.AppendResult, total: Int,
                gap: Bool, retreating: Bool) {
        let state = result.advanced ? "adv"
            : (result.retreated ? "back" : (result.stationary ? "still" : "miss"))
        write(String(format: "t=%.2fs %@ offset=%d mae=%.1f total=%d gap=%d wait=%d",
                     Date().timeIntervalSince(start), state, result.offset, result.mae,
                     total, gap ? 1 : 0, retreating ? 1 : 0))
    }

    func close(finalHeight: Int, gap: Bool) {
        write("end height=\(finalHeight)px gap=\(gap ? 1 : 0)")
        try? handle?.close()
        handle = nil
    }

    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        handle?.write(data)
    }
}

// MARK: - HUD

@MainActor
private final class ScrollHUD: NSPanel {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var keyMonitor: Any?

    init(frame: CGRect) {
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

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail

        let finish = NSButton(title: "完成", target: self, action: #selector(finishTapped))
        finish.bezelStyle = .rounded
        finish.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [cancel, finish])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let text = NSStackView(views: [titleLabel, hintLabel, buttons])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4

        let row = NSStackView(views: [imageView, text])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .top

        effect.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            row.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
            imageView.widthAnchor.constraint(equalToConstant: 96),
            imageView.heightAnchor.constraint(equalToConstant: 170),
        ])

        contentView = effect

        // 面板不抢焦点，键盘事件到不了它身上；但用户已经养成「回车完成、Esc 取消」的习惯，
        // 而且点按钮时第一下常常只是激活窗口——两个口子都补上。
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 36, 76: Task { @MainActor in self?.finishTapped() }   // Return / Enter
            case 53: Task { @MainActor in self?.cancelTapped() }       // Esc
            default: break
            }
        }
    }

    override var canBecomeKey: Bool { true }

    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        orderOut(nil)
    }

    func update(thumbnail: CGImage?, height: Int, hint: String, warning: Bool = false) {
        if let thumbnail {
            imageView.image = NSImage(cgImage: thumbnail, size: .zero)
        }
        titleLabel.stringValue = "长截图 · \(height) px"
        hintLabel.stringValue = hint
        hintLabel.textColor = warning ? .systemOrange : .secondaryLabelColor
    }

    @objc private func finishTapped() { onFinish?() }
    @objc private func cancelTapped() { onCancel?() }
}

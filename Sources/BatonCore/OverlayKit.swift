import AppKit
import CoreGraphics
import QuartzCore

public struct CaptureSelection: Sendable {
    /// CG 全局显示坐标（点，左上原点）
    public let globalRect: CGRect
    public let display: DisplayFrame
    /// 悬停拾取命中窗口时带上它的 CGWindowID：窗口截图据此真实抓取，
    /// 不再从冻结帧里裁一块（被遮挡时那块是遮挡物）。
    public let windowID: Int?

    public init(globalRect: CGRect, display: DisplayFrame, windowID: Int? = nil) {
        self.globalRect = globalRect
        self.display = display
        self.windowID = windowID
    }
}

/// 覆盖层的交互形态：拖框，还是悬停拾取（窗口 / 元素）。
public enum OverlayMode: Sendable {
    case area
    case pick
    /// 只铺冻结帧、不压暗、不收鼠标：交给外部视图（尺子）自己处理交互。
    case bare
}

/// 悬停回调。第二个参数是当前这块屏，用来把跨屏窗口裁到本屏；
/// 第三个参数是拾取粒度，⇥ 切换「窗口区域（元素）」和「整窗」时由覆盖层传下来。
public typealias PickProbe = @MainActor (CGPoint, DisplayFrame, PickTarget.Kind) -> PickTarget?

/// 冻结帧覆盖层。一屏一个无边框窗，返回一次框选结果。
/// 只负责「画 + 收鼠标」，不认识截图之后的任何业务。
@MainActor
public final class OverlayController {
    private var windows: [OverlayWindow] = []
    private var views: [CGDirectDisplayID: OverlayView] = [:]
    private var activeDisplayID: CGDirectDisplayID?
    private var continuation: CheckedContinuation<CaptureSelection?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let mainScreenHeight: CGFloat
    /// 框选结束后把覆盖层留在屏幕上，供原地编辑/长截图接管。
    private var retainsSelection = false

    public init() {
        mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
    }

    public var isHolding: Bool { retainsSelection && !windows.isEmpty }

    /// 当前铺在屏幕上的覆盖窗。模态提示要压住它，得先知道它的层级。
    public var frontWindow: NSWindow? { windows.first }

    /// - Parameter keepsSelection: 为 true 时框选结束后不销毁窗口，遮罩与选区边框保持原样，
    ///   调用方通过 `hostView(for:)` 把编辑器挂进同一个覆盖层，结束后调 `dismiss()`。
    ///   Longshot 的标注就是长在截图覆盖层里的，不另开窗。
    public func select(from frames: [CapturedFrame],
                       mode: OverlayMode = .area,
                       probe: PickProbe? = nil,
                       keepsSelection: Bool = false,
                       initialSelection: CaptureSelection? = nil,
                       timeout: Duration = .seconds(300)) async -> CaptureSelection? {
        guard !frames.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            // 上一场会话若还停着（比如编辑态又按了截图热键），先收干净再开新场
            if !windows.isEmpty {
                let previous = self.continuation
                self.continuation = nil
                teardown()
                previous?.resume(returning: nil)
            }
            self.continuation = continuation
            self.retainsSelection = keepsSelection
            self.views.removeAll()
            OverlayRecovery.beginSession()

            for frame in frames {
                let (window, view) = makeWindow(for: frame, mode: mode, probe: probe)
                view.retainsSelection = keepsSelection
                view.onFinish = { [weak self] selection in
                    self?.finish(selection)
                }
                window.orderFrontRegardless()
                windows.append(window)
                views[frame.display.displayID] = view
            }

            windows.first?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            windows.first?.makeKey()

            // 固定选区（上次区域 / 联调探针）：直接锁住并交出舞台
            if let initialSelection {
                views[initialSelection.display.displayID]?.lockSelection(initialSelection.globalRect)
                finish(initialSelection)
                return
            }

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
        }
    }

    /// 把冻结帧铺满每块屏，不压暗、不等框选，直接把宿主视图交出去。
    ///
    /// 尺子这种「一进来就要能操作整屏」的会话用它：没有框选阶段，
    /// 交互全部由挂上去的子视图负责，结束时调用 `dismiss()`。
    public func stage(from frames: [CapturedFrame]) -> [NSView] {
        guard !frames.isEmpty else { return [] }

        // 上一场若还停着（编辑态又按了尺子热键），先收干净
        let previous = continuation
        continuation = nil
        teardown()
        previous?.resume(returning: nil)

        retainsSelection = false
        activeDisplayID = nil
        views.removeAll()
        OverlayRecovery.beginSession()

        var hosts: [NSView] = []
        for frame in frames {
            let (window, view) = makeWindow(for: frame, mode: .bare, probe: nil)
            window.orderFrontRegardless()
            windows.append(window)
            views[frame.display.displayID] = view
            hosts.append(view)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        return hosts
    }

    /// 覆盖层内的宿主视图，用来挂标注画布与工具条。
    public func hostView(for displayID: CGDirectDisplayID) -> NSView? {
        views[displayID]
    }

    private func makeWindow(for frame: CapturedFrame, mode: OverlayMode,
                            probe: PickProbe?) -> (OverlayWindow, OverlayView) {
        let cocoaRect = CaptureGeometry.cocoaRect(fromGlobal: frame.display.screenFrame,
                                                  mainScreenHeight: mainScreenHeight)
        let window = OverlayWindow(contentRect: cocoaRect)
        let view = OverlayView(frame: CGRect(origin: .zero, size: cocoaRect.size),
                               captured: frame,
                               mainScreenHeight: mainScreenHeight,
                               mode: mode,
                               probe: probe)
        window.contentView = view
        return (window, view)
    }

    /// 把 CG 全局矩形换算成覆盖层视图坐标。
    public func localRect(forGlobal rect: CGRect, displayID: CGDirectDisplayID) -> CGRect? {
        views[displayID]?.localFrame(forGlobal: rect)
    }

    private func finish(_ selection: CaptureSelection?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = self.continuation
        self.continuation = nil

        // 有选区且要原地编辑：只收起其它屏，选中屏留着，遮罩不拆
        if retainsSelection, let selection {
            activeDisplayID = selection.display.displayID
            for (displayID, view) in views where displayID != selection.display.displayID {
                view.window?.orderOut(nil)
            }
            // 多屏时 key window 可能停在别的屏，编辑器就收不到键盘
            views[selection.display.displayID]?.window?.makeKey()
            resume(continuation, with: selection)
            return
        }

        teardown()
        resume(continuation, with: selection)
    }

    private func resume(_ continuation: CheckedContinuation<CaptureSelection?, Never>?,
                        with selection: CaptureSelection?) {
        continuation?.resume(returning: selection)
    }

    /// 结束整场覆盖层会话。原地编辑、贴图、取消都走这里。
    public func dismiss() {
        timeoutTask?.cancel()
        timeoutTask = nil
        retainsSelection = false
        activeDisplayID = nil
        teardown()
        // 框选阶段被外部打断时 continuation 还挂着，resume 掉避免永久挂起
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: nil)
    }

    /// 当前停留的屏幕（编辑态下就是被框住的那块屏）。
    public var currentDisplayID: CGDirectDisplayID? { activeDisplayID }

    // MARK: - 诊断

    /// 场景跑测用：覆盖层还在不在屏幕上。
    public var debugOverlayVisible: Bool { !windows.isEmpty }

    /// 场景跑测用：锁定的选区（全局屏幕坐标）。遮罩和边框都按它画，
    /// 所以「选区改了但遮罩没跟上」这类问题就看这个值。
    public var debugLockedSelection: CGRect? {
        guard let id = activeDisplayID ?? views.keys.first else { return nil }
        return views[id]?.debugLockedSelection
    }

    /// 场景跑测用：按覆盖层自己的键位表发一次按键（框选阶段的 Esc / F / HJKL）。
    @discardableResult
    public func debugSendKey(_ keyCode: UInt16) -> Bool {
        guard let view = windows.first?.contentView,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: windows.first?.windowNumber ?? 0,
                                           context: nil, characters: "",
                                           charactersIgnoringModifiers: "", isARepeat: false,
                                           keyCode: keyCode) else { return false }
        view.keyDown(with: event)
        return true
    }

    /// 模态面板（保存对话框）要压在覆盖层之上，先临时把层降下来。
    public func setWindowLevel(_ level: NSWindow.Level) {
        for window in windows {
            window.level = level
        }
    }

    /// 进入长截图采集：撤掉冻结帧、鼠标穿透，让用户直接滚下面的页面。
    /// 遮罩（只压选区外）与蓝色边框留下，选区视觉不变。
    public func enterScrollMode() {
        for (_, view) in views {
            view.enterScrollMode()
        }
        for window in windows {
            window.ignoresMouseEvents = true
        }
    }

    private func teardown() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        views.removeAll()
        OverlayRecovery.endSession()
    }
}

final class OverlayWindow: NSWindow {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    private let captured: CapturedFrame
    private let mainScreenHeight: CGFloat
    private let mode: OverlayMode
    private let probe: PickProbe?
    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let sizeLayer = CATextLayer()
    /// 放大镜：对齐 Longshot —— 直角蓝框 + 15×15 像素内容 + 底部三行信息（坐标/区域/色值）。
    /// 15 格 × 9pt = 135pt，每格代表屏幕 1pt（2x 屏 2 个设备像素）—— 实测 Longshot
    /// 光标挪 1pt 格心正好滚 18 个设备像素，所以是 9 倍而不是 18 倍。
    private let magnifier = CALayer()
    private let magnifierContent = CALayer()
    private let magnifierGrid = CALayer()
    private let magnifierCross = CAShapeLayer()
    private let magnifierCellBox = CAShapeLayer()
    private let infoBar = CALayer()
    private let infoCoord = CATextLayer()
    private let infoArea = CATextLayer()
    private let infoColor = CATextLayer()
    private let infoColorLabel = CATextLayer()
    private let infoSwatch = CALayer()
    private static let magnifierCell: CGFloat = 9
    private static let magnifierCells: CGFloat = 15
    /// 中心「取色格」：外沿 25px、内空 16px（2x 屏），折算中心线 10.25pt。
    private static let magnifierHole: CGFloat = 10.25
    private static let magnifierSide = magnifierCell * magnifierCells
    private static let magnifierInfoHeight: CGFloat = 56
    private static let magnifierAccent = NSColor(srgbRed: 0, green: 0.518, blue: 1, alpha: 1)
    /// 内容缓存。三者都按「取哪一格」做键，同一格里不会变（冻结帧是 immutable），
    /// 所以换格时才需要重做裁图 / 取色 / 拼串。
    private var lastMagnifierSnap = CGPoint(x: -1, y: -1)
    private var lastColorSnap = CGPoint(x: -1, y: -1)
    private var lastColor: NSColor?
    private var lastInfoKeys = ""

    /// 放大镜里色值的显示格式，T 键循环。Longshot 的 `snipMagnifierColorStyleRawValue`
    /// 默认就是 hex，这里跟着默认。
    enum ColorFormat: Int, CaseIterable {
        case hex, rgb, hsl
    }
    private(set) var colorFormat: ColorFormat = .hex

    /// 框定后保留选区视觉，不再跟随鼠标重算。
    var retainsSelection = false
    private var lockedSelection: CGRect?     // CG 全局坐标
    /// 诊断用：当前锁定的选区（编辑态下就是画布底下那块）
    var debugLockedSelection: CGRect? { lockedSelection }
    /// 原地标注挂上来的画布。手柄外半边落在它外面，事件与光标要从这里转过去。
    weak var annotationCanvas: NSView?

    /// 悬停拾取的粒度。默认「窗口区域」（AX 元素，最精确），⇥ 切到整窗。
    private var pickKind: PickTarget.Kind = .element
    /// 未圈选时的左下角快捷键提示，规格照 Longshot 量出来的
    private let shortcutHint: ShortcutHintView

    private var anchor: CGPoint?      // CG 全局坐标
    private var current: CGPoint?
    private var hoverRect: CGRect?
    private var hoverLabel: String?
    private var hoverWindowID: Int?
    /// 按下瞬间的悬停目标：没拖动就按「单击选中它」处理
    private var pressedHover: (rect: CGRect, windowID: Int?)?
    /// 位移超过这个值才算拖框，否则当单击（触控板轻微抖动不该取消悬停目标）
    private static let dragThreshold: CGFloat = 3

    /// 未圈选时的提示行：文案和顺序照抄 Longshot `SnipLocalizable.strings` 的
    /// `snip_body_labelShortKey*`，但只留 Baton 真的会响应的键。它那 11 行里
    /// 「选择多个窗口 / 切换截图阴影 / 回溯区域 / 回溯截图」Baton 还没有对应能力，
    /// 写上去就是假提示 —— 按了没反应比不写更糟。
    ///
    /// 圈选之后左下角不再显示提示条（会让位给工具条），那几行由标注画布接管：
    /// 方向键移选区、⌘/⇧ 扩缩，和这里写的是同一套语义。
    private static func hintRows(pickable: Bool) -> [ShortcutHintView.Row] {
        var rows: [ShortcutHintView.Row] = [
            .init("移动光标 1 个像素", "K, J, H, L"),
            .init("移动捕获区域 1 个像素", "↑, ↓, ←, →"),
            .init("扩大 / 缩小捕获区域", "⌘ / ⇧ + 方向键"),
        ]
        if pickable {
            rows.append(.init("切换窗口/窗口区域", "⇥"))
        }
        rows.append(.init("选择全屏区域", "F"))
        if pickable {
            rows.append(.init("选中光标所在窗口", "↩"))
        }
        rows.append(.init("复制颜色值", "C"))
        rows.append(.init("切换颜色值样式", "T"))
        rows.append(.init("退出截图", "⎋ 或者 鼠标右键"))
        return rows
    }
    private var lastProbeAt: CFAbsoluteTime = 0
    private var lastProbePoint = CGPoint(x: -1000, y: -1000)
    /// 帧驱动：跟屏幕刷新率同步刷新放大镜
    private var frameLink: CADisplayLink?
    private var lastTickPoint = CGPoint(x: -1, y: -1)
    /// 放大镜相对光标的摆放方向（带迟滞，避免贴边时左右/上下反复横跳）
    private var magnifierOnRight = true
    private var magnifierOnTop = false
    private var lastWindowProbeAt: CFAbsoluteTime = 0
    private var windowProbe: CGRect?

    var onFinish: ((CaptureSelection?) -> Void)?

    init(frame: CGRect,
         captured: CapturedFrame,
         mainScreenHeight: CGFloat,
         mode: OverlayMode,
         probe: PickProbe?) {
        self.captured = captured
        self.mainScreenHeight = mainScreenHeight
        self.mode = mode
        self.probe = probe
        // 长截图没有 probe：⇥ / ↩ 在那儿不响应，提示条就少两行
        shortcutHint = ShortcutHintView(rows: Self.hintRows(pickable: probe != nil))
        super.init(frame: frame)
        wantsLayer = true

        // 冻结帧直接进 contents，不经过 NSImageView（会多一份 backing store）
        imageLayer.frame = bounds
        imageLayer.contents = captured.image
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        layer?.addSublayer(imageLayer)

        dimLayer.frame = bounds
        // Longshot 的遮罩是 #0000004C（30% 黑），不是更重的 45%
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.30).cgColor
        dimLayer.fillRule = .evenOdd
        // 尺子看的是原始画面：压暗会让取色和对比度都不准
        dimLayer.isHidden = mode == .bare
        layer?.addSublayer(dimLayer)

        borderLayer.frame = bounds
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.controlAccentColor.cgColor
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)

        sizeLayer.frame = .zero
        sizeLayer.fontSize = 11
        sizeLayer.alignmentMode = .center
        sizeLayer.foregroundColor = NSColor.white.cgColor
        sizeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        sizeLayer.cornerRadius = 3
        sizeLayer.isHidden = true
        layer?.addSublayer(sizeLayer)

        // MARK: 放大镜
        let side = Self.magnifierSide
        let cell = Self.magnifierCell
        let accent = Self.magnifierAccent

        magnifier.frame = .zero
        magnifier.masksToBounds = true
        magnifier.borderWidth = 2
        magnifier.borderColor = accent.cgColor
        magnifier.backgroundColor = NSColor.black.cgColor
        magnifier.isHidden = true

        // 内容区在上、信息区在下，一起被外框裁圆
        magnifierContent.frame = CGRect(x: 0, y: Self.magnifierInfoHeight, width: side, height: side)
        magnifierContent.contentsGravity = .resize
        // 放大要看到真实像素边界，插值会把 1px 的线糊掉
        magnifierContent.magnificationFilter = .nearest
        magnifierContent.minificationFilter = .nearest
        magnifier.addSublayer(magnifierContent)

        magnifierGrid.backgroundColor = Self.gridPattern(cell: cell,
                                                         scale: captured.display.nativeScale).cgColor
        magnifierGrid.frame = magnifierContent.bounds
        magnifierContent.addSublayer(magnifierGrid)

        // 十字是「一格宽」的半透明色带，不是细线；evenOdd 让横竖交叠的那一格自动镂空，
        // 正好露出正在取的那个像素。Longshot 量出来带的合成色 (34,92,160)，
        // 反解 #0084FF 叠在 (44,52,64) 上 alpha = 0.5。
        let bandH = CGRect(x: 0, y: (side - cell) / 2, width: side, height: cell)
        let bandV = CGRect(x: (side - cell) / 2, y: 0, width: cell, height: side)
        let holeSide = Self.magnifierHole
        let hole = CGRect(x: (side - holeSide) / 2, y: (side - holeSide) / 2,
                          width: holeSide, height: holeSide)
        let cross = NSBezierPath(rect: bandH)
        cross.append(NSBezierPath(rect: bandV))
        magnifierCross.path = cross.cgPath
        magnifierCross.fillColor = accent.withAlphaComponent(0.5).cgColor
        magnifierCross.fillRule = .evenOdd
        magnifierContent.addSublayer(magnifierCross)

        // 中心那个「正在取的像素」框：Longshot 是外沿 25px、内空 16px、描边 4~5px，
        // 换算成点是外沿 12.5pt / 内空 8pt / 描边 2.25pt。
        magnifierCellBox.path = NSBezierPath(rect: hole).cgPath
        magnifierCellBox.fillColor = nil
        magnifierCellBox.strokeColor = accent.cgColor
        magnifierCellBox.lineWidth = 2.25
        magnifierContent.addSublayer(magnifierCellBox)

        infoBar.frame = CGRect(x: 0, y: 0, width: side, height: Self.magnifierInfoHeight)
        infoBar.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        magnifier.addSublayer(infoBar)

        for text in [infoCoord, infoArea, infoColorLabel, infoColor] {
            text.fontSize = 11
            text.alignmentMode = .left
            text.isWrapped = false
            text.truncationMode = .none
            text.contentsScale = window?.backingScaleFactor ?? 2
            magnifier.addSublayer(text)
        }
        infoCoord.frame = CGRect(x: 8, y: 38, width: side - 16, height: 16)
        infoArea.frame = CGRect(x: 8, y: 21, width: side - 16, height: 16)
        infoColorLabel.frame = CGRect(x: 8, y: 4, width: 44, height: 16)
        infoColor.frame = CGRect(x: 72, y: 4, width: side - 78, height: 16)

        infoSwatch.frame = CGRect(x: 52, y: 5, width: 14, height: 14)
        infoSwatch.cornerRadius = 2
        infoSwatch.borderWidth = 1
        infoSwatch.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        magnifier.addSublayer(infoSwatch)

        layer?.addSublayer(magnifier)

        // 提示条贴左下角：左 10pt、底 20.5pt（Longshot 的实测值）。
        // 用子视图而不是 CALayer：里面是静态多行文本，交给 NSTextField 排版最省心。
        shortcutHint.setFrameOrigin(NSPoint(x: 10, y: 20.5))
        addSubview(shortcutHint)

        // 关键：进场就画整屏遮罩。只靠 mouseDown/拖拽里更新的话，
        // 用户点完热键到第一次按下鼠标之间屏幕毫无变化，根本不像进了截图态。
        updateSelectionLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: lockedSelection == nil ? .crosshair : .arrow)

        // 选区手柄骑在边界上，朝外那半边落在画布外面，画布自己的 cursor rect 管不到，
        // 这里补一圈。后加的先命中，所以能压住上面的整屏箭头。
        guard lockedSelection != nil, let canvas = annotationCanvas else { return }
        for anchor in SelectionAnchor.allCases {
            let center = SelectionGeometry.point(of: anchor, in: canvas.frame)
            let box = CGRect(x: center.x - SelectionChrome.reach,
                             y: center.y - SelectionChrome.reach,
                             width: SelectionChrome.reach * 2,
                             height: SelectionChrome.reach * 2)
            addCursorRect(box, cursor: anchor.cursor)
        }
    }

    /// 手柄的外半边落在画布外面，那里没有视图接手：光标不变、按下还会被本视图
    /// 吞掉（编辑态 `mouseDown` 直接 return），表现就是「角落的手柄有时候拖不动」。
    /// 命中环里把事件转给画布，让它用同一套 `SelectionGeometry.anchor` 判断。
    ///
    /// `hitTest` 的入参在**父视图**坐标里（实测确认），先换回本地再转给画布。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self, lockedSelection != nil, let canvas = annotationCanvas else { return hit }
        let local = convert(point, from: superview)
        let inCanvas = canvas.convert(local, from: self)
        guard SelectionGeometry.anchor(at: inCanvas, in: canvas.bounds,
                                       tolerance: SelectionChrome.reach) != nil else { return hit }
        return canvas
    }

    // MARK: - 坐标

    /// CG 全局坐标 → 本视图坐标（Cocoa，左下原点）
    private func localRect(fromGlobal global: CGRect) -> CGRect {
        guard let window else { return .zero }
        let bottom = mainScreenHeight - global.maxY
        return CGRect(x: global.minX - window.frame.minX,
                      y: bottom - window.frame.minY,
                      width: global.width,
                      height: global.height)
    }

    /// 给原地编辑器换算用：选区的视图坐标。
    func localFrame(forGlobal global: CGRect) -> CGRect {
        localRect(fromGlobal: global)
    }

    /// 长截图：隐藏冻结帧，窗口变透明，只留遮罩与边框。
    func enterScrollMode() {
        imageLayer.isHidden = true
        sizeLayer.isHidden = true
        hideMagnifier()
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.30).cgColor
    }

    /// 标注阶段调整选区：只换矩形，冻结帧和内容都不动。
    func updateSelection(_ global: CGRect) {
        guard lockedSelection != nil else { return }
        lockedSelection = global
        updateSelectionLayers()
        // 手柄跟着选区走，光标热区得重算，否则拖到新位置后外沿还是旧的
        window?.invalidateCursorRects(for: self)
    }

    /// 外部指定选区时直接锁住，不再等鼠标。
    func lockSelection(_ global: CGRect) {
        lockedSelection = global
        hideMagnifier()
        anchor = nil
        current = nil
        updateSelectionLayers()
        window?.invalidateCursorRects(for: self)
    }

    /// 鼠标位置 → CG 全局坐标
    private func globalPoint(for event: NSEvent) -> CGPoint {
        globalPoint(fromEventLocal: convert(event.locationInWindow, from: nil))
    }

    private func globalPoint(fromEventLocal local: CGPoint) -> CGPoint {
        guard let window else { return .zero }
        return CGPoint(x: window.frame.minX + local.x,
                       y: mainScreenHeight - (window.frame.minY + local.y))
    }

    private var selectionGlobal: CGRect? {
        guard let a = anchor, let b = current else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 当前要展示的矩形：拖框模式看 anchor/current，拾取模式看悬停结果，锁定后看框定结果。
    private var activeGlobal: CGRect? {
        if let lockedSelection { return lockedSelection }
        switch mode {
        case .area:
            // 还没按下时把悬停命中的窗口/元素当预览：Longshot 的「开始截图」就是这样，
            // 鼠标一停就已经框住一个窗口，单击即可，不必先拖。
            return selectionGlobal ?? hoverRect
        case .pick: return hoverRect
        case .bare: return nil
        }
    }

    private var caption: String? {
        guard let rect = activeGlobal else { return nil }
        let size = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        switch mode {
        case .area:
            // 编辑态才报坐标：框选时只关心尺寸，别干扰视线
            if lockedSelection != nil {
                return "\(size)   \(Int(rect.minX)), \(Int(rect.minY))"
            }
            // 悬停预览时报出命中的是谁，否则只是一个空框，看不出选中了什么
            if selectionGlobal == nil, let hoverLabel, !hoverLabel.isEmpty {
                return "\(hoverLabel)   \(size)"
            }
            return size
        case .pick:
            guard let hoverLabel, !hoverLabel.isEmpty else { return size }
            return "\(hoverLabel)   \(size)"
        case .bare:
            return nil
        }
    }

    // MARK: - 事件

    override func mouseDown(with event: NSEvent) {
        // 编辑态：选区已锁定，画布自己收事件，遮罩上的点击不重开框选
        if lockedSelection != nil { return }
        // 尺子态：交互由挂在上面子视图负责，这里不参与
        if mode == .bare { return }
        if mode == .pick {
            updateHover(at: globalPoint(for: event))
            if let rect = hoverRect {
                onFinish?(CaptureSelection(globalRect: rect,
                                           display: captured.display,
                                           windowID: hoverWindowID))
            }
            return
        }
        anchor = globalPoint(for: event)
        current = anchor
        // 记住按下瞬间命中的窗口/元素：这一下如果不拖动，就是「单击选中它」
        pressedHover = hoverRect.map { (rect: $0, windowID: hoverWindowID) }
        updateSelectionLayers()
    }

    /// 右键 = 取消。
    ///
    /// 之前不拦右键：AppKit 找不到菜单就把事件吞掉，窗口既不关、遮罩也不再画，
    /// 屏幕上看起来「退出去了」，实际覆盖窗和 `overlay.lock` 都还留着。
    /// 显式走 onFinish(nil) 才会 teardown、清 lock、把焦点还给下层 App。
    override func rightMouseDown(with event: NSEvent) {
        // 编辑态下右键属于画布（撤销/菜单），别把整场会话取消掉
        if lockedSelection != nil { return }
        onFinish?(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        let point = globalPoint(for: event)
        // 一拖动就放弃悬停目标：用户这时候要的是自由框选，不是那个窗口
        if pressedHover != nil, let anchor,
           hypot(point.x - anchor.x, point.y - anchor.y) > Self.dragThreshold {
            pressedHover = nil
            clearHover()
        }
        current = point
        updateSelectionLayers()
        updateMagnifier(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area else { return }
        // 编辑态：选区已锁定，这一下可能是工具条里的自绘控件（颜色圆点、分段、下拉）
        // 把 mouseUp 顺着响应链冒泡上来的。此处若继续走「空选区 = 取消」，
        // 用户点一下颜色整个截图就没了 —— 必须和 mouseDown 一样先挡住。
        if lockedSelection != nil { return }

        // 单击（没拖）命中窗口/元素：直接选中它，和 Longshot 的「开始截图」一致
        let pressed = pressedHover
        pressedHover = nil
        let released = globalPoint(for: event)
        if let pressed, let anchor,
           hypot(released.x - anchor.x, released.y - anchor.y) <= Self.dragThreshold {
            ActionLog.action("overlay.pickClick",
                             "w=\(Int(pressed.rect.width)) h=\(Int(pressed.rect.height)) window=\(pressed.windowID.map(String.init) ?? "-")")
            commit(pressed.rect, windowID: pressed.windowID)
            return
        }

        hideMagnifier()
        current = globalPoint(for: event)
        defer { anchor = nil; current = nil; updateSelectionLayers() }

        guard let rect = selectionGlobal, rect.width >= 2, rect.height >= 2 else {
            ActionLog.action("overlay.cancel", "src=maskUp empty=\(selectionGlobal == nil ? "none" : "tiny")")
            onFinish?(nil)
            return
        }
        // 先锁再 finish：finish 里 onFinish 会让外部开始挂编辑器，
        // defer 的 updateSelectionLayers 也必须还能看到这块选区。
        if retainsSelection {
            lockedSelection = rect
            window?.invalidateCursorRects(for: self)
        }
        onFinish?(CaptureSelection(globalRect: rect, display: captured.display))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if mode == .area {
            // 放大镜由 displayLink 每帧刷新；这里只在帧驱动不可用时兜底，
            // 避免同一个鼠标位置被事件和 vsync 各刷一遍。
            if frameLink == nil { updateMagnifier(at: point) }
            // 未按下、未锁定时同步做悬停拾取：进截图态就能看到「鼠标下这个窗口/元素」
            // 被框出来，松手即选。判定放在 anchor 为空时，拖框阶段不会和选区抢画面。
            if probe != nil, lockedSelection == nil, anchor == nil {
                let global = globalPoint(for: event)
                if shouldProbe(at: global) { updateHover(at: global) }
            }
            return
        }
        guard mode == .pick else { return }
        let global = globalPoint(for: event)
        if shouldProbe(at: global) { updateHover(at: global) }
    }

    /// AX 命中是跨进程同步调用，30 Hz 足够；同一格点内不重复打。
    private func shouldProbe(at point: CGPoint) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastProbeAt < 0.033,
           hypot(point.x - lastProbePoint.x, point.y - lastProbePoint.y) < 2 {
            return false
        }
        return true
    }

    private func updateHover(at point: CGPoint) {
        lastProbeAt = CFAbsoluteTimeGetCurrent()
        lastProbePoint = point

        guard let target = probe?(point, captured.display, pickKind) else {
            if hoverRect != nil {
                clearHover()
                updateSelectionLayers()
            }
            return
        }
        // 同一块区域不重复刷新：悬停在窗口里移动会一直命中同一个窗口
        if hoverRect == target.rect, hoverLabel == target.label,
           hoverWindowID == (target.kind == .window ? target.windowID : nil) {
            return
        }
        hoverRect = target.rect
        hoverLabel = target.label
        // 只有整窗才有「按窗口抓」的意义；元素拾取仍按冻结帧裁小块
        hoverWindowID = target.kind == .window ? target.windowID : nil
        updateSelectionLayers()
    }

    private func clearHover() {
        hoverRect = nil
        hoverLabel = nil
        hoverWindowID = nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Esc
            onFinish?(nil)
        case 48:  // ⇥ 切换窗口 / 窗口区域
            togglePickKind()
        case 3:   // F 全屏区域
            selectFullScreen()
        case 36:  // ↩ 选中光标所在窗口/元素
            if !confirmHover() { super.keyDown(with: event) }
        case 4:   // H 光标左移一个像素（Longshot 同款键位，不区分大小写）
            nudgeCursor(dx: -1, dy: 0)
        case 37:  // L 右
            nudgeCursor(dx: 1, dy: 0)
        case 40:  // K 上
            nudgeCursor(dx: 0, dy: 1)
        case 38:  // J 下
            nudgeCursor(dx: 0, dy: -1)
        case 8:   // C 复制当前像素颜色
            copyColorAtCursor()
        case 17:  // T 切换色值样式
            cycleColorFormat()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - 键盘快捷动作

    /// HJKL：把真实光标推 1pt —— 放大镜里正好走一格（一格 = 屏幕 1pt）。
    ///
    /// 系统光标只落在整点上：`CGWarpMouseCursorPosition(700.5)` 和
    /// `CGDisplayMoveCursorToPoint(700.5)` 读回来都还是 700（实测）。
    /// Longshot 用的也是 `CGDisplayMoveCursorToPoint`，所以它的「1 个像素」
    /// 同样是 1 个整点，没有亚像素魔法；它的格子也是按 1pt 划的，两者才对齐。
    ///
    /// 之前这里走「视图本地坐标 → 窗口坐标 → 屏幕坐标」三次往返再 warp，
    /// 每一步都可能带出 .5，warp 再舍一次，位移就会在 1 和 2 之间跳 ——
    /// 那才是「按一下感觉不是一个像素」的真凶。现在先取整当前屏幕点，
    /// 只加一次步长；后面的换算纯为刷新放大镜/悬停，不回灌到步长里。
    ///
    /// 只在没按下鼠标时响应：按住拖动时 warp 会让光标和按键位置打架。
    private func nudgeCursor(dx: CGFloat, dy: CGFloat) {
        guard mode == .area, lockedSelection == nil, anchor == nil, let window else { return }
        // NSEvent.mouseLocation 是左下原点；dy 正数向上，和 K/J 的语义一致。
        // 用 floor 而不是 round 当锚点：放大镜的一格就是 floor(坐标) 那个整点，
        // 按 round 走的话，光标停在 x.4 时会一步跨 0.6pt，格数就对不上了。
        let mouse = NSEvent.mouseLocation
        let target = CGPoint(x: mouse.x.rounded(.down) + dx, y: mouse.y.rounded(.down) + dy)
        let flipped = CGPoint(x: target.x, y: mainScreenHeight - target.y)

        CGWarpMouseCursorPosition(flipped)
        // warp 会把鼠标和系统事件流解绑，必须解回来，否则用户接下来的拖动是断的
        CGAssociateMouseAndMouseCursorPosition(1)

        let inWindow = window.convertPoint(fromScreen: target)
        updateMagnifier(at: convert(inWindow, from: nil))
        if probe != nil { updateHover(at: flipped) }
    }

    /// T：在 hex / rgb / hsl 之间循环。改完立刻重画一次放大镜，
    /// 否则要等鼠标再动一下才看到新格式。
    private func cycleColorFormat() {
        let next = (colorFormat.rawValue + 1) % ColorFormat.allCases.count
        colorFormat = ColorFormat(rawValue: next) ?? .hex
        // 信息行的缓存键里带了格式，不必手动清缓存
        if mode == .area, let window {
            let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            updateMagnifier(at: convert(inWindow, from: nil))
        }
        ActionLog.action("overlay.colorFormat", "\(colorFormat)")
    }

    /// C：把光标所在像素的颜色写进剪贴板（紧凑的 `#RRGGBB`，不带放大镜里的空格）。
    private func copyColorAtCursor() {
        guard mode == .area, let window else { return }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = convert(inWindow, from: nil)
        guard let color = pixelColor(at: CGPoint(x: floor(local.x), y: floor(local.y))) else { return }
        let hex = Self.hexString(color)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        ActionLog.action("overlay.copyColor", hex)
    }

    /// ⇥：在「窗口区域（AX 元素）」和「整窗」之间切。
    /// 切完立刻按新粒度重探一次，否则要等鼠标再动一下提示框才更新。
    private func togglePickKind() {
        guard mode == .area, lockedSelection == nil, probe != nil else { return }
        pickKind = pickKind == .element ? .window : .element
        lastProbePoint = CGPoint(x: -1000, y: -1000)
        if let global = globalPointAtMouse() { updateHover(at: global) }
        ActionLog.action("overlay.pickKind", pickKind.rawValue)
    }

    /// F：整块屏当选区，直接交出去。
    private func selectFullScreen() {
        guard mode == .area, lockedSelection == nil else { return }
        ActionLog.action("overlay.fullScreen", "display=\(captured.display.displayID)")
        commit(captured.display.screenFrame, windowID: nil)
    }

    /// ↩：把当前悬停目标定下来。鼠标一直没动时先按位置探一次。
    @discardableResult
    private func confirmHover() -> Bool {
        guard mode == .area, lockedSelection == nil else { return false }
        if hoverRect == nil, let global = globalPointAtMouse() {
            updateHover(at: global)
        }
        guard let rect = hoverRect else { return false }
        ActionLog.action("overlay.confirm",
                         "w=\(Int(rect.width)) h=\(Int(rect.height)) kind=\(pickKind.rawValue)")
        commit(rect, windowID: hoverWindowID)
        return true
    }

    /// 定下选区并结束本场（单击 / ↩ / F 共用）。
    private func commit(_ rect: CGRect, windowID: Int?) {
        anchor = nil
        current = nil
        pressedHover = nil
        hideMagnifier()
        clearHover()
        if retainsSelection {
            lockedSelection = rect
            window?.invalidateCursorRects(for: self)
        }
        updateSelectionLayers()
        onFinish?(CaptureSelection(globalRect: rect,
                                   display: captured.display,
                                   windowID: windowID))
    }

    /// 光标当前所在的 CG 全局坐标。键盘动作没有 event 可拿，只能自己算。
    private func globalPointAtMouse() -> CGPoint? {
        guard let window else { return nil }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return globalPoint(fromEventLocal: convert(inWindow, from: nil))
    }

    // MARK: - 放大镜

    /// 覆盖层上的图层都在鼠标事件里逐帧改位置。CA 对独立 layer 的 `frame` / `path` /
    /// `contents` 默认带 0.25s 缓动插值，肉眼看到的就是"放大镜追着光标跑、慢半拍"。
    /// 拖框要的是像素级跟手，这里统一压掉隐式动画。
    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// 贴光标显示 15×15 格的放大镜（一格 = 1pt，9 倍），并附坐标 / 区域 / 色值三行。
    /// 规格照 Longshot 抄：直角方框、一格宽的半透明十字、中心挖空一格。
    private func updateMagnifier(at point: CGPoint) {
        guard mode == .area, lockedSelection == nil, !imageLayer.isHidden else {
            hideMagnifier()
            return
        }

        let side = Self.magnifierSide
        let total = side + Self.magnifierInfoHeight
        let gap: CGFloat = 14

        // 视图是左下原点：光标右下 = x 加、y 减。下面放不下翻到上面，右边放不下翻到左边。
        let hysteresis: CGFloat = 8
        let fitsRight = point.x + gap + side <= bounds.maxX - hysteresis
        let fitsLeft = point.x - gap - side >= hysteresis
        let fitsBelow = point.y - gap - total >= hysteresis
        let fitsAbove = point.y + gap + total <= bounds.maxY - hysteresis
        // 迟滞：只有当前方向真的塞不下、另一边塞得下时才翻，避免贴着阈值来回跳。
        // 两个条件互斥，所以不用先看现在朝哪边。
        if !fitsRight, fitsLeft { magnifierOnRight = false }
        if !fitsLeft, fitsRight { magnifierOnRight = true }
        if !fitsBelow, fitsAbove { magnifierOnTop = true }
        if !fitsAbove, fitsBelow { magnifierOnTop = false }

        var origin = CGPoint(x: magnifierOnRight ? point.x + gap : point.x - gap - side,
                             y: magnifierOnTop ? point.y + gap : point.y - gap - total)
        // 必须和内容同步吸附到整点：内容是按整像素裁的，框却走小数的话，
        // 像素格会随框平滑滑动、跨像素时整块换图，看着就是「格子在飘、内容在跳」。
        // 吸附之后两者同一节奏，跳格发生在同一帧。
        origin.x = max(0, min(origin.x, bounds.maxX - side)).rounded()
        origin.y = max(0, min(origin.y, bounds.maxY - total)).rounded()

        // 中心格 = 光标所在的那 1pt，所以采样锚点取 floor；之前取 +0.5 是在按位图像素算，
        // 一按 HJKL 就跑两格，坐标读数还比实际大 1
        let snap = CGPoint(x: floor(point.x), y: floor(point.y))
        let windowX = window?.frame.minX ?? 0
        let windowY = window?.frame.minY ?? 0
        let gx = Int((windowX + snap.x).rounded())
        // 和 Longshot 一致：y 用 Cocoa 的左下原点（光标在上方时读数大），
        // 这样两边对着同一处读到的数字完全相同
        let gy = Int((windowY + snap.y).rounded())

        // 正在拖框就报选区；还没框就报光标底下那个窗口的尺寸（Longshot 同款）
        let area = currentRegion(at: CGPoint(x: windowX + snap.x,
                                             y: mainScreenHeight - (windowY + snap.y)))
        let coordText = "坐标: (\(gx),\(gy))"
        let areaText = "区域: [\(Int(area.width)),\(Int(area.height))]"

        withoutImplicitAnimation {
            magnifier.isHidden = false
            magnifier.frame = CGRect(x: origin.x, y: origin.y, width: side, height: total)

            // 位置每帧都要跟，内容只在换格时重做：同一格里像素和颜色都不会变，
            // 没必要每秒 60 次去裁位图、建 CGContext。裁一小块而不是整屏平铺，
            // 是因为平铺时 x/y 两轴都要跟 contents 方向较劲，很容易差半个屏。
            if snap != lastMagnifierSnap {
                lastMagnifierSnap = snap
                magnifierContent.contents = magnifierCrop(around: snap)
            }

            let color = colorAt(snap)
            let colorText = Self.colorString(color, format: colorFormat)
            let info = coordText + "|" + areaText + "|" + colorText + "|\(colorFormat.rawValue)"
            if info != lastInfoKeys {
                lastInfoKeys = info
                infoCoord.string = Self.infoString(coordText)
                infoArea.string = Self.infoString(areaText)
                infoColorLabel.string = Self.infoString("色值: ")
                infoColor.string = Self.infoString(colorText, mono: true)
                infoSwatch.backgroundColor = color?.cgColor ?? NSColor.clear.cgColor
            }

            // 不再向全屏延伸十字辅助线：Longshot 只在放大镜内画十字，
            // 拉满全屏的线会盖住画面，反而看不清真正要对齐的边
        }
    }

    /// 同一格内颜色不会变，按格缓存：信息行每帧都拼串，但取色不必每帧重做。
    private func colorAt(_ snap: CGPoint) -> NSColor? {
        if snap != lastColorSnap {
            lastColorSnap = snap
            lastColor = pixelColor(at: snap)
        }
        return lastColor
    }

    /// 冻结帧一个视图点对应多少位图像素（降采样抓图时小于 nativeScale）。
    private var imageScale: (x: CGFloat, y: CGFloat) {
        let image = captured.image
        return (CGFloat(image.width) / bounds.width, CGFloat(image.height) / bounds.height)
    }

    /// 从冻结帧里裁出光标周围 15pt 见方的一块（2x 屏 = 30 个设备像素）。
    private func magnifierCrop(around point: CGPoint) -> CGImage? {
        let image = captured.image
        let scale = imageScale
        let count = Self.magnifierCells
        let half = (count - 1) / 2

        // 一格 = 屏幕 1pt，不是 1 个位图像素。
        // 实测 Longshot：光标移 1pt，放大镜里的内容正好滚 18 设备像素 = 一格，
        // 所以它这 15 格盖的是 15pt（2x 屏 30 设备像素），倍率 9 倍而不是 18 倍。
        // 之前按「一格一个位图像素」裁 15 个设备像素，一步要跑两格，怎么调都对不上手。
        // 左侧固定落在整点上，中心格就是 floor(光标) 那一点。
        let w = Int((count * scale.x).rounded())
        let h = Int((count * scale.y).rounded())
        let left = (floor(point.x) - half) * scale.x
        // 位图 y 轴朝下：视图像素 y 向上，[y-half, y+half+1] 这段翻到图像里取上边界
        let top = (bounds.maxY - (floor(point.y) + half + 1)) * scale.y
        var rect = CGRect(x: left.rounded(), y: top.rounded(),
                          width: CGFloat(w), height: CGFloat(h))
        // 贴边时整块挪回来，不能裁小 —— 裁小会被拉伸，格子就和内容错位了
        rect.origin.x = max(0, min(rect.origin.x, CGFloat(image.width - w)))
        rect.origin.y = max(0, min(rect.origin.y, CGFloat(image.height - h)))
        return image.cropping(to: rect)
    }

    /// 信息区第二行：拖框时报选区，否则报光标下窗口的尺寸（按 60ms 节流，枚举窗口不便宜）。
    private func currentRegion(at global: CGPoint) -> CGSize {
        if let rect = selectionGlobal { return rect.size }
        // 已经悬停到窗口/元素就报它：画面上框的是哪块，这里就必须报哪块，
        // 否则同屏出现「框 1044×544、区域写 1440×900」两个数
        if let hoverRect { return hoverRect.size }
        // 光标还在同一个窗口里就复用上次结果：枚举全部窗口要 20–60ms，拖框时每帧调会掉帧
        if let probe = windowProbe, probe.contains(global) { return probe.size }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastWindowProbeAt > 0.06 else { return windowProbe?.size ?? .zero }
        lastWindowProbeAt = now
        windowProbe = Self.windowRect(at: global)
        return windowProbe?.size ?? .zero
    }

    private static func windowRect(at point: CGPoint) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { continue }
            // 跳过菜单栏/桌面这类整屏或贴边窗口
            if rect.contains(point), rect.width < 4000, rect.height < 4000 {
                return rect
            }
        }
        return nil
    }

    /// 取冻结帧里某个像素的 sRGB 颜色（1×1 重绘，比把整张位图读进内存便宜得多）。
    private func pixelColor(at point: CGPoint) -> NSColor? {
        let image = captured.image
        let scale = imageScale
        let px = Int(point.x * scale.x)
        let py = Int((bounds.maxY - point.y) * scale.y)
        guard px >= 0, px < image.width, py >= 0, py < image.height,
              let one = image.cropping(to: CGRect(x: px, y: py, width: 1, height: 1)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return NSColor(srgbRed: CGFloat(rgba[0]) / 255,
                       green: CGFloat(rgba[1]) / 255,
                       blue: CGFloat(rgba[2]) / 255,
                       alpha: 1)
    }

    private static func byte(_ component: CGFloat) -> Int {
        Int((component * 255).rounded())
    }

    /// 放大镜里字节间留一格（跟 Longshot 一样好认），剪贴板里要紧凑的 `#RRGGBB`。
    private static func hexString(_ c: NSColor, spaced: Bool = false) -> String {
        let rgb = (byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
        return spaced ? String(format: "#%02X %02X %02X", rgb.0, rgb.1, rgb.2)
                      : String(format: "#%02X%02X%02X", rgb.0, rgb.1, rgb.2)
    }

    /// 色值文本按当前格式渲染。信息区宽度只有 57pt，所以非 hex 一律用最紧凑的写法，
    /// 不加 `rgb()` 包裹 —— 加完就溢出裁掉了。
    private static func colorString(_ color: NSColor?, format: ColorFormat) -> String {
        guard let c = color else { return "—" }
        switch format {
        case .hex:
            return hexString(c, spaced: true)
        case .rgb:
            return "\(byte(c.redComponent)),\(byte(c.greenComponent)),\(byte(c.blueComponent))"
        case .hsl:
            return hslString(c)
        }
    }

    private static func hslString(_ c: NSColor) -> String {
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 0 else { return "0,0,\(Int((l * 100).rounded()))" }
        let s = d / (1 - abs(2 * l - 1))
        var h: CGFloat
        if maxV == r {
            h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
        } else if maxV == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return "\(Int(h.rounded())),\(Int((s * 100).rounded())),\(Int((l * 100).rounded()))"
    }

    private static func infoString(_ text: String, mono: Bool = false) -> NSAttributedString {
        let font = mono
            ? NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            : NSFont.systemFont(ofSize: 11)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
        ])
    }

    private func hideMagnifier() {
        withoutImplicitAnimation {
            magnifier.isHidden = true
        }
        // 不用清缓存：裁图 / 取色 / 文案都以「哪一格」为键，冻结帧是 immutable 的，
        // 再亮起来时同一格的内容本来就还是对的。
    }

    /// 放大镜的像素网格。
    ///
    /// 要的是「一格 = 1pt」的分隔线。按 Longshot 实测反解：格底 (44,52,64)、
    /// 线 (104,109,116)，白色叠加解出 alpha ≈ 0.28（R/G/B 三个通道分别算都是 0.27~0.28）。
    /// 线宽 2px —— 2x 屏上正好 1pt，一格 18px。
    ///
    /// 早先用 `NSImage(size:)` + `lockFocus` 画 1pt 线，得到的是 1x 位图，铺到 2x 屏上被
    /// 放大两倍再插值，线变虚、还只有 26% 灰，所以看起来「像素线很淡」。这里直接按
    /// backing scale 造位图、按像素填色，1:1 映射不做缩放。
    /// `scale` 用被抓那块屏的 nativeScale，不是 `NSScreen.main` —— 混接 1x 副屏时
    /// 按主屏 2x 造位图，网格线会被拉虚。
    private static func gridPattern(cell: CGFloat, scale: CGFloat) -> NSColor {
        let pixels = max(2, Int((cell * scale).rounded()))
        let linePx = max(1, Int(scale.rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return .clear }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.withAlphaComponent(0.28).setFill()
        // 右侧一列 + 下侧一行：格子之间只画一条，相邻格共用
        let w = CGFloat(pixels), l = CGFloat(linePx)
        NSBezierPath(rect: NSRect(x: w - l, y: 0, width: l, height: w)).fill()
        NSBezierPath(rect: NSRect(x: 0, y: w - l, width: w, height: l)).fill()
        NSGraphicsContext.restoreGraphicsState()

        rep.size = NSSize(width: cell, height: cell)
        let image = NSImage(size: NSSize(width: cell, height: cell))
        image.addRepresentation(rep)
        return NSColor(patternImage: image)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        for text in [sizeLayer, infoCoord, infoArea, infoColorLabel, infoColor] {
            text.contentsScale = scale
        }

        // 放大镜跟手靠的是「每帧读一次真实光标」，不是靠鼠标事件驱动。
        // Longshot 用的是 CVDisplayLink（nm 里能看到 CVDisplayLinkCreateWithActiveCGDisplays
        // / SetOutputCallback / Start），这里用 macOS 14 的等价物 CADisplayLink：
        // 回调跟屏幕刷新率走（60/120Hz），和 vsync 对齐。
        //
        // 只用 mouseMoved 驱动的问题：系统会合并/丢弃事件，快速移动时一帧内可能到 0 或 3 个，
        // 放大镜的位移节奏就跟着事件抖动，看起来「跟不上」；displayLink 每帧取当前位置，
        // 位移恒定是「这一帧真实移动了多少」。
        frameLink?.invalidate()
        frameLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayTick))
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    @objc private func displayTick() {
        guard mode == .area, lockedSelection == nil, anchor == nil, window != nil else { return }
        let inWindow = window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero
        let point = convert(inWindow, from: nil)
        if point == lastTickPoint { return }
        updateMagnifier(at: point)
        lastTickPoint = point
    }

    // MARK: - 绘制

    /// 选区边框/压暗遮罩逐帧跟手，同样不能带 0.25s 的缓动，否则框会"拖着走"。
    private func updateSelectionLayers() {
        withoutImplicitAnimation(applySelectionLayers)
    }

    private func applySelectionLayers() {
        // 提示条只在「进来还没框」时出现：开始拖框或已锁定时它只会挡画面
        shortcutHint.isHidden = mode != .area
            || lockedSelection != nil
            || selectionGlobal != nil
            || imageLayer.isHidden

        guard let global = activeGlobal else {
            // 还没框选时整屏压暗：这是「已进入截图状态」的唯一视觉反馈，
            // 只把鼠标换成十字光标用户根本不知道自己已经在截图里。
            dimLayer.path = NSBezierPath(rect: bounds).cgPath
            borderLayer.path = nil
            sizeLayer.isHidden = true
            return
        }

        let rect = localRect(fromGlobal: global)
        let outer = NSBezierPath(rect: bounds)
        outer.append(NSBezierPath(rect: rect))
        // 填充规则由 CAShapeLayer.fillRule = .evenOdd 决定，路径本身不携带
        dimLayer.path = outer.cgPath
        borderLayer.path = NSBezierPath(rect: rect).cgPath

        guard let caption else {
            sizeLayer.isHidden = true
            return
        }
        sizeLayer.isHidden = false
        sizeLayer.string = caption
        // 按实际文字量算宽度，CJK 用字符数 × 7 会截断
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11)
        ]
        let textWidth = (caption as NSString).size(withAttributes: attributes).width + 14
        // 贴选区左上角的外侧（视图是左下原点，所以要加在 maxY 上）；
        // 顶上放不下就翻到框内。
        let x = min(max(0, rect.minX), max(0, bounds.width - textWidth))
        let above = rect.maxY + 4
        let y = above + 18 <= bounds.height ? above : max(0, rect.maxY - 22)
        sizeLayer.frame = CGRect(x: x.rounded(), y: y.rounded(), width: textWidth, height: 18)
    }
}

/// overlay 残留保护：无 Dock 图标的 App 一旦把全屏高 level 窗留在屏幕上，用户关不掉。
public enum OverlayRecovery {
    public struct Residue: Sendable {
        public let pid: pid_t
        public let alive: Bool
    }

    private static var lockURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Baton", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("overlay.lock")
    }

    public static func beginSession() {
        guard let url = lockURL else { return }
        try? "\(getpid())".write(to: url, atomically: true, encoding: .utf8)
    }

    public static func endSession() {
        guard let url = lockURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 返回上次会话残留。`nil` 表示干净（没有 lock、lock 是自己写的、或留下 lock 的进程已经退出）。
    public static func checkResidue() -> Residue? {
        guard let url = lockURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        if pid == getpid() { return nil }
        if kill(pid, 0) == 0 {
            return Residue(pid: pid, alive: true)
        }
        // 进程已经没了：这个 lock 挡不住任何东西，留着只会每次启动都报一条假警报
        try? FileManager.default.removeItem(at: url)
        ActionLog.state("overlay.staleLock", "pid=\(pid)")
        return nil
    }
}

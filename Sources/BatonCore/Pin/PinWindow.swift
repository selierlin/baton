import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 一张贴图的全部可观测状态，给 `Baton --pin-suite` 用。
///
/// 压在线上代码里是因为这些状态本来就是私有的：光标、命中、面板位置这些
/// 「只靠读代码看不出来」的东西，只有真跑起来读一次才知道对不对。
public struct PinDebugSnapshot {
    public var frame: CGRect = .zero
    public var alpha: CGFloat = 1
    public var zoom: CGFloat = 1
    public var isThumbnail = false
    /// 显示位图解出来没有（nil 就是那个「黑框 + 全透明」）
    public var hasContent = false
    public var editing = false
    public var barVisible = false
    public var barFrame: CGRect = .zero
    public var canvasInteractive = false
    /// 画布认为现在该是箭头光标（只读态）
    public var cursorIsArrow = false
    /// 图元包围盒（图片像素）
    public var annotationRects: [CGRect] = []
    public var selectionRect: CGRect?
    /// 有没有写进库
    public var stored = false
}

/// 贴图管理器：只管创建与回收，窗口生命周期自己管。
@MainActor
public final class PinController {
    private var pins: [PinWindowController] = []
    private let store: PinStore?

    public init(store: PinStore? = nil) {
        self.store = store
    }

    public var count: Int { pins.count }

    /// 诊断用：把最近钉的那张切到标注态（`Baton --pin-probe` 用，正常流程走空格）。
    public func debugBeginEditingLast() {
        pins.last?.debugSetEditing(true)
    }

    /// 诊断用：给最近那张贴图发一次按键，走的是真实键位表。
    @discardableResult
    public func debugSendKeyLast(_ keyCode: UInt16) -> Bool {
        guard let pin = pins.last,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: 0, context: nil, characters: "",
                                           charactersIgnoringModifiers: "", isARepeat: false,
                                           keyCode: keyCode) else { return false }
        return pin.handleKey(event)
    }

    /// 诊断用：最近那张贴图的 frame（探针读它判断拖拽有没有真的搬动窗口）。
    public var debugLastFrame: CGRect { pins.last?.debugFrame ?? .zero }

    /// 诊断用：最近那张贴图的显示/工具条状态。
    public var debugLastState: String {
        guard let pin = pins.last else { return "none" }
        return "content=\(pin.debugHasContent) editing=\(pin.debugEditing) bar=\(pin.debugBarVisible)"
    }

    /// 诊断用：完整快照（`--pin-suite` 的断言全读它）。
    public var debugSnapshot: PinDebugSnapshot? { pins.last?.debugSnapshot }

    /// 诊断用：窗口坐标上这一点归谁处理——画布还是贴图视图。
    public func debugHitIsCanvas(at point: CGPoint) -> Bool {
        pins.last?.debugHitIsCanvas(at: point) ?? false
    }

    /// 诊断用：直接拿画布，场景里要切工具/读文档。
    public var debugCanvas: AnnotateCanvasView? { pins.last?.debugCanvas }

    public func debugCloseLast() { pins.last?.close() }
    public func debugCloseAll() { closeAll() }

    /// 诊断用：让贴图窗口成为 key，悬停追踪区才会送事件。
    public func debugMakeKey() { pins.last?.debugMakeKey() }

    /// 诊断用：按真实响应链发一次按键——标注态进画布（含拦截器），只读态进贴图视图。
    /// 直接调 `handleKey` 会绕过画布那一层，Esc / ⌘Z 这类「两边都能处理」的键就测不准。
    @discardableResult
    public func debugSendKey(_ keyCode: UInt16, command: Bool = false, shift: Bool = false) -> Bool {
        guard let pin = pins.last else { return false }
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        // 画布的 ⌘Z / ⌘D 这些按字符认，合成的空字符会让它们全落到 super 里
        let characters = Self.debugCharacters[keyCode] ?? ""
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else { return false }
        return pin.debugSendKey(event)
    }

    /// 常用键的字符形式（只有按键表里按字符判断的那几个需要）
    private static let debugCharacters: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 6: "z", 8: "c", 12: "q", 15: "r",
        24: "=", 27: "-", 31: "o", 35: "p", 49: " ",
    ]

    /// 全部临时藏起来：`orderOut` 而已，不删库也不改 frame，再切回来原位原样。
    public private(set) var isHidden = false

    /// - Parameters:
    ///   - image: 已合成的位图
    ///   - scale: 原图倍率，用来把像素换成视觉点（2x 图上 1200px 宽在屏幕上是 600pt）
    ///   - screenRect: 原选区屏幕坐标（点，左上原点），有就贴着原位钉住
    public func pin(_ image: CGImage, scale: CGFloat, near screenRect: CGRect? = nil) {
        // 藏起来的状态下又贴了新图：先全部恢复，否则新图孤零零一张，
        // 再按一次「显示所有贴图」反而会把它也藏掉，状态就对不上了
        if isHidden { setHidden(false) }
        let controller = PinWindowController(source: PinImageSource(image: image),
                                             scale: max(scale, 1),
                                             anchor: screenRect,
                                             initialFrame: nil,
                                             opacity: 1,
                                             store: store,
                                             pinID: nil,
                                             onClose: { [weak self] id in
            self?.pins.removeAll { $0.id == id }
        })
        controller.onDropFile = { [weak self] url in self?.pinFile(url) }
        // 贴图窗口里的「贴图」：把带标注的合成图再钉一张
        controller.onPinCopy = { [weak self] image, scale in self?.pin(image, scale: scale) }
        pins.append(controller)
        controller.show()
        ActionLog.result("pin.show", "count=\(pins.count) px=\(image.width)x\(image.height) scale=\(scale) at=\(screenRect.map { "\(Int($0.origin.x)),\(Int($0.origin.y))" } ?? "-")")
    }

    /// 启动时把上次没关的贴图摆回来。
    public func restore() {
        guard let store else { return }
        for stored in store.loadAll() {
            let controller = PinWindowController(source: stored.source,
                                                 scale: stored.scale,
                                                 anchor: nil,
                                                 initialFrame: stored.frame,
                                                 opacity: stored.opacity,
                                                 store: store,
                                                 pinID: stored.id,
                                                 baseZoom: stored.baseZoom,
                                                 isThumbnail: stored.isThumbnail,
                                                 onClose: { [weak self] id in
                self?.pins.removeAll { $0.id == id }
            })
            controller.onDropFile = { [weak self] url in self?.pinFile(url) }
            controller.onPinCopy = { [weak self] image, scale in self?.pin(image, scale: scale) }
            pins.append(controller)
            controller.show()
        }
    }

    public func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        for pin in pins { pin.setVisible(!hidden) }
        ActionLog.result("pin.hidden", "hidden=\(hidden) count=\(pins.count)")
    }

    public func toggleHidden() { setHidden(!isHidden) }

    /// 从磁盘上的图片文件贴图（Finder 拖入、⌘O 打开都走这里）。
    ///
    /// 文件图没有「屏幕倍率」概念，按 1px = 1pt 处理；太大的图由 `initialRect()`
    /// 自己缩到屏幕 80% 内，不至于一贴就盖满整块屏。
    @discardableResult
    public func pinFile(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else {
            ActionLog.fail("pin.file", "unreadable=\(url.lastPathComponent)")
            return false
        }
        pin(image, scale: 1)
        return true
    }

    public func closeAll() {
        ActionLog.action("pin.closeAll.apply", "count=\(pins.count)")
        for pin in pins { pin.close() }
        pins.removeAll()
        isHidden = false
    }
}

@MainActor
final class PinWindowController: NSObject, NSWindowDelegate {
    let id = UUID()

    private let source: PinImageSource
    private let baseSize: CGSize
    private let imageScale: CGFloat
    private let anchor: CGRect?
    private let initialFrame: CGRect?
    private let initialOpacity: Double
    private let store: PinStore?
    private var pinID: String?
    /// 库里记下的还原倍率与缩略图态（老记录为 nil / false）。
    private let storedBaseZoom: CGFloat?
    private let storedThumbnail: Bool
    private let onClose: (UUID) -> Void
    /// 往这张贴图上丢文件：交给 PinController 再钉一张，自己不动。
    var onDropFile: ((URL) -> Void)?

    private var window: PinPanel?
    private var view: PinView?
    private var annotator: PinAnnotator?
    private var zoom: CGFloat = 1
    /// 贴图创建（或从库里恢复）时的倍率。R 从缩略图还原回这里。
    private var baseZoom: CGFloat = 1
    /// 是否处于缩略图模式。
    private var isThumbnailMode = false
    private var pendingSave: DispatchWorkItem?

    /// 缩略图模式把长边收到这么多点：够看清是什么图，又不至于挡着内容。
    private static let thumbnailLongest: CGFloat = 160

    /// 恢复一行贴图时的倍率计划。
    struct RestorePlan: Equatable {
        var zoom: CGFloat
        /// R 从缩略图还原的目标倍率。
        var baseZoom: CGFloat
        /// 这行 frame 是缩略图态写下的（旧版本会把缩略图尺寸当真实尺寸存），R 得能放回去。
        var isThumbnail: Bool
    }

    /// 屏内「适配」倍率：太大就缩到屏宽的 80%。
    static func fitZoom(baseSize: CGSize, in visible: CGRect) -> CGFloat {
        guard baseSize.width > 0, baseSize.height > 0 else { return 1 }
        return min(1, (visible.width * 0.8) / baseSize.width, (visible.height * 0.8) / baseSize.height)
    }

    /// 从库里恢复时算倍率。
    ///
    /// 新记录直接读 `baseZoom` / `thumbnail`，与关闭前完全一致。
    /// 老记录没有这两列：正常情况「存下来的 frame 就是真实尺寸」，`baseZoom` 取它；
    /// 但旧版本在缩略图态也写当前 frame，重启后 `baseZoom` 就成了缩略图的倍率，
    /// 再按 R 时目标倍率等于当前倍率，看起来就是「按了没反应」。
    /// 长边正好 160 点且原图比它大，就认定是缩略图态，还原目标按屏内适配算。
    static func restorePlan(frame: CGRect, baseSize: CGSize, fitZoom: CGFloat,
                            baseZoom: CGFloat? = nil, isThumbnail: Bool = false) -> RestorePlan {
        let zoom = frame.width / max(baseSize.width, 1)
        if let baseZoom {
            return RestorePlan(zoom: zoom, baseZoom: baseZoom, isThumbnail: isThumbnail)
        }
        let longest = max(frame.width, frame.height)
        let sourceLongest = max(baseSize.width, baseSize.height)
        let stranded = abs(longest - thumbnailLongest) <= 2 && sourceLongest > thumbnailLongest
        return stranded
            ? RestorePlan(zoom: zoom, baseZoom: fitZoom, isThumbnail: true)
            : RestorePlan(zoom: zoom, baseZoom: zoom, isThumbnail: false)
    }

    init(source: PinImageSource, scale: CGFloat, anchor: CGRect?, initialFrame: CGRect?,
         opacity: Double, store: PinStore?, pinID: String?,
         baseZoom: CGFloat? = nil, isThumbnail: Bool = false,
         onClose: @escaping (UUID) -> Void) {
        self.source = source
        self.imageScale = max(scale, 1)
        self.baseSize = CGSize(width: source.pixelSize.width / max(scale, 1),
                               height: source.pixelSize.height / max(scale, 1))
        self.anchor = anchor
        self.initialFrame = initialFrame
        self.initialOpacity = opacity
        self.store = store
        self.pinID = pinID
        self.storedBaseZoom = baseZoom
        self.storedThumbnail = isThumbnail
        self.onClose = onClose
        super.init()
    }

    /// 隐藏/显示：隐藏只是把窗口挪出屏幕，DB 记录和 frame 都不动。
    func setVisible(_ visible: Bool) {
        guard let window else { return }
        if visible {
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }

    func show() {
        let panel: PinPanel
        if let initialFrame {
            // 恢复：沿用上次的 frame，但屏幕可能已经变了，先夹回可视区
            panel = PinPanel(contentRect: clamped(initialFrame),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            let visible = (screenForAnchor() ?? NSScreen.main)?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let plan = Self.restorePlan(frame: panel.frame,
                                        baseSize: baseSize,
                                        fitZoom: Self.fitZoom(baseSize: baseSize, in: visible),
                                        baseZoom: storedBaseZoom,
                                        isThumbnail: storedThumbnail)
            zoom = plan.zoom
            baseZoom = plan.baseZoom
            isThumbnailMode = plan.isThumbnail
        } else {
            panel = PinPanel(contentRect: initialRect(),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            baseZoom = zoom
        }

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // 拖拽由 `PinView` 自己算（双击缩放会吃掉 AppKit 的背景拖动）；
        // 两边都开着会一次拖拽算两遍，窗口抖
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.alphaValue = CGFloat(initialOpacity)
        panel.delegate = self

        let view = PinView(source: source)
        view.onZoom = { [weak self] step, anchor in
            self?.zoomByGesture(step: step, at: anchor)
        }
        view.onDoubleClick = { [weak self] in self?.toggleActualSize() }
        view.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        view.onMenu = { [weak self] event in self?.showMenu(for: event) ?? false }
        view.onDropFile = { [weak self] url in self?.onDropFile?(url) }
        // 缩略态那一圈加粗边框得跟着视图一起立起来（恢复出来的缩略图直接就是加粗态）
        view.emphasizedBorder = isThumbnailMode
        panel.contentView = view
        self.view = view

        // 贴图不抢焦点：截图后用户往往马上要滚动/继续打字，
        // nonactivating panel 只有被点中时才成为 key。
        panel.becomesKeyOnlyIfNeeded = true
        panel.makeFirstResponder(view)
        panel.orderFrontRegardless()
        window = panel

        // 刚钉出来的那张顺手拿 key：Baton 这会儿本来就是前台，用户下一句
        // 多半是空格 / R，不拿 key 这些键会飘到别的 app 上。
        // 恢复历史贴图时不抢——那是开机静默摆回来的。
        if pinID == nil, NSApp.isActive { panel.makeKey() }

        // 只有新钉的才写库；恢复出来的已经有记录
        if pinID == nil, let store, let image = source.full() {
            pinID = try? store.save(image: image, scale: imageScale, frame: panel.frame,
                                    screenUUID: Self.screenUUID(panel.screen),
                                    opacity: Double(panel.alphaValue),
                                    baseZoom: baseZoom)
            if let pinID {
                // 先把 blob 认回来再丢原图：显示（换桶重新解）和导出（原图）
                // 都靠它，否则缩放一下贴图就空白、空格也建不出画布。
                if let url = store.blobURL(forPinID: pinID) { source.adopt(fileURL: url) }
                source.releaseOriginal()
            }
        }
    }

    func close() {
        pendingSave?.cancel()
        guard let window else { return }
        annotator?.dismantle()
        annotator = nil
        view = nil
        if let store, let pinID { store.delete(id: pinID) }
        window.delegate = nil
        window.close()
        self.window = nil
        onClose(id)
        ActionLog.result("pin.close", "id=\(id.uuidString.prefix(8))")
    }

    func windowWillClose(_ notification: Notification) {
        pendingSave?.cancel()
        annotator?.dismantle()
        annotator = nil
        view = nil
        if let store, let pinID { store.delete(id: pinID) }
        window = nil
        onClose(id)
    }

    // MARK: - 键位

    /// 贴图窗口的一次按键。返回 true 表示已消费。
    ///
    /// 两个入口共用：只读态由 `PinView` 转发，编辑态由画布的 `keyInterceptor` 转发。
    /// 键位表在 `PinShortcuts` 里，这里只管「这条动作怎么落到窗口上」。
    func handleKey(_ event: NSEvent) -> Bool {
        guard let action = PinShortcuts.action(for: event) else { return false }

        // 编辑中且选中了图元：方向键微调图元、Esc 取消选中，都还归画布
        let canvasOwns = annotator?.isEditing == true && annotator?.hasSelectedAnnotation == true
        switch action {
        case .nudge where canvasOwns, .escape where canvasOwns:
            return false
        default:
            break
        }

        switch action {
        case .toggleEdit:
            toggleEditing()
        case .thumbnail:
            toggleThumbnail()
        case .zoomIn:
            changeZoom(byRatio: 1.1)
        case .zoomOut:
            changeZoom(byRatio: 1 / 1.1)
        case .opacityUp:
            changeOpacity(by: 0.1)
        case .opacityDown:
            changeOpacity(by: -0.1)
        case .copy:
            ensureAnnotator()?.copyFlattened()
        case .save:
            ensureAnnotator()?.saveFlattened()
        case .saveAndCopy:
            ensureAnnotator()?.saveAndCopy()
        case .escape:
            if annotator?.isEditing == true {
                annotator?.setEditing(false)
            } else {
                close()
            }
        case .nudge(let dx, let dy):
            nudge(dx: dx, dy: dy)
        }
        return true
    }

    /// 标注层按需创建：没进过标注的贴图不该为它付一条面板 + 一堆视图的代价。
    @discardableResult
    private func ensureAnnotator() -> PinAnnotator? {
        if let annotator { return annotator }
        guard let window, let view else { return nil }

        let annotator = PinAnnotator(source: source, hostView: view, hostWindow: window)
        annotator.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        annotator.onPin = { [weak self] image in
            guard let self else { return }
            self.onPinCopy?(image, self.imageScale)
        }
        annotator.onEditingChange = { [weak self] editing in
            guard let self, let view = self.view else { return }
            view.allowsWindowDrag = !editing
            if !editing { view.window?.makeFirstResponder(view) }
        }
        self.annotator = annotator
        return annotator
    }

    /// 「贴图」动作：把合成结果再钉一张。
    var onPinCopy: ((CGImage, CGFloat) -> Void)?

    /// 诊断用：单测里看不到私有状态。
    var debugEditing: Bool { annotator?.isEditing ?? false }
    var debugBarVisible: Bool { annotator?.debugBarVisible ?? false }
    var debugFrame: CGRect { window?.frame ?? .zero }
    var debugZoom: CGFloat { zoom }
    /// 诊断用：窗口里到底有没有可画的位图（空白贴图就是这个变 nil）
    var debugHasContent: Bool { view?.hasContent ?? false }
    var debugCanvas: AnnotateCanvasView? { annotator?.debugCanvas }

    var debugSnapshot: PinDebugSnapshot {
        var snapshot = PinDebugSnapshot()
        snapshot.frame = window?.frame ?? .zero
        snapshot.alpha = window?.alphaValue ?? 0
        snapshot.zoom = zoom
        snapshot.isThumbnail = isThumbnailMode
        snapshot.hasContent = view?.hasContent ?? false
        snapshot.editing = annotator?.isEditing ?? false
        snapshot.barVisible = annotator?.debugBarVisible ?? false
        snapshot.barFrame = annotator?.debugBarFrame ?? .zero
        snapshot.canvasInteractive = annotator?.debugCanvasInteractive ?? false
        snapshot.cursorIsArrow = annotator?.debugCursorIsArrow ?? false
        snapshot.annotationRects = annotator?.document.annotations.map(\.bounds) ?? []
        snapshot.selectionRect = annotator?.document.selectedAnnotation?.bounds
        snapshot.stored = pinID != nil
        return snapshot
    }

    func debugHitIsCanvas(at point: CGPoint) -> Bool {
        guard let canvas = annotator?.debugCanvas else { return false }
        return window?.contentView?.hitTest(point) === canvas
    }

    func debugMakeKey() {
        window?.makeKey()
    }

    /// 复现 AppKit 的派发：编辑态第一响应者是画布，其余是贴图视图。
    @discardableResult
    func debugSendKey(_ event: NSEvent) -> Bool {
        if annotator?.isEditing == true, let canvas = annotator?.debugCanvas {
            canvas.keyDown(with: event)
            return true
        }
        guard let view else { return false }
        view.keyDown(with: event)
        return true
    }

    /// 诊断用：合成一次滚轮事件（正数放大），走的是真 `scrollWheel` 那条路。
    func debugScroll(lines: Int32) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                               wheel1: lines, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg),
              let view
        else { return }
        view.scrollWheel(with: event)
    }

    /// 诊断用：在窗口内指定一点做一次缩放（滚轮和捏合最终都落到这里）。
    /// 合成事件带不了窗口内坐标，指针位置只能这样喂进来。
    func debugZoomGesture(step: CGFloat, at local: NSPoint) {
        zoomByGesture(step: step, at: local)
    }

    /// 诊断用：窗口里这一点归谁处理（点用窗口坐标）
    func debugHitView(at point: CGPoint) -> NSView? {
        window?.contentView?.hitTest(point)
    }

    /// 诊断用：绕过键盘直接进/出标注（`--pin-probe` 截图用）。
    func debugSetEditing(_ editing: Bool) {
        if editing {
            ensureAnnotator()?.setEditing(true)
        } else {
            annotator?.setEditing(false)
        }
    }

    private func toggleEditing() {
        guard let annotator = ensureAnnotator() else { return }
        annotator.setEditing(!annotator.isEditing)
    }

    private func changeOpacity(by delta: CGFloat) {
        guard let window else { return }
        let next = min(max(window.alphaValue + delta, 0.2), 1)
        window.alphaValue = next
        if let store, let pinID { store.updateOpacity(id: pinID, opacity: Double(next)) }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard let window else { return }
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: frame.origin.x + dx, y: frame.origin.y + dy))
        scheduleSave()
    }

    /// 缩略图模式：缩到长边 160pt，再按 R 回到「原样」。
    ///
    /// 「原样」是最后一次手动缩放（滚轮 / 键位 / 双击）后的大小，见 `applyZoom`。
    /// 这样滚到满意尺寸 → R 收起 → R 放回，回到的正是刚调好的那一档。
    private func toggleThumbnail() {
        annotator?.setEditing(false)
        if isThumbnailMode {
            setThumbnailMode(false)
            setZoom(baseZoom)
            return
        }
        let longest = max(baseSize.width, baseSize.height)
        guard longest > 0 else { return }
        let target = min(zoom, Self.thumbnailLongest / longest)
        // 已经比缩略图还小时不再缩，但状态照进：再按一下照样能放回原样。
        setThumbnailMode(true)
        if target < zoom - 0.001 { setZoom(target) }
    }

    /// 缩略态 = 加粗边框。状态和边框一起切，避免「收起来了但没有加粗」这种半截状态。
    ///
    /// 用边框而不是动画提示：不带定时器、不挪窗口，缩略图摆多久都不烧 CPU。
    private func setThumbnailMode(_ on: Bool) {
        isThumbnailMode = on
        view?.emphasizedBorder = on
    }

    /// 诊断用：缩略态那圈加粗边框有没有真的交给视图去画。
    var debugBorderEmphasized: Bool { view?.emphasizedBorder ?? false }

    // MARK: - 位置与倍率

    private func initialRect() -> CGRect {
        let screen = screenForAnchor()
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // 太大的图先缩到屏内，否则贴图会盖满整块屏幕
        let fit = Self.fitZoom(baseSize: baseSize, in: visible)
        zoom = fit
        let size = CGSize(width: baseSize.width * fit, height: baseSize.height * fit)

        var origin = CGPoint(x: visible.midX - size.width / 2,
                             y: visible.midY - size.height / 2)
        if let anchor, let frame = screen?.frame {
            // 全局坐标是左上原点，Cocoa 是左下原点
            origin = CGPoint(x: anchor.minX, y: frame.maxY - anchor.minY - size.height)
        }
        return CGRect(origin: origin, size: size)
    }

    private func screenForAnchor() -> NSScreen? {
        guard let anchor else { return NSScreen.main }
        return NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
    }

    private func clamped(_ frame: CGRect) -> CGRect {
        // 只要还有一部分落在某块屏上就保持原位，允许跨屏
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        guard !visible else { return frame }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: screen.midX - frame.width / 2,
                      y: screen.midY - frame.height / 2,
                      width: frame.width,
                      height: frame.height)
    }

    /// 滚轮 / 触控板捏合：按比例乘，锚在指针那一点，图围着指针长大缩小。
    ///
    /// 手动调过的倍率就是新的「原样」——滚到满意大小后按 R 收起来，再按一下回到的是
    /// 这个大小，而不是创建贴图那一刻的大小。否则每次调完都要重新滚一遍。
    private func zoomByGesture(step: CGFloat, at anchorInWindow: NSPoint) {
        guard let window else { return }
        // 缩略态下一滚就退回原样再继续；往里缩（step < 0）没有更小的去处，不理。
        if isThumbnailMode, step <= 0 { return }
        // 锚点只在改窗口之前换算一次。缩略态先回原样再叠这一格如果分两步，
        // 第二步拿的还是缩略窗口里的坐标，窗口已经变大，同一个坐标就指到别处，
        // 图会整个甩出屏幕（再按 R 收到屏幕外，看起来就是贴图没了）。
        let anchor = window.convertPoint(toScreen: anchorInWindow)
        let from = isThumbnailMode ? baseZoom : zoom
        applyZoom(from * (1 + step), remember: true, screenAnchor: anchor)
    }

    /// 键盘缩放按比例：`=` 三次再 `-` 三次要回到原样。
    /// 按「当前值的 10%」加减做不到这点——放大到 1.331 之后连减三次是 0.970，
    /// 来回几次就漂到别的倍率上，用户只会觉得键位不听话。
    private func changeZoom(byRatio ratio: CGFloat) {
        applyZoom(zoom * ratio, remember: true)
    }

    /// - Parameters:
    ///   - remember: 这次缩放要不要成为新的「原样」（R 从缩略图还原的目标）。
    ///     手动缩放传 true；缩略图自己的进出传 false，否则目标倍率会被缩略倍率顶掉。
    ///   - screenAnchor: 屏幕坐标里的锚点，缩放时这一点不动。默认窗口中心。
    ///     要锚在指针上的调用方得自己先换算好再传进来——窗口一变，
    ///     窗口内坐标就不再指向同一个点了。
    private func applyZoom(_ value: CGFloat, remember: Bool = false, screenAnchor: CGPoint? = nil) {
        guard let window else { return }
        // 下限放到 0.05：缩略图模式要把长边收到 160pt，大图那一档会低于 0.25
        let next = min(max(value, 0.05), 4)
        guard abs(next - zoom) > 0.001 else { return }

        let previous = zoom
        zoom = next
        if remember {
            // 手动改尺寸就是退出缩略态，边框跟着回到细的
            if isThumbnailMode { setThumbnailMode(false) }
            baseZoom = next
        }

        let anchor = screenAnchor ?? CGPoint(x: window.frame.midX, y: window.frame.midY)
        window.setFrame(frame(forZoom: next, anchoredAt: anchor, from: previous),
                        display: true, animate: false)
        scheduleSave()
    }

    private func frame(forZoom value: CGFloat, anchoredAt anchor: CGPoint,
                       from previous: CGFloat) -> CGRect {
        let frame = window?.frame ?? .zero
        let ratio = value / max(previous, 0.0001)
        let size = CGSize(width: baseSize.width * value, height: baseSize.height * value)
        let origin = CGPoint(x: anchor.x - (anchor.x - frame.minX) * ratio,
                             y: anchor.y - (anchor.y - frame.minY) * ratio)
        return CGRect(origin: origin, size: size)
    }

    private func setZoom(_ value: CGFloat) {
        applyZoom(value)
    }

    /// 双击：100% ⇄ 适配屏幕
    private func toggleActualSize() {
        let visible = window?.screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = min(1, (visible.width * 0.8) / baseSize.width, (visible.height * 0.8) / baseSize.height)
        // 双击也是「手动定尺寸」，和 R 的还原目标对齐，不然按一次 R 就跳回旧大小
        applyZoom(abs(zoom - 1) < 0.01 ? fit : 1, remember: true)
    }

    private func scheduleSave() {
        guard store != nil, pinID != nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window, let pinID = self.pinID else { return }
            self.store?.updateFrame(id: pinID, frame: window.frame,
                                    screenUUID: Self.screenUUID(window.screen),
                                    baseZoom: self.baseZoom,
                                    thumbnail: self.isThumbnailMode)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func windowDidMove(_ notification: Notification) {
        // 工具条是宿主的子窗口，跟着动；但缩放/贴边重排还得自己算一遍
        annotator?.layoutChrome()
        scheduleSave()
    }

    func windowDidResize(_ notification: Notification) {
        annotator?.layoutChrome()
        scheduleSave()
    }

    // MARK: - 右键菜单

    private func showMenu(for event: NSEvent) -> Bool {
        let menu = NSMenu()

        // 键位写在标题里，不当 keyEquivalent：弹出菜单里挂等价键会真去抢键盘
        let annotate = NSMenuItem(title: annotator?.isEditing == true ? "完成编辑  空格" : "标注  空格",
                                  action: #selector(toggleEditMenuItem),
                                  keyEquivalent: "")
        annotate.target = self
        menu.addItem(annotate)

        let thumbnail = NSMenuItem(title: "缩略图模式  R", action: #selector(toggleThumbnailMenuItem),
                                   keyEquivalent: "")
        thumbnail.target = self
        thumbnail.state = isThumbnailMode ? .on : .off
        menu.addItem(thumbnail)

        menu.addItem(.separator())

        let copy = NSMenuItem(title: "复制图片  ↩", action: #selector(copyImage), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

        let save = NSMenuItem(title: "保存到本地  ⌘D", action: #selector(saveImage), keyEquivalent: "")
        save.target = self
        menu.addItem(save)

        let saveAndCopy = NSMenuItem(title: "保存并复制  ⇧⌘D", action: #selector(saveAndCopyImage),
                                     keyEquivalent: "")
        saveAndCopy.target = self
        menu.addItem(saveAndCopy)

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "总在最前", action: #selector(toggleFloating), keyEquivalent: "")
        toggle.target = self
        toggle.state = (window?.level ?? .floating) == .floating ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        for percent in [50, 100, 200] as [CGFloat] {
            let item = NSMenuItem(title: "\(Int(percent))%", action: #selector(applyPresetZoom(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(percent)
            item.state = abs(zoom * 100 - percent) < 0.5 ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let opacityMenu = NSMenu()
        for percent in [100, 80, 60, 40] as [CGFloat] {
            let item = NSMenuItem(title: "\(Int(percent))%", action: #selector(applyOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(percent)
            item.state = abs((window?.alphaValue ?? 1) * 100 - percent) < 0.5 ? .on : .off
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())
        let closeItem = NSMenuItem(title: "关闭", action: #selector(closeMenuItem), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)

        NSMenu.popUpContextMenu(menu, with: event, for: event.window?.contentView ?? NSView())
        return true
    }

    @objc private func copyImage() {
        // 有标注就复制合成的，没有就复制原图；`flattened()` 两种情况都对
        if let annotator {
            annotator.copyFlattened()
            return
        }
        guard let full = source.full() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: full, size: .zero)])
    }

    @objc private func saveImage() {
        guard let annotator = ensureAnnotator() else { return }
        annotator.saveFlattened()
    }

    @objc private func saveAndCopyImage() {
        guard let annotator = ensureAnnotator() else { return }
        annotator.saveAndCopy()
    }

    @objc private func toggleEditMenuItem() {
        toggleEditing()
    }

    @objc private func toggleThumbnailMenuItem() {
        toggleThumbnail()
    }

    @objc private func toggleFloating() {
        window?.level = (window?.level == .floating) ? .normal : .floating
    }

    @objc private func applyPresetZoom(_ sender: NSMenuItem) {
        // 菜单里点定倍率也是手动定尺寸，R 还原跟着它走
        applyZoom(CGFloat(sender.tag) / 100, remember: true)
    }

    @objc private func applyOpacity(_ sender: NSMenuItem) {
        window?.alphaValue = CGFloat(sender.tag) / 100
        if let store, let pinID {
            store.updateOpacity(id: pinID, opacity: Double(sender.tag) / 100)
        }
    }

    @objc private func closeMenuItem() {
        close()
    }

    static func screenUUID(_ screen: NSScreen?) -> String? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

// MARK: - 窗口与视图

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PinView: NSView {
    private let source: PinImageSource
    /// 按窗口像素重采样后的显示位图，和 bounds 在设备像素上一一对应。
    private var displayImage: CGImage?
    private var displayBucket = 0
    var onZoom: ((CGFloat, NSPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    /// 键位交给控制器（贴图的键位表和截图态不一样，实现只该有一份）。
    var onKey: ((NSEvent) -> Bool)?
    var onMenu: ((NSEvent) -> Bool)?
    var onDropFile: ((URL) -> Void)?

    /// 诊断用：显示位图有没有解出来。
    var hasContent: Bool { displayImage != nil }

    /// 缩略态那圈加粗边框。纯绘制，没有动画、没有定时器，缩略图摆一整天也不耗 CPU。
    var emphasizedBorder = false {
        didSet {
            guard emphasizedBorder != oldValue else { return }
            needsDisplay = true
        }
    }

    init(source: PinImageSource) {
        self.source = source
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - 从 Finder 拖图进来

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                    options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURLs(sender).first else { return false }
        onDropFile?(url)
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDisplayImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDisplayImage()
    }

    /// 只按「窗口设备像素」取图：2920×1800 的截图钉成 600pt 窗口时，
    /// 2x 屏上只需要 1200px，没必要留全图。
    private func updateDisplayImage() {
        let scale = window?.backingScaleFactor ?? 2
        let need = Int(ceil(max(bounds.width, bounds.height) * scale))
        guard need > 0, need != displayBucket else { return }
        displayBucket = need
        displayImage = source.display(maxPixel: need)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let displayImage {
            // 显示位图通常已经按设备像素对齐，再插值只会糊；
            // 只有原图比窗口还小（放大）时才需要平滑插值。
            let scale = window?.backingScaleFactor ?? 2
            let deviceWidth = bounds.width * scale
            context.interpolationQuality = CGFloat(displayImage.width) < deviceWidth ? .high : .none
            AnnotateRenderer.drawImage(displayImage, in: bounds, context: context)
        }

        // 边框：细线只用来和图内容分开；缩略态换成粗圈，静止的，不花一帧定时器
        if emphasizedBorder {
            // 粗黑圈 + 内侧白线：深色截图和浅色截图上都能一眼看到
            NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85).setStroke()
            let outer = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            outer.lineWidth = 3
            outer.stroke()

            NSColor(white: 1, alpha: 0.9).setStroke()
            let inner = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
            inner.lineWidth = 1
            inner.stroke()
        } else {
            // 细边框：和图内容区分开，浅色截图上也能看出边界
            NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35).setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // 触控板给的是像素级增量（一格 ≈ 10 点、一次滑动几十个事件），
        // 滚轮给的是行数（一格 1 行）。两者量纲差一个数量级，分开换算成比例步长。
        // 一格滚轮约 8%，单次事件封顶 12%：甩一下触控板不至于把图弹出屏幕。
        let step = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / 500
            : event.scrollingDeltaY * 0.08
        onZoom?(min(max(step, -0.12), 0.12), event.locationInWindow)
    }

    /// 触控板双指捏合：`magnification` 已经是「相对上一帧的比例」（捏开 0.1 就是放大 10%），
    /// 逐帧乘上去，手指张多大图就长多大，不用再换算量纲。
    override func magnify(with event: NSEvent) {
        onZoom?(min(max(event.magnification, -0.12), 0.12), event.locationInWindow)
    }

    /// 只读态的拖拽锚点：屏幕坐标 + 窗口原点。
    ///
    /// 拖窗口这事不能交给 `isMovableByWindowBackground`：这个视图自己实现了
    /// `mouseDown`（双击缩放），AppKit 的背景拖动就再也不触发了。索性自己算，
    /// 顺带把「标注态不搬窗口」变成一句话——那时候事件根本到不了这里。
    private var dragAnchor: (pointer: CGPoint, origin: CGPoint)?

    /// 只读态才允许搬窗口。画布自己也答了 NO（`interactive` 时），
    /// 这层是兜底：哪天画布不铺满、或者别的子视图接手了点击，
    /// 也不会在标注时把窗口拖跑。
    var allowsWindowDrag = true

    override var mouseDownCanMoveWindow: Bool { allowsWindowDrag }

    override func mouseDown(with event: NSEvent) {
        // 点哪张就把键盘收归哪张：nonactivating panel 默认点了不取 key，
        // 多张并存时 R / 空格会落到上一张身上（看起来就是「按了没反应」）。
        window?.makeKey()
        window?.makeFirstResponder(self)

        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        guard let window else { return }
        dragAnchor = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragAnchor, let window else { return }
        // 用屏幕坐标算位移：窗口跟着动之后，`locationInWindow` 会跟着变，
        // 拿它做增量会抖；屏幕坐标是绝对位置，动多少次都是准的。
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: dragAnchor.origin.x + pointer.x - dragAnchor.pointer.x,
                                      y: dragAnchor.origin.y + pointer.y - dragAnchor.pointer.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if onMenu?(event) != true {
            super.rightMouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

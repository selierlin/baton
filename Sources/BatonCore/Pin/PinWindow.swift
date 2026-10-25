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
    private let onClose: (UUID) -> Void
    /// 往这张贴图上丢文件：交给 PinController 再钉一张，自己不动。
    var onDropFile: ((URL) -> Void)?

    private var window: PinPanel?
    private var view: PinView?
    private var annotator: PinAnnotator?
    private var zoom: CGFloat = 1
    /// 进缩略图之前的倍率；非 nil 就表示现在是缩略图。
    private var thumbnailRestore: CGFloat?
    private var pendingSave: DispatchWorkItem?

    /// 缩略图模式把长边收到这么多点：够看清是什么图，又不至于挡着内容。
    private static let thumbnailLongest: CGFloat = 160

    init(source: PinImageSource, scale: CGFloat, anchor: CGRect?, initialFrame: CGRect?,
         opacity: Double, store: PinStore?, pinID: String?, onClose: @escaping (UUID) -> Void) {
        self.source = source
        self.imageScale = max(scale, 1)
        self.baseSize = CGSize(width: source.pixelSize.width / max(scale, 1),
                               height: source.pixelSize.height / max(scale, 1))
        self.anchor = anchor
        self.initialFrame = initialFrame
        self.initialOpacity = opacity
        self.store = store
        self.pinID = pinID
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
            zoom = initialFrame.width / max(baseSize.width, 1)
        } else {
            panel = PinPanel(contentRect: initialRect(),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
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
        view.onZoom = { [weak self] delta in self?.changeZoom(by: delta) }
        view.onDoubleClick = { [weak self] in self?.toggleActualSize() }
        view.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        view.onMenu = { [weak self] event in self?.showMenu(for: event) ?? false }
        view.onDropFile = { [weak self] url in self?.onDropFile?(url) }
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
                                    opacity: Double(panel.alphaValue))
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
        snapshot.isThumbnail = thumbnailRestore != nil
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

    /// 缩略图模式：缩到长边 160pt，再按 R 回到原倍率。
    private func toggleThumbnail() {
        annotator?.setEditing(false)
        if let restore = thumbnailRestore {
            thumbnailRestore = nil
            setZoom(restore)
            return
        }
        let longest = max(baseSize.width, baseSize.height)
        guard longest > 0 else { return }
        let target = min(zoom, Self.thumbnailLongest / longest)
        guard target < zoom - 0.001 else { return }
        thumbnailRestore = zoom
        setZoom(target)
    }

    // MARK: - 位置与倍率

    private func initialRect() -> CGRect {
        let screen = screenForAnchor()
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // 太大的图先缩到屏内，否则贴图会盖满整块屏幕
        let fit = min(1, (visible.width * 0.8) / baseSize.width, (visible.height * 0.8) / baseSize.height)
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

    private func changeZoom(by delta: CGFloat) {
        applyZoom(zoom + delta)
    }

    /// 键盘缩放按比例：`=` 三次再 `-` 三次要回到原样。
    /// 按「当前值的 10%」加减做不到这点——放大到 1.331 之后连减三次是 0.970，
    /// 来回几次就漂到别的倍率上，用户只会觉得键位不听话。
    private func changeZoom(byRatio ratio: CGFloat) {
        applyZoom(zoom * ratio)
    }

    private func applyZoom(_ value: CGFloat) {
        guard let window else { return }
        // 下限放到 0.05：缩略图模式要把长边收到 160pt，大图那一档会低于 0.25
        let next = min(max(value, 0.05), 4)
        guard abs(next - zoom) > 0.001 else { return }

        // 以窗口中心为锚点缩放
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        zoom = next
        let size = CGSize(width: baseSize.width * zoom, height: baseSize.height * zoom)
        let frame = CGRect(x: center.x - size.width / 2,
                           y: center.y - size.height / 2,
                           width: size.width,
                           height: size.height)
        window.setFrame(frame, display: true, animate: false)
        scheduleSave()
    }

    private func setZoom(_ value: CGFloat) {
        changeZoom(by: value - zoom)
    }

    /// 双击：100% ⇄ 适配屏幕
    private func toggleActualSize() {
        let visible = window?.screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = min(1, (visible.width * 0.8) / baseSize.width, (visible.height * 0.8) / baseSize.height)
        setZoom(abs(zoom - 1) < 0.01 ? fit : 1)
    }

    private func scheduleSave() {
        guard store != nil, pinID != nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window, let pinID = self.pinID else { return }
            self.store?.updateFrame(id: pinID, frame: window.frame,
                                    screenUUID: Self.screenUUID(window.screen))
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
        thumbnail.state = thumbnailRestore == nil ? .off : .on
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
        setZoom(CGFloat(sender.tag) / 100)
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
    var onZoom: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?
    /// 键位交给控制器（贴图的键位表和截图态不一样，实现只该有一份）。
    var onKey: ((NSEvent) -> Bool)?
    var onMenu: ((NSEvent) -> Bool)?
    var onDropFile: ((URL) -> Void)?

    /// 诊断用：显示位图有没有解出来。
    var hasContent: Bool { displayImage != nil }

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

        // 细边框：和图内容区分开，浅色截图上也能看出边界
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func scrollWheel(with event: NSEvent) {
        // 触控板给的是像素级增量，滚轮给的是行数，两者量纲差一个数量级
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300 : event.scrollingDeltaY / 40
        onZoom?(delta)
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

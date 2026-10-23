import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 贴图管理器：只管创建与回收，窗口生命周期自己管。
@MainActor
public final class PinController {
    private var pins: [PinWindowController] = []
    private let store: PinStore?

    public init(store: PinStore? = nil) {
        self.store = store
    }

    public var count: Int { pins.count }

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
    private var zoom: CGFloat = 1
    private var pendingSave: DispatchWorkItem?

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
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.alphaValue = CGFloat(initialOpacity)
        panel.delegate = self

        let view = PinView(source: source)
        view.onZoom = { [weak self] delta in self?.changeZoom(by: delta) }
        view.onDoubleClick = { [weak self] in self?.toggleActualSize() }
        view.onClose = { [weak self] in self?.close() }
        view.onMenu = { [weak self] event in self?.showMenu(for: event) ?? false }
        view.onDropFile = { [weak self] url in self?.onDropFile?(url) }
        panel.contentView = view

        // 贴图不抢焦点：截图后用户往往马上要滚动/继续打字，
        // nonactivating panel 只有被点中时才成为 key。
        panel.becomesKeyOnlyIfNeeded = true
        panel.orderFrontRegardless()
        window = panel

        // 只有新钉的才写库；恢复出来的已经有记录
        if pinID == nil, let store, let image = source.full() {
            pinID = try? store.save(image: image, scale: imageScale, frame: panel.frame,
                                    screenUUID: Self.screenUUID(panel.screen),
                                    opacity: Double(panel.alphaValue))
            // 落库后原图可以从内存里放掉，之后显示按窗口像素取、导出时再从 blob 解
            if pinID != nil { source.releaseOriginal() }
        }
    }

    func close() {
        pendingSave?.cancel()
        guard let window else { return }
        if let store, let pinID { store.delete(id: pinID) }
        window.delegate = nil
        window.close()
        self.window = nil
        onClose(id)
        ActionLog.result("pin.close", "id=\(id.uuidString.prefix(8))")
    }

    func windowWillClose(_ notification: Notification) {
        pendingSave?.cancel()
        if let store, let pinID { store.delete(id: pinID) }
        window = nil
        onClose(id)
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
        guard let window else { return }
        let next = min(max(zoom + delta, 0.25), 4)
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

    func windowDidMove(_ notification: Notification) { scheduleSave() }
    func windowDidResize(_ notification: Notification) { scheduleSave() }

    // MARK: - 右键菜单

    private func showMenu(for event: NSEvent) -> Bool {
        let menu = NSMenu()

        let copy = NSMenuItem(title: "复制图片", action: #selector(copyImage), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

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
        guard let full = source.full() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: full, size: .zero)])
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
    var onClose: (() -> Void)?
    var onMenu: ((NSEvent) -> Bool)?
    var onDropFile: ((URL) -> Void)?

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

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if onMenu?(event) != true {
            super.rightMouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClose?()
            return
        }
        super.keyDown(with: event)
    }
}

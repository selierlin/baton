import AppKit
import CoreGraphics

/// 标注窗口：工具条 + 画布。
///
/// 窗口尺寸按图片逻辑尺寸（像素 ÷ 倍率）一次算好，不做可缩放窗口——
/// 截图工具里「所见即所得」比「能拖大」重要，缩放留给贴图窗口。
@MainActor
public final class AnnotateWindowController: NSObject, NSWindowDelegate {
    public enum Outcome: Sendable {
        case copied
        case saved(URL)
        case pinned
        /// 交给外部动作（打开 / 隔空投送 / QR 解码）继续，窗口已经关掉。
        case handedOff
        case cancelled
    }

    public var onFinish: ((Outcome) -> Void)?

    private var window: NSWindow?
    /// 每开一次标注窗口都换新文档，避免上一张图的标注残留。
    private var document = AnnotateDocument()
    private var canvas: AnnotateCanvasView?
    private var image: CGImage?
    private var bar: AnnotateBarView?
    private var properties: AnnotatePropertyBarView?
    private var propertyWidthConstraint: NSLayoutConstraint?
    private var scale: CGFloat = 1
    private var hasFinished = false
    private let pinController: PinController

    public init(pinController: PinController) {
        self.pinController = pinController
        super.init()
    }

    public var isVisible: Bool { window?.isVisible ?? false }
    public var debugFrame: CGRect { window?.frame ?? .zero }

    /// 诊断用：把当前标注的几何摊开
    public func debugDump() -> String {
        "count=\(document.annotations.count) selection=\(document.selection?.uuidString ?? "nil")\n"
            + document.annotations.map { "  \($0.kind) bounds=\($0.bounds)" }.joined(separator: "\n")
    }

    public func show(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = max(scale, 1)
        document = AnnotateDocument()

        let logical = CGSize(width: CGFloat(image.width) / scale,
                             height: CGFloat(image.height) / scale)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxSize = CGSize(width: screen.width * 0.85, height: screen.height * 0.82)
        let fit = min(1, maxSize.width / logical.width, maxSize.height / logical.height)
        // 长截图比屏幕高，不能缩成一条：按 1:1 放进滚动视图
        let needsScroll = logical.width > maxSize.width || logical.height > maxSize.height
        let canvasSize = needsScroll
            ? logical
            : CGSize(width: floor(logical.width * fit), height: floor(logical.height * fit))
        let viewport = CGSize(width: min(canvasSize.width, maxSize.width),
                              height: min(canvasSize.height, maxSize.height))

        let barSize = AnnotateBarView().preferredSize
        let propertySize = AnnotatePropertyBarView().preferredSize
        let contentWidth = max(viewport.width, barSize.width, propertySize.width) + 24
        // 窗口高度只能按「可视区」算，不能按整张画布。
        // 长图按 1:1 铺开时画布高几千点，窗口跟着长就会整个铺到屏幕外，
        // 里面那条滚动视图的上下约束也跟着打架——用户看到的就是
        // 「只显示了长图的一小块、而且滚不动」。属性条会随工具显隐，按两条都显示预留。
        let contentHeight = 8 + barSize.height + 6 + propertySize.height + 6 + viewport.height + 6

        let canvas = AnnotateCanvasView(image: image,
                                        document: document,
                                        style: AnnotateStyle().scaled(by: scale))
        canvas.tool = .rectangle
        canvas.onChange = { [weak self] in self?.refreshToolbar() }
        canvas.onCommand = { [weak self] command in self?.perform(command) }
        self.canvas = canvas

        let content = NSView()
        let bar = AnnotateBarView()
        bar.supportsCaptureActions = false
        bar.onTool = { [weak self] tool in
            self?.canvas?.commitPendingText()
            self?.canvas?.tool = tool
            self?.refreshToolbar()
        }
        bar.onCommand = { [weak self] command in self?.perform(command) }
        bar.onMenu = { [weak self] action in self?.handleMenu(action) }
        self.bar = bar

        let properties = AnnotatePropertyBarView()
        properties.onChange = { [weak self] change in self?.apply(change) }
        self.properties = properties

        let bars = NSStackView(views: [bar, properties])
        bars.orientation = .vertical
        bars.alignment = .centerX
        bars.spacing = 6
        bars.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bars)
        content.addSubview(canvas)

        NSLayoutConstraint.activate([
            bars.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            bars.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bar.heightAnchor.constraint(equalToConstant: AnnotateBarView.height),
            bar.widthAnchor.constraint(equalToConstant: barSize.width),
            properties.heightAnchor.constraint(equalToConstant: AnnotatePropertyBarView.height),
        ])
        let widthConstraint = properties.widthAnchor.constraint(equalToConstant: propertySize.width)
        widthConstraint.isActive = true
        propertyWidthConstraint = widthConstraint

        if needsScroll {
            canvas.frame = CGRect(origin: .zero, size: canvasSize)
            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.documentView = canvas
            content.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: bars.bottomAnchor, constant: 6),
                scroll.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
                scroll.widthAnchor.constraint(equalToConstant: viewport.width),
                scroll.heightAnchor.constraint(equalToConstant: viewport.height),
            ])
        } else {
            canvas.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                canvas.topAnchor.constraint(equalTo: bars.bottomAnchor, constant: 6),
                canvas.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
                canvas.widthAnchor.constraint(equalToConstant: canvasSize.width),
                canvas.heightAnchor.constraint(equalToConstant: canvasSize.height),
            ])
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                 width: contentWidth,
                                                 height: contentHeight),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "标注 · \(Int(logical.width))×\(Int(logical.height))"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = content
        window.setContentSize(NSSize(width: contentWidth, height: contentHeight))
        window.center()
        window.makeKeyAndOrderFront(nil)
        // 从后台起来的场景（长截图收尾、尺子交接）里，只调 NSApp.activate 常被系统忽略，
        // 窗口会安静地留在 Safari 后面，用户以为什么都没发生。
        // orderFrontRegardless 不看激活状态，先把窗口压到最前，再尝试拿 key。
        window.orderFrontRegardless()
        window.makeFirstResponder(canvas)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        self.window = window
        hasFinished = false
        refreshToolbar()
    }

    // MARK: - 工具条

    private func refreshToolbar() {
        guard let canvas else { return }
        let selected = document.selectedAnnotation
        let activeTool = selected?.tool ?? canvas.tool
        bar?.refresh(tool: canvas.tool, canUndo: document.canUndo, canRedo: document.canRedo)

        guard let properties else { return }
        properties.isHidden = canvas.tool == .select || activeTool == .colorPick
        let style = (selected?.style ?? canvas.style).unscaled(by: scale)
        let number = selected.flatMap { annotation -> Int? in
            if case .counter(_, let number) = annotation.kind { return number }
            return nil
        } ?? (canvas.counterNumberOverride ?? document.nextCounterNumber)
        properties.configure(.init(tool: activeTool, style: style, number: number))
        propertyWidthConstraint?.constant = properties.preferredSize.width
    }

    private func apply(_ change: AnnotatePropertyBarView.Change) {
        guard let canvas else { return }

        if case .tool(let tool) = change {
            if tool != .select { document.select(nil) }
            canvas.tool = tool
            refreshToolbar()
            return
        }

        if case .counterNumber(let number) = change {
            if let id = document.selection, document.setCounterNumber(number, for: id) {
                canvas.needsDisplay = true
            } else {
                canvas.counterNumberOverride = number
            }
            refreshToolbar()
            return
        }

        var style = document.selectedAnnotation?.style ?? canvas.style
        guard change.merge(into: &style, scale: scale) else { return }

        canvas.style = style
        if let id = document.selection { document.restyle(id: id, style: style) }
        canvas.needsDisplay = true
        refreshToolbar()
    }

    private func perform(_ command: AnnotateCommand) {
        canvas?.commitPendingText()
        switch command {
        case .undo:
            document.undo()
            canvas?.needsDisplay = true
            refreshToolbar()
        case .redo:
            document.redo()
            canvas?.needsDisplay = true
            refreshToolbar()
        case .copy:
            guard let flat = flattened() else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([NSImage(cgImage: flat, size: .zero)])
            finish(.copied)
        case .save:
            guard let flat = flattened() else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "Baton-\(Self.timestamp()).png"
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                guard let data = Self.pngData(flat) else { return }
                try? data.write(to: url)
                self?.finish(.saved(url))
            }
        case .pin:
            guard let flat = flattened(), let image else { return }
            let scale = CGFloat(image.width) / max(canvas?.bounds.width ?? 1, 1)
            pinController.pin(flat, scale: max(scale, 1))
            finish(.pinned)
        case .cancel:
            finish(.cancelled)

        // 识别 / 打开 / 隔空投送只在「原地标注」里有意义（那边有整场截图会话），
        // 独立弹窗只是一张图，没有可交出去的流程
        case .ocr, .qr, .open, .airDrop:
            break
        }
    }

    private func flattened() -> CGImage? {
        guard let image else { return nil }
        return AnnotateRenderer.flatten(base: image, annotations: document.annotations)
    }

    /// 「更多」菜单：都是终态动作，做完就关窗。
    private func handleMenu(_ action: AnnotateBarView.MenuAction) {
        guard let flat = flattened() else { return }
        switch action {
        case .qr:
            let host = window
            AnnotateExport.decodeQR(flat) { [weak self] payloads in
                AnnotateExport.presentQRResult(payloads, attachedTo: host)
                self?.finish(.handedOff)
            }
        case .open:
            AnnotateExport.open(flat)
            finish(.handedOff)
        case .airDrop:
            // 先关窗：隔空投送的面板会挂在当前窗口上
            finish(.handedOff)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                AnnotateExport.airDrop(flat)
            }
        case .saveAndCopy:
            AnnotateExport.copy(flat)
            perform(.save)
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !hasFinished else { return }
        hasFinished = true
        window?.close()
        window = nil
        releaseContent()
        onFinish?(outcome)
    }

    public func windowWillClose(_ notification: Notification) {
        // 用户点红点关窗
        guard !hasFinished else { return }
        hasFinished = true
        window?.contentView = nil
        window = nil
        releaseContent()
        onFinish?(.cancelled)
    }

    /// 关窗后立刻断掉对整张图的引用。
    ///
    /// 之前只把 `window` 置 nil，`canvas` / `image` 还挂在这个常驻单例上：
    /// 长图（1600×1600 起步）的位图和视图后备存储一直不还，连做几轮长截图
    /// 每轮涨 20 多 MB —— 实测 5 轮从 51 MB 涨到 185 MB。
    private func releaseContent() {
        canvas = nil
        bar = nil
        properties = nil
        propertyWidthConstraint = nil
        image = nil
        document = AnnotateDocument()
    }

    // MARK: - 工具

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [:])
    }
}

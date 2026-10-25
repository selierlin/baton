import AppKit
import CoreGraphics

/// 贴图窗口里的标注层：画布 + 工具条 + 属性条。
///
/// 和截图里那两个标注窗口的区别只在「宿主」：
/// - 画布是贴图视图的子视图，坐标空间固定为**原图像素**，
///   所以窗口怎么缩放，标注都贴在图像内容上，导出时也不用换算；
/// - 工具条不能像截图那样浮在选区外面（贴图窗口本身就是整张图），
///   所以挂在一条独立的无边框面板上、跟着窗口走 —— 小图上也不会盖住内容。
///
/// 空格开关图的就是这条面板：没有它，贴图窗口就只是一张图。
@MainActor
final class PinAnnotator {
    let document = AnnotateDocument()

    /// 宿主（贴图窗口的 contentView）。画布挂在它上面，跟它一起缩放。
    private weak var hostView: NSView?
    private weak var hostWindow: NSPanel?
    private let source: PinImageSource

    private var canvas: AnnotateCanvasView?
    private let bar = AnnotateBarView(variant: .pin)
    private let properties = AnnotatePropertyBarView()
    private let panel = PinBarPanel()

    private(set) var isEditing = false

    /// 编辑态变化（进入 / 退出）。宿主用它在画布和贴图视图之间换 first responder。
    var onEditingChange: ((Bool) -> Void)?
    /// 键位交给贴图窗口处理（空格 / R / 缩放这些和截图态重名的键）。
    var onKey: ((NSEvent) -> Bool)?
    /// 「贴图」动作：把合成结果再钉一张。
    var onPin: ((CGImage) -> Void)?

    init(source: PinImageSource, hostView: NSView, hostWindow: NSPanel) {
        self.source = source
        self.hostView = hostView
        self.hostWindow = hostWindow

        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = PinBarContainer(bar: bar, properties: properties)

        bar.onTool = { [weak self] tool in self?.select(tool) }
        bar.onCommand = { [weak self] command in self?.perform(command) }
        bar.onMenu = { [weak self] action in self?.handleMenu(action) }
        properties.onChange = { [weak self] change in self?.apply(change) }
    }

    var hasSelectedAnnotation: Bool { document.selection != nil }

    /// 诊断用：工具条那条面板是不是真的在屏幕上。
    var debugBarVisible: Bool { isEditing && panel.isVisible }

    // MARK: - 编辑态

    func setEditing(_ editing: Bool) {
        guard editing != isEditing else { return }

        if editing {
            guard let canvas = ensureCanvas() else { return }
            isEditing = true
            canvas.interactive = true
            canvas.commitPendingText()
            if let hostWindow {
                if panel.parent == nil { hostWindow.addChildWindow(panel, ordered: .above) }
                panel.orderFront(nil)
                hostWindow.makeKey()
                hostWindow.makeFirstResponder(canvas)
            }
            refreshBar()
            onEditingChange?(true)
        } else {
            isEditing = false
            canvas?.commitPendingText()
            canvas?.interactive = false
            panel.orderOut(nil)
            onEditingChange?(false)
        }
    }

    func toggleEditing() { setEditing(!isEditing) }

    /// 贴图窗口移动/缩放后跟着重排。
    func layoutChrome() {
        guard isEditing else { return }
        layoutPanel()
    }

    /// 宿主关窗：拆掉子窗口与画布，别让位图挂着。
    func dismantle() {
        isEditing = false
        panel.orderOut(nil)
        if let hostWindow { hostWindow.removeChildWindow(panel) }
        canvas?.removeFromSuperview()
        canvas = nil
        document.select(nil)
    }

    // MARK: - 画布

    private var pixelScale: CGFloat {
        guard let canvas, canvas.bounds.width > 0 else { return 1 }
        return CGFloat(canvas.baseImage.width) / canvas.bounds.width
    }

    private func ensureCanvas() -> AnnotateCanvasView? {
        if let canvas { return canvas }
        guard let hostView,
              let image = source.full() else { return nil }

        let pointWidth = max(hostView.bounds.width, 1)
        let style = AnnotateStyle().scaled(by: max(1, CGFloat(image.width) / pointWidth))
        let canvas = AnnotateCanvasView(image: image, document: document, style: style)
        // 底图由贴图视图自己画（它按窗口像素重采样过，比原图直缩更清晰），
        // 画布只负责标注；但 `baseImage` 仍然留着原图——马赛克要从原像素取。
        canvas.drawsBaseImage = false
        canvas.tool = .rectangle
        canvas.frame = hostView.bounds
        canvas.autoresizingMask = [.width, .height]
        canvas.onChange = { [weak self] in self?.refreshBar() }
        canvas.onCommand = { [weak self] in self?.perform($0) }
        canvas.keyInterceptor = { [weak self] event in self?.onKey?(event) ?? false }
        hostView.addSubview(canvas)
        self.canvas = canvas
        return canvas
    }

    /// 把标注烧结到原图上：复制 / 保存 / 再贴图都走这里。
    func flattened() -> CGImage? {
        guard let base = canvas?.baseImage ?? source.full() else { return nil }
        return AnnotateRenderer.flatten(base: base, annotations: document.annotations)
    }

    // MARK: - 工具条

    private func select(_ tool: AnnotateTool) {
        canvas?.commitPendingText()
        canvas?.tool = tool
        refreshBar()
    }

    private func refreshBar() {
        guard let canvas else { return }
        let selected = document.selectedAnnotation
        let activeTool = selected?.tool ?? canvas.tool
        bar.refresh(tool: canvas.tool, canUndo: document.canUndo, canRedo: document.canRedo)

        let scale = pixelScale
        properties.isHidden = canvas.tool == .select || activeTool == .colorPick
        let style = (selected?.style ?? canvas.style).unscaled(by: scale)
        let number = selected.flatMap { annotation -> Int? in
            if case .counter(_, let number) = annotation.kind { return number }
            return nil
        } ?? (canvas.counterNumberOverride ?? document.nextCounterNumber)
        properties.configure(.init(tool: activeTool, style: style, number: number))
        layoutPanel()
    }

    private func apply(_ change: AnnotatePropertyBarView.Change) {
        guard let canvas else { return }

        if case .tool(let tool) = change {
            if tool != .select { document.select(nil) }
            canvas.tool = tool
            refreshBar()
            return
        }

        if case .counterNumber(let number) = change {
            if let id = document.selection, document.setCounterNumber(number, for: id) {
                canvas.needsDisplay = true
            } else {
                canvas.counterNumberOverride = number
            }
            refreshBar()
            return
        }

        var style = document.selectedAnnotation?.style ?? canvas.style
        guard change.merge(into: &style, scale: pixelScale) else { return }
        canvas.style = style
        if let id = document.selection { document.restyle(id: id, style: style) }
        canvas.needsDisplay = true
        refreshBar()
    }

    // MARK: - 面板布局

    private func layoutPanel() {
        guard let hostWindow, isEditing else { return }
        let barSize = bar.preferredSize
        let propSize = properties.isHidden ? .zero : properties.preferredSize
        let gap: CGFloat = 5.5
        let width = max(barSize.width, propSize.width)
        let height = propSize.height > 0 ? barSize.height + gap + propSize.height : barSize.height

        let pinned = hostWindow.frame
        let screen = hostWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        // 默认贴在窗口下方；下方放不下就翻到上方（和截图工具条同一套规则）
        var y = pinned.minY - SelectionChrome.toolbarGap - height
        if y < screen.minY {
            y = pinned.maxY + SelectionChrome.toolbarGap
        }
        y = min(max(screen.minY, y), max(screen.minY, screen.maxY - height))

        var x = pinned.midX - width / 2
        x = min(max(screen.minX, x), max(screen.minX, screen.maxX - width))

        panel.setFrame(CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height),
                       display: true)

        // 容器里：属性条贴底，工具条贴顶，各自水平居中
        if let container = panel.contentView {
            let bounds = container.bounds
            bar.frame = CGRect(x: (bounds.width - barSize.width) / 2,
                               y: bounds.height - barSize.height,
                               width: barSize.width, height: barSize.height)
            properties.frame = CGRect(x: (bounds.width - propSize.width) / 2,
                                      y: 0,
                                      width: propSize.width, height: propSize.height)
        }
    }

    // MARK: - 命令

    private func perform(_ command: AnnotateCommand) {
        guard let canvas else { return }
        canvas.commitPendingText()

        switch command {
        case .undo:
            document.undo()
            canvas.needsDisplay = true
            refreshBar()
        case .redo:
            document.redo()
            canvas.needsDisplay = true
            refreshBar()
        case .copy:
            copyFlattened()
        case .save:
            saveFlattened()
        case .cancel:
            // 贴图里的红叉是「完成编辑」，不是「关掉这张贴图」
            setEditing(false)
        case .pin:
            if let image = flattened() { onPin?(image) }
        case .open:
            if let image = flattened() { AnnotateExport.open(image) }
        case .airDrop:
            if let image = flattened() { AnnotateExport.airDrop(image) }
        case .qr:
            guard let image = flattened() else { return }
            AnnotateExport.decodeQR(image) { [weak self] payloads in
                AnnotateExport.presentQRResult(payloads, attachedTo: self?.hostWindow)
            }
        case .ocr:
            break
        }
    }

    private func handleMenu(_ action: AnnotateBarView.MenuAction) {
        guard let flat = flattened() else { return }
        switch action {
        case .qr: perform(.qr)
        case .open: AnnotateExport.open(flat)
        case .airDrop: AnnotateExport.airDrop(flat)
        case .saveAndCopy: saveAndCopy()
        }
    }

    // MARK: - 导出

    /// 复制合成图。没画过东西时 `flattened()` 直接返回原图，不会白拷一次。
    func copyFlattened() {
        guard let image = flattened() else { return }
        AnnotateExport.copy(image)
    }

    func saveFlattened() { save() }

    func saveAndCopy() {
        if let image = flattened() { AnnotateExport.copy(image) }
        save()
    }

    private func save() {
        guard let flat = flattened() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Baton-\(Self.timestamp()).png"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:]) else {
                return
            }
            try? data.write(to: url)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - 面板

/// 工具条面板：不激活、不抢 key，只当一条浮在外面的托盘。
private final class PinBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 工具条 + 属性条的容器。两块都是手动摆 frame 的自绘视图，不跑 Auto Layout。
private final class PinBarContainer: NSView {
    init(bar: NSView, properties: NSView) {
        super.init(frame: .zero)
        // 两块都是手动摆 frame 的，别让它们去参与容器的 Auto Layout
        bar.translatesAutoresizingMaskIntoConstraints = true
        properties.translatesAutoresizingMaskIntoConstraints = true
        addSubview(properties)
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }
}

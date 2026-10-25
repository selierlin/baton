import AppKit
import CoreGraphics

/// 原地标注：不新开窗口，直接把画布和工具条挂进截图覆盖层。
///
/// 几何关系和 Longshot 一致——冻结帧铺满全屏、选区外的遮罩保持不变，
/// 画布正好落在选区的屏幕位置上，所以标注从头到尾都是「在原图上画」，
/// 不存在「图片被缩放进另一个窗口」的跳变。
@MainActor
public final class InPlaceAnnotator {
    public enum Outcome: Sendable {
        case copied
        case saved(URL)
        case pinned
        /// 交给外部流程（OCR / 长截图）继续，覆盖层已经让出。
        case handedOff
        case cancelled
    }

    /// 工具条上需要跳出标注流程的两个动作。
    public enum ExternalRequest {
        case ocr(CGImage, silent: Bool)
        case scroll(CaptureResult)
    }

    public var onFinish: ((Outcome) -> Void)?
    public var onExternal: ((ExternalRequest) -> Void)?

    private let pinController: PinController
    /// 每次截图都换一份全新文档，否则上一张图的标注会跟着留到下一次截图。
    private var document = AnnotateDocument()
    private var overlay: OverlayController?
    /// 画布挂在覆盖层的宿主视图上，调选区时要拿它的 bounds 重排工具条
    private var hostView: OverlayView?
    private var canvas: AnnotateCanvasView?
    private var bar: AnnotateBarView?
    private var properties: AnnotatePropertyBarView?
    /// 选区 8 个手柄。画在宿主层而不是画布里：画布的 bounds 就是选区，
    /// 手柄骑在边界上，画在画布内会被裁掉朝外的一半（实测只剩 1/4）。
    private let selectionChrome = CAShapeLayer()
    private var image: CGImage?
    private var result: CaptureResult?
    private var scale: CGFloat = 1
    private var hasFinished = false

    public init(pinController: PinController) {
        self.pinController = pinController
    }

    public var isActive: Bool { canvas != nil }

    // MARK: - 诊断

    /// 场景跑测（`Baton --capture-suite`）读的一次性快照。
    ///
    /// 截图态的坑基本都藏在「画布/工具条/遮罩三者有没有跟着选区走」，
    /// 所以这里把三者的几何一次交出去，断言不用去猜私有状态。
    public struct Snapshot {
        public init() {}

        public var active = false
        public var tool = ""
        /// 图片像素 ÷ 画布点宽
        public var scale: CGFloat = 1
        /// 当前线宽（图片像素），图元包围盒按它外扩
        public var lineWidth: CGFloat = 0
        public var hostBounds: CGRect = .zero
        /// 画布 frame（宿主本地坐标，Cocoa 左下原点）
        public var canvasFrame: CGRect = .zero
        /// 当前选区（全局屏幕坐标，左上原点）
        public var selectionGlobal: CGRect = .zero
        /// 当前裁剪在整屏位图里的像素原点（左上原点）
        public var pixelOrigin = CGPoint.zero
        public var displayOrigin = CGPoint.zero
        public var barFrame: CGRect = .zero
        public var propertiesFrame: CGRect = .zero
        public var barVisible = false
        public var propertiesVisible = false
        /// 8 个手柄的图层挂上了没有
        public var handlesVisible = false
        /// 图元包围盒（图片像素，左上原点）
        public var annotationRects: [CGRect] = []
        /// 选中图元的包围盒（图片像素）
        public var selectionRect: CGRect?
        public var canUndo = false
        public var canRedo = false

        /// 图片像素 → 全局屏幕坐标（点）
        public func screenPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: displayOrigin.x + (pixelOrigin.x + point.x) / scale,
                    y: displayOrigin.y + (pixelOrigin.y + point.y) / scale)
        }

        public func screenRect(forImage rect: CGRect) -> CGRect {
            CGRect(origin: screenPoint(rect.origin),
                   size: CGSize(width: rect.width / scale, height: rect.height / scale))
        }

        public var annotationScreenRects: [CGRect] {
            annotationRects.map(screenRect(forImage:))
        }
    }

    public var debugSnapshot: Snapshot {
        var snapshot = Snapshot()
        guard let canvas, let result, let hostView else { return snapshot }
        snapshot.active = true
        snapshot.tool = canvas.tool.rawValue
        snapshot.scale = scale
        snapshot.lineWidth = canvas.style.lineWidth
        snapshot.hostBounds = hostView.bounds
        snapshot.canvasFrame = canvas.frame
        snapshot.selectionGlobal = result.screenRect
        snapshot.pixelOrigin = result.pixelRect.origin
        snapshot.displayOrigin = result.display.screenFrame.origin
        snapshot.barFrame = bar?.frame ?? .zero
        snapshot.propertiesFrame = properties?.frame ?? .zero
        snapshot.barVisible = bar?.window != nil && bar?.superview != nil
        snapshot.propertiesVisible = properties.map { $0.window != nil && !$0.isHidden } ?? false
        snapshot.handlesVisible = selectionChrome.path != nil && selectionChrome.superlayer != nil
        snapshot.annotationRects = document.annotations.map(\.bounds)
        snapshot.selectionRect = document.selectedAnnotation?.bounds
        snapshot.canUndo = document.canUndo
        snapshot.canRedo = document.canRedo
        return snapshot
    }

    /// 按画布的键位表发一次按键。走 `canvas.keyDown` 而不是系统事件：
    /// 这里要验的是「键位有没有接上」，事件投递那一层在真机上另有覆盖。
    @discardableResult
    public func debugSendKey(_ keyCode: UInt16, command: Bool = false, shift: Bool = false) -> Bool {
        guard let canvas else { return false }
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        let characters = Self.debugCharacters[keyCode] ?? ""
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: canvas.window?.windowNumber ?? 0,
                                           context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else { return false }
        canvas.keyDown(with: event)
        return true
    }

    /// 画布按字符判断的那几个键需要带上字符，否则会落到 `super` 里
    private static let debugCharacters: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 6: "z", 8: "c", 9: "v", 12: "q", 15: "r",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 26: "7", 28: "8",
        24: "=", 27: "-", 31: "o", 35: "p", 49: " ",
    ]

    /// - Returns: 覆盖层不可用（没有对应屏的宿主）时返回 false，调用方可以退回弹窗模式。
    @discardableResult
    public func present(result: CaptureResult, overlay: OverlayController) -> Bool {
        guard let host = overlay.hostView(for: result.display.displayID) as? OverlayView,
              let image = result.cropped,
              let local = overlay.localRect(forGlobal: result.screenRect,
                                            displayID: result.display.displayID),
              local.width >= 2, local.height >= 2 else {
            return false
        }

        self.result = result
        self.overlay = overlay
        self.hostView = host
        self.image = image
        self.hasFinished = false
        // 上一次截图留下的标注（含撤销栈、选中态）不能带进这一次
        document = AnnotateDocument()

        // 画布点宽 = 选区点宽，像素宽 ÷ 点宽就是真实倍率；
        // 标注样式按这个倍率放大，2x 屏上 6px 线看起来才是 3pt。
        scale = CGFloat(image.width) / local.width
        let style = AnnotateStyle().scaled(by: scale)

        let canvas = AnnotateCanvasView(image: image, document: document, style: style)
        // 底图由覆盖层的冻结帧提供，画布只画标注，避免取整误差造成重影
        canvas.drawsBaseImage = false
        canvas.tool = .rectangle
        canvas.frame = local
        // 圈完之后选区还能拖：8 个手柄改尺寸，方向键移/扩缩。
        // 画布拿全局坐标跟宿主对话，自己不用关心屏幕坐标系怎么翻转。
        canvas.adjustableSelection = true
        canvas.selectionFrame = result.screenRect
        canvas.selectionLimit = result.display.screenFrame
        canvas.onSelectionChange = { [weak self] rect in self?.adjustSelection(to: rect) }
        canvas.onChange = { [weak self] in self?.refreshBar() }
        canvas.onCommand = { [weak self] command in self?.perform(command) }
        host.addSubview(canvas)
        self.canvas = canvas
        // 手柄有一半骑在选区边界外侧，事件要从宿主转进来
        host.annotationCanvas = canvas

        let bar = AnnotateBarView()
        // 覆盖层是手动摆 frame 的，不跑 Auto Layout
        bar.translatesAutoresizingMaskIntoConstraints = true
        bar.onTool = { [weak self] tool in self?.select(tool) }
        bar.onCommand = { [weak self] command in self?.perform(command) }
        bar.onExternal = { [weak self] action in self?.handleExternal(action) }
        bar.onMenu = { [weak self] action in self?.handleMenu(action) }
        selectionChrome.fillColor = CGColor(srgbRed: 0.15, green: 0.51, blue: 0.96, alpha: 1)
        selectionChrome.strokeColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)
        selectionChrome.lineWidth = 1
        host.layer?.addSublayer(selectionChrome)
        host.addSubview(bar)
        self.bar = bar

        // 颜色 / 粗细从工具条里拆出来，和 Longshot 一样放在第二条属性条
        let properties = AnnotatePropertyBarView()
        properties.translatesAutoresizingMaskIntoConstraints = true
        properties.onChange = { [weak self] change in self?.apply(change) }
        host.addSubview(properties)
        self.properties = properties

        layoutBars(around: local, in: host.bounds)
        updateSelectionChrome(local)

        host.window?.makeKey()
        host.window?.makeFirstResponder(canvas)
        refreshBar()
        return true
    }

    // MARK: - 布局

    /// 工具条浮在选区下方，间距跟手柄热区绑在一起（`SelectionChrome.toolbarGap`），
    /// 装不下就翻到上方。
    /// 横向：工具条比选区窄时右对齐，比选区宽时居中，最后夹回屏内 3pt。
    /// 属性条贴在工具条下面，左边缘对齐，间隔 5.5pt。
    private func layoutBars(around selection: CGRect, in bounds: CGRect) {
        guard let bar, let properties else { return }

        let gap = SelectionChrome.toolbarGap
        let stackGap: CGFloat = 5.5
        let margin: CGFloat = 10
        let edge: CGFloat = 3
        let height = AnnotateBarView.height
        let showsProperties = !properties.isHidden
        let stackHeight = showsProperties ? height * 2 + stackGap : height

        let barSize = bar.preferredSize
        let available = max(240, bounds.width - margin * 2)
        let barWidth = min(barSize.width, available)

        let below = selection.minY - gap - stackHeight
        var barY: CGFloat
        var propertyY: CGFloat
        if below >= margin {
            barY = selection.minY - gap - height
            propertyY = barY - stackGap - height
        } else {
            barY = selection.maxY + gap
            propertyY = barY + height + stackGap
        }

        // 选区太靠边时把整组夹回屏内，优先保证工具条在可见范围内
        barY = min(max(margin, barY), bounds.height - margin - height)
        propertyY = min(max(margin, propertyY), bounds.height - margin - height)

        var x = barSize.width <= selection.width
            ? selection.maxX - barWidth
            : selection.midX - barWidth / 2
        x = min(max(edge, x), max(edge, bounds.width - edge - barWidth))

        bar.frame = CGRect(x: x.rounded(), y: barY.rounded(), width: barWidth, height: height)

        let propertySize = properties.preferredSize
        let propertyWidth = min(propertySize.width, available)
        let propertyX = min(max(edge, x), max(edge, bounds.width - edge - propertyWidth))
        properties.frame = CGRect(x: propertyX.rounded(), y: propertyY.rounded(),
                                  width: propertyWidth, height: height)
    }

    // MARK: - 选区调整

    /// 选区被拖动或键盘调整后：重裁底图、改画布尺寸、平移已画图元、重排工具条。
    ///
    /// 冻结帧是整屏的，所以「换一块区域」只是一次零拷贝裁剪，不需要重新截屏；
    /// 像素/点的比例也不变，标注样式不用重算。
    private func adjustSelection(to global: CGRect) {
        guard let result, let overlay, let canvas, let hostView else { return }
        let oldScreen = result.screenRect
        guard global != oldScreen, global.width >= 2, global.height >= 2 else { return }

        let oldPixels = result.pixelRect
        let updated = CaptureResult(image: result.image,
                                    pixelRect: CaptureGeometry.pixelRect(forGlobal: global,
                                                                         in: result.display),
                                    screenRect: global,
                                    display: result.display,
                                    action: result.action)
        guard let cropped = updated.cropped,
              let local = overlay.localRect(forGlobal: global,
                                            displayID: result.display.displayID) else { return }

        self.result = updated
        self.image = cropped
        scale = CGFloat(cropped.width) / max(local.width, 1)

        // 标注存的是图片像素：裁剪原点挪了多少，全部图元就补多少。
        // 补对了，图元在屏幕上纹丝不动——它贴的是画面内容，不是选区边框。
        let offset = SelectionGeometry.imageOffset(from: oldPixels, to: updated.pixelRect)
        document.translateAll(dx: offset.x, dy: offset.y)

        canvas.baseImage = cropped
        canvas.selectionFrame = global
        canvas.frame = local
        canvas.needsDisplay = true

        hostView.updateSelection(global)
        layoutBars(around: local, in: hostView.bounds)
        updateSelectionChrome(local)
        ActionLog.action("overlay.adjustSelection",
                         "x=\(Int(global.minX)) y=\(Int(global.minY)) w=\(Int(global.width)) h=\(Int(global.height))")
    }

    private func updateSelectionChrome(_ local: CGRect) {
        selectionChrome.path = SelectionChrome.path(in: local)
    }

    private func refreshBar() {
        guard let canvas, let bar else { return }
        let selected = document.selectedAnnotation
        let activeTool = selected?.tool ?? canvas.tool
        bar.refresh(tool: activeTool, canUndo: document.canUndo, canRedo: document.canRedo)

        guard let properties else { return }
        let wasHidden = properties.isHidden
        // 取色是纯吸管，Longshot 这时不收工具条，但也没有属性条
        properties.isHidden = canvas.tool == .select || activeTool == .colorPick

        let style = (selected?.style ?? canvas.style).unscaled(by: scale)
        let number = selected.flatMap { annotation -> Int? in
            if case .counter(_, let number) = annotation.kind { return number }
            return nil
        } ?? (canvas.counterNumberOverride ?? document.nextCounterNumber)
        properties.configure(.init(tool: activeTool, style: style, number: number))

        // 属性条的内容随工具变宽变窄，每次刷新都要重新排一次
        if let host = properties.superview,
           wasHidden != properties.isHidden || abs(properties.frame.width - properties.preferredSize.width) > 0.5 {
            layoutBars(around: canvas.frame, in: host.bounds)
        }
    }

    /// 属性条的统一入口：改当前工具默认值，有选中元素时同步改它。
    private func apply(_ change: AnnotatePropertyBarView.Change) {
        guard let canvas else { return }

        if case .tool(let tool) = change {
            select(tool)
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
        guard change.merge(into: &style, scale: scale) else { return }

        canvas.style = style
        if let id = document.selection {
            document.restyle(id: id, style: style)
        }
        canvas.needsDisplay = true
        refreshBar()
    }

    private func select(_ tool: AnnotateTool) {
        canvas?.commitPendingText()
        // 从选中态换工具时先取消选中，属性条才会切到新工具的面板
        if tool != .select {
            document.select(nil)
        }
        canvas?.tool = tool
        refreshBar()
    }

    // MARK: - 命令

    private func perform(_ command: AnnotateCommand) {
        canvas?.commitPendingText()
        switch command {
        case .undo:
            document.undo()
            canvas?.needsDisplay = true
            refreshBar()

        case .redo:
            document.redo()
            canvas?.needsDisplay = true
            refreshBar()

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
            // 覆盖层在 statusBar 层，会把保存面板压住
            overlay?.setWindowLevel(.normal)
            panel.begin { [weak self] response in
                self?.overlay?.setWindowLevel(.statusBar)
                guard response == .OK, let url = panel.url,
                      let data = Self.pngData(flat) else { return }
                try? data.write(to: url)
                self?.finish(.saved(url))
            }

        case .pin:
            guard let flat = flattened(), let result else { return }
            let scale = CGFloat(flat.width) / max(result.screenRect.width, 1)
            pinController.pin(flat, scale: max(scale, 1), near: result.screenRect)
            finish(.pinned)

        case .cancel:
            finish(.cancelled)

        case .ocr(let silent):
            guard let flat = flattened() else { return }
            // 先把图交出去，再撤覆盖层：识别面板不吃覆盖层的层级
            finish(.handedOff)
            onExternal?(.ocr(flat, silent: silent))

        case .qr:
            handleMenu(.qr)

        case .open:
            handleMenu(.open)

        case .airDrop:
            handleMenu(.airDrop)
        }
    }

    private func handleExternal(_ action: AnnotateBarView.ExternalAction) {
        switch action {
        case .ocr:
            guard let flat = flattened() else { return }
            // 先把图交出去，再撤覆盖层：识别面板不吃覆盖层的层级
            finish(.handedOff)
            onExternal?(.ocr(flat, silent: false))

        case .scroll:
            guard let result else { return }
            // 覆盖层要留给长截图继续用，只拆编辑器
            detachEditor()
            onExternal?(.scroll(result))
        }
    }

    /// 「更多」菜单：都是终态动作，做完就结束这次标注。
    private func handleMenu(_ action: AnnotateBarView.MenuAction) {
        guard let flat = flattened() else { return }
        switch action {
        case .qr:
            let host = canvas?.window
            AnnotateExport.decodeQR(flat) { [weak self] payloads in
                AnnotateExport.presentQRResult(payloads, attachedTo: host)
                self?.finish(.handedOff)
            }
        case .open:
            AnnotateExport.open(flat)
            finish(.handedOff)
        case .airDrop:
            // 先撤覆盖层：隔空投送的面板会挂在当前窗口上，窗口没了才能独立弹出来
            finish(.handedOff)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                AnnotateExport.airDrop(flat)
            }
        case .saveAndCopy:
            AnnotateExport.copy(flat)
            perform(.save)
        }
    }

    private func flattened() -> CGImage? {
        guard let image else { return nil }
        return AnnotateRenderer.flatten(base: image, annotations: document.annotations)
    }

    /// 拆掉画布与两条工具条，保留覆盖层——长截图接着在同一个选区上滚。
    private func detachEditor() {
        guard !hasFinished else { return }
        hasFinished = true
        canvas?.commitPendingText()
        canvas?.removeFromSuperview()
        bar?.removeFromSuperview()
        properties?.removeFromSuperview()
        selectionChrome.removeFromSuperlayer()
        hostView?.annotationCanvas = nil
        canvas = nil
        bar = nil
        properties = nil
        overlay = nil
    }

    private func finish(_ outcome: Outcome) {
        guard !hasFinished else { return }
        hasFinished = true

        canvas?.commitPendingText()
        canvas?.removeFromSuperview()
        bar?.removeFromSuperview()
        properties?.removeFromSuperview()
        selectionChrome.removeFromSuperlayer()
        hostView?.annotationCanvas = nil
        canvas = nil
        bar = nil
        properties = nil

        overlay?.dismiss()
        overlay = nil
        onFinish?(outcome)
    }

    // MARK: - 工具

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

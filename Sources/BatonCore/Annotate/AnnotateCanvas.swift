import AppKit
import CoreGraphics

/// 标注画布。视图坐标 = 图片坐标 ÷ 缩放比，`isFlipped` 让两者同为左上原点。
@MainActor
public final class AnnotateCanvasView: NSView {
    public let baseImage: CGImage
    public let document: AnnotateDocument
    public var tool: AnnotateTool = .rectangle {
        didSet {
            window?.invalidateCursorRects(for: self)
            guard tool != .select else { return }
            document.select(nil)
            needsDisplay = true
        }
    }
    public var style: AnnotateStyle
    /// 属性条上改的下一个序号；落完一个就清空，回到自增。
    public var counterNumberOverride: Int?
    /// 原地编辑时底图由覆盖层的冻结帧提供，画布不再画一遍（避免 0.5pt 取整带来重影）。
    public var drawsBaseImage = true
    /// 会话回调：工具或撤销栈变化时刷新工具条
    public var onChange: (() -> Void)?
    /// 命令回调：copy / save / pin / cancel / undo / redo。
    /// 走闭包而不是直接关窗，是因为关窗时机由控制器决定（贴图、保存都要先合成）。
    public var onCommand: ((AnnotateCommand) -> Void)?

    /// 视图点 → 图片像素
    private var pixelScale: CGFloat {
        guard bounds.width > 0 else { return 1 }
        return CGFloat(baseImage.width) / bounds.width
    }

    private var dragStart: CGPoint?
    private var draft: Annotation?
    private var movingOriginal: Annotation?
    private var movingStart: CGPoint?
    private var resizingOriginal: Annotation?
    private var resizingHandle: SelectionHandle?
    private var editingID: UUID?
    private var textField: NSTextField?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    public init(image: CGImage, document: AnnotateDocument = AnnotateDocument(), style: AnnotateStyle) {
        self.baseImage = image
        self.document = document
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 绘制

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        if drawsBaseImage {
            AnnotateRenderer.drawImage(baseImage, in: bounds, context: context)
        }

        // 标注存的是图片像素，画布是视图点：这里必须把坐标系缩回去，
        // 否则 2x 截图上画出来的图形会放大一倍。
        let scale = bounds.width / CGFloat(baseImage.width)
        let imageSize = CGSize(width: baseImage.width, height: baseImage.height)

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        AnnotateRenderer.draw(document.annotations, in: context, imageSize: imageSize,
                              mosaicSource: baseImage, selection: document.selection)
        if let draft {
            AnnotateRenderer.draw(draft, in: context, imageSize: imageSize, mosaicSource: baseImage)
        }
        context.restoreGState()

        if tool == .select, let selected = document.selectedAnnotation {
            drawHandles(for: selected, scale: scale, context: context)
        }
    }

    /// 选中手柄画在视图坐标里，尺寸才不会随 2x 截图放大。
    private func drawHandles(for annotation: Annotation, scale: CGFloat, context: CGContext) {
        for handle in annotation.handles {
            let point = annotation.handlePoint(handle)
            let center = CGPoint(x: point.x * scale, y: point.y * scale)
            let rect = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
            context.saveGState()
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fillEllipse(in: rect.insetBy(dx: -1, dy: -1))
            context.setFillColor(CGColor(srgbRed: 0.15, green: 0.51, blue: 0.96, alpha: 1))
            context.fillEllipse(in: rect)
            context.restoreGState()
        }
    }

    // MARK: - 坐标

    func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * pixelScale, y: point.y * pixelScale)
    }

    // MARK: - 鼠标

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitPendingText()
        let point = convert(event.locationInWindow, from: nil)
        let imagePoint = imagePoint(point)

        switch tool {
        case .select:
            // 双击文字：进入编辑
            if event.clickCount == 2,
               let id = document.hitTest(imagePoint, tolerance: 6 * pixelScale),
               let annotation = document.annotations.first(where: { $0.id == id }),
               annotation.tool == .text || annotation.tool == .labelText {
                startEditing(annotation)
                return
            }

            // 先判手柄，再判图元本体
            if let selected = document.selectedAnnotation,
               let handle = handleHit(at: point, annotation: selected) {
                document.beginTransaction()
                resizingOriginal = selected
                resizingHandle = handle
                return
            }

            if let id = document.hitTest(imagePoint, tolerance: 6 * pixelScale) {
                document.select(id)
                document.beginTransaction()
                movingOriginal = document.annotations.first { $0.id == id }
                movingStart = imagePoint
                needsDisplay = true
                onChange?()
            } else {
                document.select(nil)
                needsDisplay = true
                onChange?()
            }

        case .text:
            beginTextEditing(at: point, imagePoint: imagePoint)

        case .labelText:
            beginTextEditing(at: point, imagePoint: imagePoint, kind: .label)

        case .counter:
            let number = counterNumberOverride ?? document.nextCounterNumber
            counterNumberOverride = nil
            let annotation = Annotation(kind: .counter(center: imagePoint, number: number),
                                        style: style, tool: .counter)
            place(annotation)
            needsDisplay = true
            onChange?()

        case .colorPick:
            pickColor(at: imagePoint)

        default:
            dragStart = imagePoint
            draft = makeAnnotation(from: imagePoint, to: imagePoint, shift: event.modifierFlags.contains(.shift))
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let imagePoint = imagePoint(point)

        if let handle = resizingHandle, let original = resizingOriginal {
            document.updateInPlace(original.resized(handle, to: imagePoint))
            needsDisplay = true
            return
        }

        if let movingStart, let original = movingOriginal {
            var moved = original
            moved.offsetBy(dx: imagePoint.x - movingStart.x, dy: imagePoint.y - movingStart.y)
            document.updateInPlace(moved)
            needsDisplay = true
            return
        }

        guard let dragStart else { return }
        if tool.isFreehand, var draft, case .stroke(var points) = draft.kind {
            // 采样抽稀：距离小于线宽一半的点不记，省内存也免得曲线发抖
            if let last = points.last,
               hypot(imagePoint.x - last.x, imagePoint.y - last.y) < max(style.lineWidth * 0.4, 1) {
                return
            }
            points.append(imagePoint)
            switch tool {
            case .mosaicPencil:
                draft.kind = .mosaicStroke(points: points)
            default:
                draft.kind = .stroke(points: points)
            }
            self.draft = draft
        } else {
            self.draft = makeAnnotation(from: dragStart, to: imagePoint,
                                        shift: event.modifierFlags.contains(.shift))
        }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        if resizingOriginal != nil {
            document.endTransaction()
            resizingOriginal = nil
            resizingHandle = nil
            onChange?()
            return
        }

        if movingOriginal != nil {
            document.endTransaction()
            movingOriginal = nil
            movingStart = nil
            onChange?()
            return
        }

        guard let draft else { return }
        // 单击（无拖动）不留下 0 尺寸图元
        if draft.bounds.width > 2 || draft.bounds.height > 2 || tool.isFreehand {
            var finished = draft
            finished.tool = tool
            place(finished)
        }
        self.draft = nil
        dragStart = nil
        needsDisplay = true
        onChange?()
    }

    /// 落一个新图元。
    ///
    /// 绘制工具下不保留选中态：选中框是选择工具的语义（Longshot 也只在选中时出现），
    /// 画完还留着的话，箭头、直线这种斜向图元外面会多出一个外接四边形虚线框。
    private func place(_ annotation: Annotation) {
        document.add(annotation)
        if tool != .select { document.select(nil) }
    }

    private func makeAnnotation(from start: CGPoint, to end: CGPoint, shift: Bool) -> Annotation {
        let target = shift ? snapped(start: start, end: end) : end
        let rect = CGRect(x: min(start.x, target.x), y: min(start.y, target.y),
                          width: abs(target.x - start.x), height: abs(target.y - start.y))
        switch tool {
        case .rectangle:
            return Annotation(kind: .rectangle(squareIfNeeded(rect, shift: shift, anchor: start)), style: style)
        case .ellipse:
            return Annotation(kind: .ellipse(squareIfNeeded(rect, shift: shift, anchor: start)), style: style)
        case .line:
            return Annotation(kind: .line(start: start, end: target), style: style)
        case .flatArrow:
            return Annotation(kind: .arrow(start: start, end: target, sinkTail: false), style: style)
        case .sinkArrow:
            return Annotation(kind: .arrow(start: start, end: target, sinkTail: true), style: style)
        case .pencil:
            return Annotation(kind: .stroke(points: [start]), style: style)
        case .markerPen:
            var pen = style
            pen.lineWidth = style.lineWidth * 1.4
            return Annotation(kind: .stroke(points: [start]), style: pen)
        case .marker:
            // 荧光笔：粗、半透明，压住文字也还看得见底下的字
            var marker = style
            marker.opacity = 0.38
            marker.lineWidth = style.lineWidth * 3
            return Annotation(kind: .highlight(rect, ellipse: false), style: marker)
        case .markerEllipse:
            var marker = style
            marker.opacity = 0.38
            return Annotation(kind: .highlight(rect, ellipse: true), style: marker)
        case .markerPencil:
            var marker = style
            marker.opacity = 0.38
            marker.lineWidth = style.lineWidth * 3
            return Annotation(kind: .stroke(points: [start]), style: marker)
        case .mosaic:
            return Annotation(kind: .mosaic(rect), style: style)
        case .mosaicEllipse:
            return Annotation(kind: .mosaicEllipse(rect), style: style)
        case .mosaicPencil:
            return Annotation(kind: .mosaicStroke(points: [start]), style: style)
        case .ruler:
            return Annotation(kind: .ruler(start: start, end: target), style: style)
        case .length:
            return Annotation(kind: .length(start: start, end: target), style: style)
        case .area:
            return Annotation(kind: .area(rect), style: style)
        case .select, .text, .labelText, .counter, .colorPick:
            return Annotation(kind: .rectangle(rect), style: style)
        }
    }

    /// 取色：读底图对应像素，复制十六进制值，并把当前画笔颜色换成它。
    private func pickColor(at point: CGPoint) {
        let rect = CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1).integral
        guard rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= CGFloat(baseImage.width), rect.maxY <= CGFloat(baseImage.height),
              let pixel = baseImage.cropping(to: rect) else { return }

        var rgba = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &rgba, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let hex = String(format: "#%02X%02X%02X", rgba[0], rgba[1], rgba[2])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        style.color = AnnotateColor(red: Double(rgba[0]) / 255,
                                    green: Double(rgba[1]) / 255,
                                    blue: Double(rgba[2]) / 255)
        onChange?()
    }

    /// Shift：直线吸附到 45° 倍数
    private func snapped(start: CGPoint, end: CGPoint) -> CGPoint {        let dx = end.x - start.x
        let dy = end.y - start.y
        let angle = atan2(dy, dx)
        let step = CGFloat.pi / 4
        let snappedAngle = (angle / step).rounded() * step
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(snappedAngle) * length,
                       y: start.y + sin(snappedAngle) * length)
    }

    /// Shift：矩形 / 椭圆变正方形，向拖动方向展开
    private func squareIfNeeded(_ rect: CGRect, shift: Bool, anchor: CGPoint) -> CGRect {
        guard shift else { return rect }
        let side = max(rect.width, rect.height)
        let signX: CGFloat = rect.maxX >= anchor.x ? 1 : -1
        let signY: CGFloat = rect.maxY >= anchor.y ? 1 : -1
        let originX = signX > 0 ? anchor.x : anchor.x - side
        let originY = signY > 0 ? anchor.y : anchor.y - side
        return CGRect(x: originX, y: originY, width: side, height: side)
    }

    // MARK: - 文字

    private enum TextKind {
        case plain
        case label
    }

    private var pendingTextKind: TextKind = .plain
    private var pendingTextStyle: AnnotateStyle?

    private func beginTextEditing(at point: CGPoint, imagePoint: CGPoint,
                                  kind: TextKind = .plain,
                                  initial: String = "",
                                  existing: Annotation? = nil) {
        commitPendingText()
        pendingTextKind = kind
        pendingTextStyle = existing?.style
        editingID = existing?.id
        let textStyle = existing?.style ?? style
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y,
                                              width: 240,
                                              height: textStyle.fontSize / pixelScale * 1.4))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: textStyle.fontSize / pixelScale, weight: .bold)
        field.textColor = NSColor(cgColor: textStyle.color.cgColor) ?? .systemRed
        field.placeholderString = kind == .label ? "说明..." : "输入文字，回车确认"
        field.stringValue = initial
        field.target = self
        field.action = #selector(commitText(_:))
        field.identifier = NSUserInterfaceItemIdentifier("\(imagePoint.x),\(imagePoint.y)")
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// 双击已有文字：用它的位置和样式重新打开输入框。
    private func startEditing(_ annotation: Annotation) {
        switch annotation.kind {
        case .text(let origin, let string):
            let point = CGPoint(x: origin.x / pixelScale, y: origin.y / pixelScale)
            beginTextEditing(at: point, imagePoint: origin, kind: .plain,
                             initial: string, existing: annotation)
        case .labelText(let origin, let string):
            let point = CGPoint(x: origin.x / pixelScale, y: origin.y / pixelScale)
            beginTextEditing(at: point, imagePoint: origin, kind: .label,
                             initial: string, existing: annotation)
        default:
            break
        }
    }

    private func handleHit(at point: CGPoint, annotation: Annotation) -> SelectionHandle? {
        for handle in annotation.handles {
            let image = annotation.handlePoint(handle)
            let center = CGPoint(x: image.x / pixelScale, y: image.y / pixelScale)
            if hypot(center.x - point.x, center.y - point.y) <= 7 {
                return handle
            }
        }
        return nil
    }

    @objc private func commitText(_ sender: NSTextField) {
        commitPendingText()
    }

    /// 结束文字编辑：有内容就落成标注，空则丢弃。
    public func commitPendingText() {
        guard let field = textField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = (field.identifier?.rawValue ?? "0,0").split(separator: ",")
        let origin = CGPoint(x: CGFloat(Double(parts.first ?? "0") ?? 0),
                             y: CGFloat(Double(parts.last ?? "0") ?? 0))
        field.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)

        let usedStyle = pendingTextStyle ?? style
        pendingTextStyle = nil

        if let id = editingID {
            editingID = nil
            if text.isEmpty {
                document.remove(id: id)
            } else {
                document.updateText(id: id, string: text)
            }
            needsDisplay = true
            onChange?()
            return
        }

        guard !text.isEmpty else { return }
        let annotation: Annotation
        switch pendingTextKind {
        case .plain:
            annotation = Annotation(kind: .text(origin: origin, string: text),
                                    style: usedStyle, tool: .text)
        case .label:
            annotation = Annotation(kind: .labelText(origin: origin, string: text),
                                    style: usedStyle, tool: .labelText)
        }
        place(annotation)
        pendingTextKind = .plain
        needsDisplay = true
        onChange?()
    }

    // MARK: - 键盘

    public override func keyDown(with event: NSEvent) {
        // 文字输入中不抢键
        if textField != nil {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                onCommand?(event.modifierFlags.contains(.shift) ? .redo : .undo)
            case "c":
                onCommand?(.copy)
            case "p":
                onCommand?(.pin)
            case "d":
                onCommand?(.save)
            case "w":
                onCommand?(.cancel)
            default:
                super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case 53: // Esc：先取消选中，没有选中才退出
            if document.selection != nil {
                document.select(nil)
                needsDisplay = true
                onChange?()
            } else {
                onCommand?(.cancel)
            }
            return
        case 36, 76: // Return / Enter：Longshot 里回车即复制
            onCommand?(.copy)
            return
        case 51, 117: // Delete / Forward Delete
            if let selection = document.selection {
                document.remove(id: selection)
                needsDisplay = true
                onChange?()
            }
            return
        case 123, 124, 125, 126: // ← → ↓ ↑
            // Longshot: 方向键移动选中元素 1 个像素
            guard let id = document.selection,
                  let original = document.annotations.first(where: { $0.id == id }) else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 * pixelScale : pixelScale
            var moved = original
            switch event.keyCode {
            case 123: moved.offsetBy(dx: -step, dy: 0)
            case 124: moved.offsetBy(dx: step, dy: 0)
            case 125: moved.offsetBy(dx: 0, dy: step)
            default: moved.offsetBy(dx: 0, dy: -step)
            }
            document.replace(moved)
            needsDisplay = true
            return
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              let character = characters.first else {
            super.keyDown(with: event)
            return
        }

        // P = 贴到屏幕（Longshot 同款）
        if character == "p" {
            onCommand?(.pin)
            return
        }

        // 1…8 对应一条工具组；连按同一个键在组内轮换（Longshot: 连续按切换）
        if let group = AnnotateBarView.groups.first(where: { $0.first?.key == character }) {
            if let index = group.firstIndex(of: tool) {
                tool = group[(index + 1) % group.count]
            } else {
                tool = group.first ?? tool
            }
            onChange?()
            return
        }

        guard let match = AnnotateTool.allCases.first(where: { $0.key == character }) else {
            super.keyDown(with: event)
            return
        }
        tool = match
        onChange?()
    }

    public override func rightMouseDown(with event: NSEvent) {
        if document.selection != nil {
            document.select(nil)
            needsDisplay = true
            onChange?()
        } else {
            onCommand?(.cancel)
        }
    }

    /// 滚轮调绘制粗细。马赛克调颗粒大小，文字调字号。
    ///
    /// 长截图会被放进 NSScrollView 看全图，这时滚轮必须归滚动用——
    /// 否则用户滚半天只把线宽改了，看到的就是「长图只有一块、滚不动」。
    public override func scrollWheel(with event: NSEvent) {
        if enclosingScrollView != nil {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        let step = delta * 0.12
        switch tool {
        case .mosaic, .mosaicEllipse, .mosaicPencil:
            style.mosaicBlock = min(max(4, style.mosaicBlock + step * pixelScale), 80 * pixelScale)
        case .text, .labelText:
            style.fontSize = min(max(8, style.fontSize + step * pixelScale), 200 * pixelScale)
        case .counter:
            style.counterScale = min(max(0.4, style.counterScale + step * 0.02), 3)
        default:
            style.lineWidth = min(max(1, style.lineWidth + step * pixelScale), 40 * pixelScale)
        }
        if let id = document.selection { document.restyle(id: id, style: style) }
        needsDisplay = true
        onChange?()
    }
}

extension AnnotateDocument {
    // 撤销栈操作在模型里，画布只负责转发
}

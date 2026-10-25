import AppKit
import CoreGraphics

/// 标注画布。视图坐标 = 图片坐标 ÷ 缩放比，`isFlipped` 让两者同为左上原点。
@MainActor
public final class AnnotateCanvasView: NSView {
    /// 底图。调整选区时会换成新裁剪的图，所以不是 let。
    public var baseImage: CGImage {
        didSet { needsDisplay = true }
    }
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
    /// 按下时压着的图元：抬手前没拖动就是「单击选中」，拖起来则照常画新图元。
    private var pendingSelect: UUID?
    private var movingOriginal: Annotation?
    private var movingStart: CGPoint?
    private var resizingOriginal: Annotation?
    private var resizingHandle: SelectionHandle?
    private var editingID: UUID?
    private var textField: NSTextField?
    /// 悬停命中的图元；绘制中保持不动
    private(set) var hoveredID: UUID?

    // MARK: - 选区调整

    /// 选区本身可拖（只有原地标注模式下打开）。
    public var adjustableSelection = false
    /// 选区在屏幕全局坐标里的位置（左上原点，与 `CaptureSelection.globalRect` 同一套）。
    /// 宿主每次调整完都会同步回来，所以这里读到的永远是「当前真实选区」。
    public var selectionFrame: CGRect = .zero
    /// 选区能扩到的范围（屏幕全局坐标）。
    public var selectionLimit: CGRect = .zero
    /// 选区被拖动/键盘调整后的新值（全局坐标）。宿主负责改画布 frame、重裁底图、平移标注。
    public var onSelectionChange: ((CGRect) -> Void)?

    private var activeAnchor: SelectionAnchor?
    private var anchorDragStart: CGRect?

    /// 选中/悬停的高亮色，和 Longshot 的蓝色一致
    private static let accent = CGColor(srgbRed: 0.15, green: 0.51, blue: 0.96, alpha: 1)

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    private var currentCursor: NSCursor {
        if hoveredID != nil { return .openHand }
        if adjustableSelection, let anchor = hoveredAnchor() { return anchor.cursor }
        return tool == .text || tool == .labelText ? .iBeam : .crosshair
    }

    /// 鼠标现在压着哪个选区手柄。取当前光标位置反查，供光标形状用。
    private func hoveredAnchor() -> SelectionAnchor? {
        guard let window else { return nil }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return SelectionGeometry.anchor(at: convert(inWindow, from: nil),
                                        in: bounds, tolerance: SelectionChrome.reach)
    }

    private var hoveredAnnotation: Annotation? {
        guard let hoveredID else { return nil }
        return document.annotations.first { $0.id == hoveredID }
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
                              mosaicSource: baseImage)
        if let draft {
            AnnotateRenderer.draw(draft, in: context, imageSize: imageSize, mosaicSource: baseImage)
        }
        context.restoreGState()

        // 悬停：淡一点，告诉用户这里可以点
        if let hovered = hoveredAnnotation, hovered.id != document.selection {
            drawChrome(hovered, scale: scale, selected: false, context: context)
        }
        if let selected = document.selectedAnnotation {
            drawChrome(selected, scale: scale, selected: true, context: context)
            drawHandles(for: selected, scale: scale, context: context)
        }
    }

    /// 选中/悬停的辅助图形，画在视图坐标里（线宽不随截图倍率变粗）。
    ///
    /// 闭合形状用外扩一圈的轮廓，线类改用加宽的光晕：线类没有「内部」，
    /// 轮廓只能压在杆上，会把箭头本身的颜色染蓝。
    private func drawChrome(_ annotation: Annotation, scale: CGFloat,
                            selected: Bool, context: CGContext) {
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        let padding = annotation.style.lineWidth / 2 + 2
        guard let path = AnnotateRenderer.outlinePath(for: annotation, padding: padding)
            .copy(using: &transform) else { return }

        context.saveGState()
        context.setLineCap(.round)
        if annotation.isLineLike {
            context.setStrokeColor(Self.accent.copy(alpha: selected ? 0.26 : 0.20)!)
            context.setLineWidth(annotation.style.lineWidth * scale + (selected ? 5 : 8))
        } else {
            context.setStrokeColor(Self.accent.copy(alpha: selected ? 1 : 0.6)!)
            context.setLineWidth(1)
            if !selected { context.setLineDash(phase: 0, lengths: [4, 3]) }
        }
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// 选中手柄画在视图坐标里，尺寸才不会随 2x 截图放大。
    private func drawHandles(for annotation: Annotation, scale: CGFloat, context: CGContext) {
        for handle in annotation.editableHandles {
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

        // 选区手柄压在所有图元语义之上：它改的是「截哪块」，不是「画什么」
        if adjustableSelection,
           let anchor = SelectionGeometry.anchor(at: point, in: bounds, tolerance: SelectionChrome.reach) {
            activeAnchor = anchor
            anchorDragStart = selectionFrame
            return
        }

        // 图元手柄次之，而且不挑工具：选中之后随时都能拖控制点改几何
        if let selected = document.selectedAnnotation,
           let handle = handleHit(at: point, annotation: selected) {
            document.beginTransaction()
            resizingOriginal = selected
            resizingHandle = handle
            return
        }

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
            draft = nil
            // 压在已有图元上时先不落笔：抬手算单击选中，拖起来才算画新的。
            // 已经选中的那个例外——直接进入整体拖动。
            if let id = document.hitTest(imagePoint, tolerance: 6 * pixelScale) {
                if id == document.selection {
                    document.beginTransaction()
                    movingOriginal = document.annotations.first { $0.id == id }
                    movingStart = imagePoint
                    dragStart = nil
                    return
                }
                pendingSelect = id
            } else if document.selection != nil {
                document.select(nil)
                onChange?()
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let imagePoint = imagePoint(point)

        if let anchor = activeAnchor, let start = anchorDragStart {
            let next = SelectionGeometry.resized(start, anchor: anchor,
                                                 to: selectionPoint(point),
                                                 limit: selectionLimit)
            if next != selectionFrame {
                selectionFrame = next
                onSelectionChange?(next)
            }
            return
        }

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

        if draft == nil {
            // 还压在手势判定的死区里：继续等，别把单击变成 0 尺寸图元
            if pendingSelect != nil,
               hypot(imagePoint.x - dragStart.x, imagePoint.y - dragStart.y) < 2 * pixelScale {
                return
            }
            if pendingSelect != nil {
                pendingSelect = nil
                document.select(nil)
                onChange?()
            }
            draft = makeAnnotation(from: dragStart, to: imagePoint,
                                   shift: event.modifierFlags.contains(.shift))
            needsDisplay = true
            return
        }

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
        if activeAnchor != nil {
            activeAnchor = nil
            anchorDragStart = nil
            return
        }

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

        if let draft {
            // 单击（无拖动）不留下 0 尺寸图元
            if draft.bounds.width > 2 || draft.bounds.height > 2 || tool.isFreehand {
                var finished = draft
                finished.tool = tool
                place(finished)
            }
        } else if let pendingSelect {
            // 按下→抬起没移动：这次点击是选中已有图元
            document.select(pendingSelect)
        }
        self.draft = nil
        dragStart = nil
        pendingSelect = nil
        needsDisplay = true
        onChange?()
    }

    // MARK: - 悬停

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 悬停反馈靠 mouseMoved，窗口默认不产生这个事件
        window?.acceptsMouseMovedEvents = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        guard dragStart == nil, movingOriginal == nil, resizingOriginal == nil,
              activeAnchor == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        // 压着选区手柄时不做图元悬停：两个高亮同时出现会分不清在拖哪个
        if adjustableSelection, SelectionGeometry.anchor(at: point, in: bounds, tolerance: SelectionChrome.reach) != nil {
            setHovered(nil)
            currentCursor.set()
            return
        }
        setHovered(document.hitTest(imagePoint(point), tolerance: 6 * pixelScale))
        currentCursor.set()
    }

    public override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ id: UUID?) {
        guard id != hoveredID else { return }
        hoveredID = id
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - 选区调整

    /// 画布点 → 屏幕全局坐标。画布左上角与选区左上角重合，只差一个原点。
    private func selectionPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: selectionFrame.minX + point.x, y: selectionFrame.minY + point.y)
    }

    private func applySelectionChange(_ next: CGRect) {
        guard next != selectionFrame else { return }
        selectionFrame = next
        onSelectionChange?(next)
    }

    /// 方向键：有选中图元时移图元，否则移/扩缩选区。
    ///
    /// Longshot 的语义是「选中了元素就动元素，没选中就动捕获区域」，
    /// 这里保持一致；两者互斥，不需要额外的模式。
    private func handleArrow(keyCode: UInt16, command: Bool, shift: Bool) {
        let dx: CGFloat
        let dy: CGFloat
        switch keyCode {
        case 123: dx = -1; dy = 0
        case 124: dx = 1; dy = 0
        case 125: dx = 0; dy = 1
        default:  dx = 0; dy = -1
        }

        if let id = document.selection,
           let original = document.annotations.first(where: { $0.id == id }) {
            // ⌘ 留给选区扩缩，不参与图元移动
            guard !command else { return }
            let step: CGFloat = shift ? 10 * pixelScale : pixelScale
            var moved = original
            moved.offsetBy(dx: dx * step, dy: dy * step)
            document.replace(moved)
            needsDisplay = true
            return
        }

        guard adjustableSelection else { return }
        if let edge = SelectionGeometry.edge(forKeyCode: keyCode, command: command, shift: shift) {
            // ⌘ 外扩、⇧ 收缩，每次 1pt
            applySelectionChange(SelectionGeometry.inset(selectionFrame, edge: edge,
                                                          by: command ? 1 : -1,
                                                          limit: selectionLimit))
        } else if !command && !shift {
            applySelectionChange(SelectionGeometry.moved(selectionFrame, dx: dx, dy: dy,
                                                          limit: selectionLimit))
        }
    }

    /// 落一个新图元。
    ///
    /// 绘制工具下落笔不自动选中：刚画完还挂着选中框，等于每个图元都拖一条尾巴。
    /// 想改它，鼠标移上去（有悬停反馈）单击即可。
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
        for handle in annotation.editableHandles {
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

        // 方向键的 ⌘ / ⇧ 有独立语义（扩缩选区），必须在 command 分支之前截走，
        // 否则 ⌘← 会被当成未知命令丢给 super。
        if [123, 124, 125, 126].contains(event.keyCode) {
            handleArrow(keyCode: event.keyCode,
                        command: event.modifierFlags.contains(.command),
                        shift: event.modifierFlags.contains(.shift))
            return
        }

        // ⌥Q 走 keyCode：Option 会把字符改成特殊符号，靠 characters 认不出来
        if event.modifierFlags.contains(.option), event.keyCode == 12 { // Q
            onCommand?(.qr)
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
            case "r":
                // ⌘R：识别并复制，不弹面板
                onCommand?(.ocr(silent: true))
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
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              let character = characters.first else {
            super.keyDown(with: event)
            return
        }

        // 无修饰单键：贴图 / 打开 / 隔空投送 / 识别（Longshot 同款）
        switch character {
        case "p": onCommand?(.pin); return
        case "o": onCommand?(.open); return
        case "a": onCommand?(.airDrop); return
        case "r": onCommand?(.ocr(silent: false)); return
        default: break
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

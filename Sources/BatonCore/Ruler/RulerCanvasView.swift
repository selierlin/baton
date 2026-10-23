import AppKit
import CoreGraphics

/// 尺子画布：铺在冻结帧上面，负责测量、辅助线和取色。
///
/// 坐标系：视图是翻转的（左上原点），和图片像素同向，
/// 所以「视图点 × 倍率」就是像素，不需要再翻一次 y。
/// 测量方式。数字键 1–4 切换，和标注页的键位习惯保持一致。
enum RulerMode: Int, CaseIterable {
    case box = 1
    case horizontal = 2
    case vertical = 3
    case angle = 4

    var title: String {
        switch self {
        case .box: return "框选"
        case .horizontal: return "水平"
        case .vertical: return "垂直"
        case .angle: return "角度"
        }
    }

    var hint: String {
        switch self {
        case .box: return "拖动量宽高"
        case .horizontal: return "拖动量水平距离"
        case .vertical: return "拖动量垂直距离"
        case .angle: return "依次点 3 下：起点 → 顶点 → 终点"
        }
    }
}

@MainActor
final class RulerCanvasView: NSView {
    private struct Guide {
        /// true = 竖线（按 x 定位），false = 横线（按 y 定位）
        let vertical: Bool
        /// 视图坐标
        let position: CGFloat
    }

    /// 结束回调：`true` 表示正常退出，`false` 表示取消（Esc）。
    var onFinish: ((Bool) -> Void)?
    /// 「按这块区域去标注」：给出裁好的图和它的倍率。
    var onCapture: ((CGImage, CGSize) -> Void)?

    private let image: CGImage

    private var cursor: CGPoint?
    private var anchor: CGPoint?
    private var current: CGPoint?
    private var isDragging = false
    private var measureRect: CGRect?
    /// 单轴测量：两端点（视图坐标）。
    private var measureLine: (a: CGPoint, b: CGPoint)?
    /// 角度测量：起点、顶点、终点（视图坐标）。
    private var measureAngle: (a: CGPoint, vertex: CGPoint, b: CGPoint)?
    /// 角度测量正在收集的点（点满 3 个才成一次测量）。
    private var angleDraft: [CGPoint] = []
    private var guides: [Guide] = []

    private var settings: RulerSettings
    private(set) var mode: RulerMode = .box

    /// 撤销栈：存整份快照。辅助线和测量框都很少，比逐动作记增量省心。
    private struct Snapshot {
        let guides: [Guide]
        let measure: CGRect?
        let line: (a: CGPoint, b: CGPoint)?
        let angle: (a: CGPoint, vertex: CGPoint, b: CGPoint)?
    }

    private var history: [Snapshot] = []

    private var toastText: String?
    private var toastToken = 0

    /// 取色缓存：同一像素不重复建 context
    private var cachedPixel: CGPoint = CGPoint(x: -1, y: -1)
    private var cachedColor: (srgb: (UInt8, UInt8, UInt8), native: (UInt8, UInt8, UInt8))?

    private let loupeRadius: CGFloat = 52

    init(image: CGImage, settings: RulerSettings = RulerSettings()) {
        self.image = image
        self.settings = settings
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 设置页改了单位/线色/线宽：还开着的尺子立刻换，不用退出去重开。
    func apply(_ settings: RulerSettings) {
        self.settings = settings
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 图片像素 ÷ 视图点
    private var scale: CGSize {
        CGSize(width: CGFloat(image.width) / max(bounds.width, 1),
               height: CGFloat(image.height) / max(bounds.height, 1))
    }

    private var imageBounds: CGRect {
        CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    // MARK: - 事件

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseEntered(with event: NSEvent) {
        // 多屏时键盘跟着鼠标走：哪块屏有指针，哪块屏接键
        focusWindow()
    }

    override func mouseMoved(with event: NSEvent) {
        focusWindow()
        cursor = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        cursor = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        focusWindow()
        let point = convert(event.locationInWindow, from: nil)
        cursor = point

        if mode == .angle {
            // 三点定角：A（起点）→ V（顶点）→ B（终点）。点满才算一次测量，
            // 中途按 Delete 可以退一个点。
            angleDraft.append(point)
            if angleDraft.count == 3 {
                record()
                measureAngle = (angleDraft[0], angleDraft[1], angleDraft[2])
                angleDraft.removeAll()
            }
            needsDisplay = true
            return
        }

        anchor = point
        current = point
        isDragging = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode != .angle, let anchor else { return }
        var point = convert(event.locationInWindow, from: nil)
        if mode == .horizontal || mode == .vertical {
            point = RulerMetrics.axisLocked(anchor: anchor, point: point,
                                            horizontal: mode == .horizontal)
        } else if event.modifierFlags.contains(.shift) {
            point = RulerMetrics.squareLocked(anchor: anchor, point: point)
        }
        current = point
        isDragging = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            anchor = nil
            current = nil
            isDragging = false
            needsDisplay = true
        }

        guard mode != .angle else { return }

        var point = convert(event.locationInWindow, from: nil)
        if mode == .horizontal || mode == .vertical, let anchor {
            point = RulerMetrics.axisLocked(anchor: anchor, point: point,
                                            horizontal: mode == .horizontal)
        }
        if isDragging, let anchor {
            // 单轴模式：只记线段，不进矩形那条路
            if mode != .box {
                let length = mode == .horizontal
                    ? abs(point.x - anchor.x) * scale.width
                    : abs(point.y - anchor.y) * scale.height
                guard length >= 1 else { return }
                record()
                measureLine = (anchor, point)
                measureRect = nil
                measureAngle = nil
                return
            }
            var rect = RulerMetrics.rect(from: anchor, to: point)
            guard rect.width >= 2, rect.height >= 2 else { return }
            // ⌥ 松手：把四条边各自贴到附近对比最强的像素边界上
            if settings.snapEnabled, event.modifierFlags.contains(.option) {
                let before = RulerMetrics.pixelRect(rect, scale: scale)
                let snapped = RulerSnap.snap(before, in: image)
                if snapped == before {
                    toast("附近没有可吸附的边缘")
                } else {
                    rect = CGRect(x: snapped.minX / scale.width,
                                  y: snapped.minY / scale.height,
                                  width: snapped.width / scale.width,
                                  height: snapped.height / scale.height)
                    toast("已吸附边缘")
                }
            }
            record()
            measureRect = rect
            measureLine = nil
            measureAngle = nil
            return
        }

        // 没拖动就是取样：把颜色写进剪贴板，尺子留着继续量
        if let sample = sampleColor(at: point) {
            let text = RulerMetrics.colorText(red: sample.srgb.0, green: sample.srgb.1,
                                              blue: sample.srgb.2, format: settings.colorFormat)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            toast("已复制 \(text)")
        }
    }

    override func keyDown(with event: NSEvent) {
        // ⌘Z 先判，别让后面的分支把带修饰键的按键当成普通字母
        if event.modifierFlags.contains(.command) {
            if event.keyCode == 6 {  // ⌘Z
                undo()
                return
            }
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 18, 19, 20, 21:  // 1 / 2 / 3 / 4
            let raw = event.keyCode - 17
            guard let next = RulerMode(rawValue: Int(raw)) else { return }
            if next != mode {
                mode = next
                angleDraft.removeAll()
                toast("测量方式：\(next.title) · \(next.hint)")
            }
        case 53:  // Esc
            onFinish?(false)
        case 36, 76:  // Return / 小键盘 Enter：按当前测量框去标注
            captureMeasuredArea()
        case 4, 9:  // H / V（按物理键位，不受键盘布局影响）
            if let cursor {
                let vertical = event.keyCode == 9
                record()
                guides.append(Guide(vertical: vertical,
                                    position: vertical ? cursor.x : cursor.y))
                needsDisplay = true
            }
        case 51, 117:  // Delete / Forward Delete
            if !angleDraft.isEmpty {
                angleDraft.removeLast()
                needsDisplay = true
            } else if measureAngle != nil || measureLine != nil {
                record()
                measureAngle = nil
                measureLine = nil
                needsDisplay = true
            } else if !guides.isEmpty {
                record()
                guides.removeLast()
                needsDisplay = true
            } else if measureRect != nil {
                record()
                measureRect = nil
                needsDisplay = true
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - 撤销

    private func record() {
        history.append(Snapshot(guides: guides, measure: measureRect,
                                line: measureLine, angle: measureAngle))
        if history.count > 64 { history.removeFirst() }
    }

    private func undo() {
        guard let snapshot = history.popLast() else { return }
        guides = snapshot.guides
        measureRect = snapshot.measure
        measureLine = snapshot.line
        measureAngle = snapshot.angle
        needsDisplay = true
    }

    /// 把测量框当成新的选区交出去（裁好图，连倍率一起给）。
    private func captureMeasuredArea() {
        guard mode == .box else {
            toast("当前是\(mode.title)测量，按 1 切回框选再截取")
            return
        }
        guard let rect = measureRect else { return }
        let pixelRect = RulerMetrics.pixelRect(rect, scale: scale).intersection(imageBounds)
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let crop = image.cropping(to: pixelRect) else { return }
        onCapture?(crop, scale)
    }

    override func flagsChanged(with event: NSEvent) {
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        needsDisplay = true

        let menu = NSMenu()
        if let rect = measureRect {
            let size = RulerMetrics.sizeText(width: Int(rect.width * scale.width.rounded()),
                                             height: Int(rect.height * scale.height.rounded()),
                                             scale: scale)
            menu.addItem(item(title: "复制尺寸  \(size)", action: #selector(copySize)))
            menu.addItem(item(title: "按此区域标注 (↩)", action: #selector(captureAreaForAnnotate)))
            menu.addItem(item(title: "复制测量区域截图", action: #selector(copyArea)))
            menu.addItem(.separator())
        }
        menu.addItem(item(title: "撤销 (⌘Z)", action: #selector(undoAction)))
        menu.addItem(item(title: "清空绘制", action: #selector(clearAll)))
        menu.addItem(.separator())
        menu.addItem(item(title: "退出尺子", action: #selector(exitRuler)))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func focusWindow() {
        guard let window else { return }
        if !window.isKeyWindow {
            window.makeKey()
        }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }

    // MARK: - 菜单动作

    @objc private func copySize() {
        guard let rect = measureRect else { return }
        let width = Int((rect.width * scale.width).rounded())
        let height = Int((rect.height * scale.height).rounded())
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(width) × \(height)", forType: .string)
        toast("已复制 \(width) × \(height)")
    }

    @objc private func copyArea() {
        guard let rect = measureRect else { return }
        let pixelRect = RulerMetrics.pixelRect(rect, scale: scale).intersection(imageBounds)
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let crop = image.cropping(to: pixelRect) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: crop, size: .zero)])
        toast("已复制 \(Int(pixelRect.width)) × \(Int(pixelRect.height)) 截图")
    }

    @objc private func captureAreaForAnnotate() {
        captureMeasuredArea()
    }

    @objc private func undoAction() {
        undo()
    }

    @objc private func clearAll() {
        record()
        measureRect = nil
        guides.removeAll()
        needsDisplay = true
    }

    @objc private func exitRuler() {
        onFinish?(true)
    }

    private func toast(_ text: String) {
        toastText = text
        toastToken &+= 1
        let token = toastToken
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.toastText = nil
            self.needsDisplay = true
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawGuides(context)
        drawMeasurement(context)
        drawCursorCrosshair(context)
        drawLoupe(context)
        drawHint()
        drawToast()
    }

    private func drawGuides(_ context: CGContext) {
        guard !guides.isEmpty else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1)
        for guide in guides {
            context.beginPath()
            if guide.vertical {
                context.move(to: CGPoint(x: guide.position.rounded() + 0.5, y: 0))
                context.addLine(to: CGPoint(x: guide.position.rounded() + 0.5, y: bounds.height))
            } else {
                context.move(to: CGPoint(x: 0, y: guide.position.rounded() + 0.5))
                context.addLine(to: CGPoint(x: bounds.width, y: guide.position.rounded() + 0.5))
            }
            context.strokePath()
        }
        context.restoreGState()

        // 每条线末端标位置，方便对齐到具体像素
        for guide in guides {
            let value = Int((guide.vertical ? guide.position * scale.width
                                            : guide.position * scale.height).rounded())
            let text = guide.vertical ? "x = \(value)" : "y = \(value)"
            let box = badgeSize(text)
            var origin = guide.vertical
                ? CGPoint(x: guide.position + 6, y: 8)
                : CGPoint(x: 8, y: guide.position + 4)
            origin.x = min(max(4, origin.x), max(4, bounds.width - box.width - 4))
            origin.y = min(max(4, origin.y), max(4, bounds.height - box.height - 4))
            drawBadge(text, origin: origin)
        }

        drawGuideGaps()
    }

    /// 同方向最近两条线的间距：这才是「拉两条线量间距」的用法。
    private func drawGuideGaps() {
        for vertical in [false, true] {
            let same = guides.filter { $0.vertical == vertical }
            guard same.count >= 2 else { continue }
            let a = same[same.count - 2].position
            let b = same[same.count - 1].position
            let gap = abs(b - a)
            guard gap >= 1 else { continue }

            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            // 横线的间距是竖直距离，所以量尺要竖着画（竖线反之），别画反
            var origin: CGPoint
            if vertical {
                let y = bounds.height - 44
                path.move(to: CGPoint(x: a, y: y))
                path.line(to: CGPoint(x: b, y: y))
                path.move(to: CGPoint(x: a, y: y - 5))
                path.line(to: CGPoint(x: a, y: y + 5))
                path.move(to: CGPoint(x: b, y: y - 5))
                path.line(to: CGPoint(x: b, y: y + 5))
                origin = CGPoint(x: (a + b) / 2 - 30, y: y - 26)
            } else {
                let x = bounds.width - 44
                path.move(to: CGPoint(x: x, y: a))
                path.line(to: CGPoint(x: x, y: b))
                path.move(to: CGPoint(x: x - 5, y: a))
                path.line(to: CGPoint(x: x + 5, y: a))
                path.move(to: CGPoint(x: x - 5, y: b))
                path.line(to: CGPoint(x: x + 5, y: b))
                origin = CGPoint(x: x - 108, y: (a + b) / 2 - 10)
            }
            path.stroke()

            let pixels = gap * (vertical ? scale.width : scale.height)
            let text = RulerMetrics.lengthText(pixels: Double(pixels),
                                               pixelsPerPoint: Double(vertical ? scale.width : scale.height),
                                               unit: settings.unit)
            drawBadge("间距 \(text)", origin: origin)
        }
    }

    private func drawMeasurement(_ context: CGContext) {
        switch mode {
        case .box: drawBoxMeasurement(context)
        case .horizontal, .vertical: drawLineMeasurement(context)
        case .angle: drawAngleMeasurement(context)
        }
    }

    /// 测量线的颜色。辅助线仍走系统强调色，两者要能一眼分开。
    private var accentColor: NSColor {
        let c = settings.accent.components
        return NSColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green),
                       blue: CGFloat(c.blue), alpha: 1)
    }

    private func drawBoxMeasurement(_ context: CGContext) {
        let rect: CGRect?
        if let anchor, let current, isDragging {
            rect = RulerMetrics.rect(from: anchor, to: current)
        } else {
            rect = measureRect
        }
        guard let rect, rect.width >= 1, rect.height >= 1 else { return }

        context.saveGState()
        context.setStrokeColor(accentColor.cgColor)
        context.setLineWidth(CGFloat(settings.lineWidth))
        // 0.5 内缩让 1pt 描边压在像素网格上，不发虚
        context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        context.restoreGState()

        let width = Int((rect.width * scale.width).rounded())
        let height = Int((rect.height * scale.height).rounded())
        let text = RulerMetrics.sizeText(width: width, height: height,
                                         scale: scale, unit: settings.unit)
        let box = badgeSize(text)
        var origin = CGPoint(x: rect.minX, y: rect.minY - box.height - 6)
        if origin.y < 4 {
            origin.y = min(rect.maxY + 6, bounds.height - box.height - 4)
        }
        origin.x = min(max(4, origin.x), max(4, bounds.width - box.width - 4))
        drawBadge(text, origin: origin)
    }

    private func drawLineMeasurement(_ context: CGContext) {
        guard let (a, b) = currentLine() else { return }
        // 拖动中也要按模式锁轴，否则预览会跟着手歪
        let horizontal = mode == .horizontal
        let end = horizontal ? CGPoint(x: b.x, y: a.y) : CGPoint(x: a.x, y: b.y)

        context.saveGState()
        context.setStrokeColor(accentColor.cgColor)
        context.setLineWidth(CGFloat(settings.lineWidth))
        context.beginPath()
        context.move(to: a)
        context.addLine(to: end)
        // 两端画 8pt 竖/横刻度：单看一条线分不清量的是哪一段
        let tick: CGFloat = 4
        if horizontal {
            context.move(to: CGPoint(x: a.x, y: a.y - tick))
            context.addLine(to: CGPoint(x: a.x, y: a.y + tick))
            context.move(to: CGPoint(x: end.x, y: end.y - tick))
            context.addLine(to: CGPoint(x: end.x, y: end.y + tick))
        } else {
            context.move(to: CGPoint(x: a.x - tick, y: a.y))
            context.addLine(to: CGPoint(x: a.x + tick, y: a.y))
            context.move(to: CGPoint(x: end.x - tick, y: end.y))
            context.addLine(to: CGPoint(x: end.x + tick, y: end.y))
        }
        context.strokePath()
        context.restoreGState()

        let pixels = horizontal
            ? abs(end.x - a.x) * scale.width
            : abs(end.y - a.y) * scale.height
        let text = RulerMetrics.lengthText(pixels: Double(pixels),
                                           pixelsPerPoint: Double(horizontal ? scale.width : scale.height),
                                           unit: settings.unit)
        let box = badgeSize(text)
        var origin = horizontal
            ? CGPoint(x: (a.x + end.x) / 2 - box.width / 2, y: a.y - box.height - 8)
            : CGPoint(x: a.x + 10, y: (a.y + end.y) / 2 - box.height / 2)
        origin.x = min(max(4, origin.x), max(4, bounds.width - box.width - 4))
        origin.y = min(max(4, origin.y), max(4, bounds.height - box.height - 4))
        drawBadge(text, origin: origin)
    }

    /// 正在拖的那条线，或者已经落定的那条。
    private func currentLine() -> (CGPoint, CGPoint)? {
        if let anchor, let current, isDragging { return (anchor, current) }
        if let measureLine { return (measureLine.a, measureLine.b) }
        return nil
    }

    private func drawAngleMeasurement(_ context: CGContext) {
        if let angle = measureAngle {
            drawAngle(context, a: angle.a, vertex: angle.vertex, b: angle.b)
        }

        // 收集中的点：画小圆点 + 已确定的连线，让用户知道还差几下游标
        guard !angleDraft.isEmpty else { return }
        context.saveGState()
        context.setStrokeColor(accentColor.withAlphaComponent(0.75).cgColor)
        context.setLineWidth(CGFloat(settings.lineWidth))
        if angleDraft.count >= 2 {
            context.beginPath()
            context.move(to: angleDraft[0])
            context.addLine(to: angleDraft[1])
            context.strokePath()
        }
        if let cursor, let last = angleDraft.last {
            context.beginPath()
            context.setLineDash(phase: 0, lengths: [5, 4])
            context.move(to: last)
            context.addLine(to: cursor)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }
        for point in angleDraft {
            context.setFillColor(accentColor.cgColor)
            context.fillEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
        }
        context.restoreGState()
    }

    private func drawAngle(_ context: CGContext, a: CGPoint, vertex: CGPoint, b: CGPoint) {
        context.saveGState()
        context.setStrokeColor(accentColor.cgColor)
        context.setLineWidth(CGFloat(settings.lineWidth))
        context.beginPath()
        context.move(to: vertex)
        context.addLine(to: a)
        context.move(to: vertex)
        context.addLine(to: b)
        context.strokePath()

        // 弧：从 A 方向扫到 B 方向，取小于 180° 的那一侧（与读数一致）。
        let radius: CGFloat = 26
        let start = atan2(a.y - vertex.y, a.x - vertex.x)
        let end = atan2(b.y - vertex.y, b.x - vertex.x)
        var sweep = end - start
        while sweep > .pi { sweep -= 2 * .pi }
        while sweep < -.pi { sweep += 2 * .pi }
        let steps = 24
        context.beginPath()
        for index in 0...steps {
            let angle = start + sweep * CGFloat(index) / CGFloat(steps)
            let point = CGPoint(x: vertex.x + cos(angle) * radius,
                                y: vertex.y + sin(angle) * radius)
            index == 0 ? context.move(to: point) : context.addLine(to: point)
        }
        context.strokePath()
        context.restoreGState()

        let degrees = RulerMetrics.degrees(from: a, vertex: vertex, to: b)
        let text = RulerMetrics.angleText(degrees)
        let box = badgeSize(text)
        // 沿角平分线放，正好落在弧外面
        let middle = CGPoint(x: vertex.x + cos(start + sweep / 2) * (radius + 20),
                             y: vertex.y + sin(start + sweep / 2) * (radius + 20))
        var origin = CGPoint(x: middle.x - box.width / 2, y: middle.y - box.height / 2)
        origin.x = min(max(4, origin.x), max(4, bounds.width - box.width - 4))
        origin.y = min(max(4, origin.y), max(4, bounds.height - box.height - 4))
        drawBadge(text, origin: origin)
    }

    private func drawCursorCrosshair(_ context: CGContext) {
        guard let cursor, !isDragging else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.beginPath()
        context.move(to: CGPoint(x: 0, y: cursor.y.rounded() + 0.5))
        context.addLine(to: CGPoint(x: bounds.width, y: cursor.y.rounded() + 0.5))
        context.move(to: CGPoint(x: cursor.x.rounded() + 0.5, y: 0))
        context.addLine(to: CGPoint(x: cursor.x.rounded() + 0.5, y: bounds.height))
        context.strokePath()
        context.restoreGState()
    }

    /// 放大镜：光标周围 13×13 像素放到 104pt 圆里，边缘仍然对齐。
    private func drawLoupe(_ context: CGContext) {
        guard let cursor, !isDragging else { return }

        let side: CGFloat = 13
        var center = CGPoint(x: cursor.x + loupeRadius + 22, y: cursor.y + loupeRadius + 22)
        if center.x + loupeRadius > bounds.width - 8 { center.x = cursor.x - loupeRadius - 22 }
        if center.y + loupeRadius > bounds.height - 8 { center.y = cursor.y - loupeRadius - 22 }
        center.x = min(max(loupeRadius + 8, center.x), bounds.width - loupeRadius - 8)
        center.y = min(max(loupeRadius + 8, center.y), bounds.height - loupeRadius - 8)

        let circle = CGRect(x: center.x - loupeRadius, y: center.y - loupeRadius,
                            width: loupeRadius * 2, height: loupeRadius * 2)
        let pixelPoint = RulerMetrics.pixelPoint(cursor, scale: scale)
        let sourceRect = CGRect(x: pixelPoint.x - side / 2, y: pixelPoint.y - side / 2,
                                width: side, height: side)
        let clipped = sourceRect.intersection(imageBounds)

        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        NSColor(white: 0.08, alpha: 1).setFill()
        context.fill(circle)
        if !clipped.isEmpty, let crop = image.cropping(to: clipped.integral) {
            let factor = circle.width / side
            let destination = CGRect(x: circle.minX + (clipped.minX - sourceRect.minX) * factor,
                                     y: circle.minY + (clipped.minY - sourceRect.minY) * factor,
                                     width: clipped.width * factor,
                                     height: clipped.height * factor)
            context.interpolationQuality = .none
            AnnotateRenderer.drawImage(crop, in: destination, context: context)
        }
        context.restoreGState()

        // 圆环 + 中心定位点
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 2
        ring.stroke()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        let inner = NSBezierPath(ovalIn: circle.insetBy(dx: 2.5, dy: 2.5))
        inner.lineWidth = 1
        inner.stroke()

        let marker = NSBezierPath()
        marker.move(to: CGPoint(x: center.x - 4, y: center.y))
        marker.line(to: CGPoint(x: center.x + 4, y: center.y))
        marker.move(to: CGPoint(x: center.x, y: center.y - 4))
        marker.line(to: CGPoint(x: center.x, y: center.y + 4))
        marker.lineWidth = 1
        NSColor.white.setStroke()
        marker.stroke()
        NSColor.black.setStroke()
        marker.lineWidth = 2
        marker.stroke()

        guard let sample = sampleColor(at: cursor) else { return }
        // ⌥ 看的是原始色彩空间（P3 屏上的真实值），默认给 sRGB
        let raw = NSEvent.modifierFlags.contains(.option)
        let native = sample.native
        let text = raw
            ? "\(RulerMetrics.colorText(red: native.0, green: native.1, blue: native.2, format: settings.colorFormat))  P3 原值"
            : RulerMetrics.colorText(red: sample.srgb.0, green: sample.srgb.1,
                                     blue: sample.srgb.2, format: settings.colorFormat)
        let box = badgeSize(text)
        var origin = CGPoint(x: center.x - box.width / 2, y: circle.maxY + 6)
        if origin.y + box.height > bounds.height - 4 {
            origin.y = circle.minY - box.height - 6
        }
        origin.x = min(max(4, origin.x), max(4, bounds.width - box.width - 4))
        drawBadge(text, origin: origin)
    }

    private func drawHint() {
        let snap = settings.snapEnabled ? "⌥ 吸边缘" : "吸附已关"
        let text = "\(mode.title)：\(mode.hint) · 1–4 切模式 · \(snap) · 点击取色 · H/V 辅助线 · ↩ 标注 · Esc 退出"
        let box = badgeSize(text)
        let origin = CGPoint(x: (bounds.width - box.width) / 2, y: bounds.height - box.height - 24)
        drawBadge(text, origin: origin, alpha: 0.55)
    }

    private func drawToast() {
        guard let toastText else { return }
        let box = badgeSize(toastText)
        // 贴着底部提示条上方：视图是翻转的，y 越大越靠下
        let origin = CGPoint(x: (bounds.width - box.width) / 2,
                             y: bounds.height - box.height - 56)
        drawBadge(toastText, origin: origin)
    }

    // MARK: - 文本与徽标

    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    private func badgeSize(_ text: String) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: Self.badgeFont])
        return CGSize(width: (size.width + 12).rounded(.up), height: 20)
    }

    @discardableResult
    private func drawBadge(_ text: String, origin: CGPoint, alpha: CGFloat = 0.82) -> CGRect {
        let size = badgeSize(text)
        let rect = CGRect(x: origin.x.rounded(), y: origin.y.rounded(),
                          width: size.width, height: size.height)
        NSColor(white: 0.1, alpha: alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.badgeFont,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6,
                                            y: rect.midY - textSize.height / 2),
                                withAttributes: attributes)
        return rect
    }

    // MARK: - 取色

    private func sampleColor(at point: CGPoint) -> (srgb: (UInt8, UInt8, UInt8), native: (UInt8, UInt8, UInt8))? {
        let pixel = RulerMetrics.pixelPoint(point, scale: scale)
        let x = Int(pixel.x.rounded(.down))
        let y = Int(pixel.y.rounded(.down))
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }

        let key = CGPoint(x: x, y: y)
        if key == cachedPixel, let cachedColor {
            return cachedColor
        }

        guard let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let srgb = Self.rgb(crop, space: CGColorSpace(name: CGColorSpace.sRGB)),
              let native = Self.rgb(crop, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB())
        else { return nil }

        let value = (srgb: srgb, native: native)
        cachedPixel = key
        cachedColor = value
        return value
    }

    /// 把 1×1 的像素画进指定色彩空间的 context，读回来就是该空间下的字节。
    private static func rgb(_ image: CGImage, space: CGColorSpace?) -> (UInt8, UInt8, UInt8)? {
        guard let space else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let ok = pixel.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: 1,
                                          height: 1,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return nil }
        return (pixel[0], pixel[1], pixel[2])
    }
}

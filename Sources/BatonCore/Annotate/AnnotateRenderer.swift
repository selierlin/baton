import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// 标注绘制。绘制坐标系约定为**左上原点、y 向下**，和模型一致；
/// 调用方负责把上下文翻好（画布视图和 flatten 都这么做）。
public enum AnnotateRenderer {
    // MARK: - 尺寸

    public static func font(style: AnnotateStyle) -> CTFont {
        CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)
    }

    public static func textSize(_ string: String, style: AnnotateStyle) -> CGSize {
        guard !string.isEmpty else { return .zero }
        let line = CTLineCreateWithAttributedString(attributed(string, style: style))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        return CGSize(width: ceil(bounds.width) + style.lineWidth,
                      height: ceil(bounds.height) + style.lineWidth)
    }

    public static func counterRadius(style: AnnotateStyle) -> CGFloat {
        max(style.fontSize * 0.75, style.lineWidth * 3) * max(style.counterScale, 0.2)
    }

    private static func attributed(_ string: String, style: AnnotateStyle) -> NSAttributedString {
        let color = style.color.cgColor.copy(alpha: style.color.alpha * style.opacity) ?? style.color.cgColor
        return NSAttributedString(string: string, attributes: [
            .font: font(style: style),
            .foregroundColor: color,
        ])
    }

    /// 轮廓在给定 y 上的半宽。profile 按 y 递增排好，段内线性插值。
    private static func interpolate(_ profile: [(CGFloat, CGFloat)], at y: CGFloat) -> CGFloat {
        guard let first = profile.first, let last = profile.last else { return 0 }
        if y <= first.1 { return first.0 }
        if y >= last.1 { return last.0 }
        for index in 1..<profile.count where profile[index].1 >= y {
            let (x0, y0) = profile[index - 1]
            let (x1, y1) = profile[index]
            let span = y1 - y0
            guard span > 0 else { return x1 }
            return x0 + (x1 - x0) * (y - y0) / span
        }
        return last.0
    }

    // MARK: - 绘制

    /// - Parameters:
    ///   - context: 已翻成 y 向下的上下文
    ///   - imageSize: 底图像素尺寸，用于裁剪越界图元
    ///   - mosaicSource: 马赛克取像素的底图，nil 时该图元跳过
    public static func draw(_ annotations: [Annotation],
                            in context: CGContext,
                            imageSize: CGSize,
                            mosaicSource: CGImage?) {
        for annotation in annotations {
            draw(annotation, in: context, imageSize: imageSize, mosaicSource: mosaicSource)
        }
    }

    public static func draw(_ annotation: Annotation,
                            in context: CGContext,
                            imageSize: CGSize,
                            mosaicSource: CGImage?) {
        context.saveGState()
        defer { context.restoreGState() }

        context.setAlpha(annotation.style.opacity)
        context.setStrokeColor(annotation.style.color.cgColor)
        context.setFillColor(annotation.style.color.cgColor)
        context.setLineWidth(annotation.style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.kind {
        case .line(let start, let end):
            applyLinePattern(context, style: annotation.style)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])

        case .arrow(let start, let end, let sinkTail):
            drawArrow(context, start: start, end: end,
                      width: annotation.style.lineWidth, sinkTail: sinkTail,
                      dashed: annotation.style.linePattern == .dashed)

        case .rectangle(let rect):
            drawShape(context, rect: rect, ellipse: false, style: annotation.style)

        case .ellipse(let rect):
            drawShape(context, rect: rect, ellipse: true, style: annotation.style)

        case .stroke(let points):
            guard let first = points.first else { break }
            // 记号笔的「直角」笔头：线帽改成方形
            context.setLineCap(annotation.style.markerCap == .square ? .square : .round)
            context.move(to: first)
            if points.count == 1 {
                // 单击也留一个点，否则画笔点一下没有任何反馈
                context.addLine(to: CGPoint(x: first.x + 0.1, y: first.y))
            } else {
                for point in points.dropFirst() { context.addLine(to: point) }
            }
            context.strokePath()

        case .mosaic(let rect):
            if let mosaicSource {
                drawMosaic(context, rect: rect, block: annotation.style.mosaicBlock,
                           pattern: annotation.style.mosaicPattern,
                           cornerRadius: annotation.style.cornerRadius,
                           source: mosaicSource, imageSize: imageSize)
            }

        case .mosaicEllipse(let rect):
            if let mosaicSource {
                drawMosaic(context, rect: rect, block: annotation.style.mosaicBlock,
                           pattern: annotation.style.mosaicPattern,
                           cornerRadius: annotation.style.cornerRadius,
                           source: mosaicSource, imageSize: imageSize, ellipse: true)
            }

        case .mosaicStroke(let points):
            if let mosaicSource {
                drawMosaicStroke(context, points: points, block: annotation.style.mosaicBlock,
                                 pattern: annotation.style.mosaicPattern,
                                 width: max(annotation.style.lineWidth * 5, 24),
                                 source: mosaicSource, imageSize: imageSize)
            }

        case .highlight(let rect, let ellipse):
            // 半透明色块，压住文字也还看得清底下的字
            context.saveGState()
            context.setAlpha(annotation.style.opacity)
            context.setFillColor(annotation.style.color.cgColor)
            let path: CGPath = ellipse
                ? CGPath(ellipseIn: rect, transform: nil)
                : CGPath(roundedRect: rect,
                         cornerWidth: min(annotation.style.cornerRadius, rect.width / 2),
                         cornerHeight: min(annotation.style.cornerRadius, rect.height / 2),
                         transform: nil)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()

        case .text(let origin, let string):
            drawText(context, string: string, origin: origin, style: annotation.style)

        case .labelText(let origin, let string):
            drawLabelText(context, string: string, origin: origin, style: annotation.style)

        case .counter(let center, let number):
            drawCounter(context, center: center, number: number, style: annotation.style)

        case .length(let start, let end):
            drawMeasureLine(context, start: start, end: end, style: annotation.style,
                            distance: hypot(end.x - start.x, end.y - start.y))

        case .area(let rect):
            drawMeasureArea(context, rect: rect, style: annotation.style)

        case .ruler(let start, let end):
            drawRuler(context, start: start, end: end, style: annotation.style)
        }
    }

    /// 选中/悬停轮廓：贴着图元自己的几何走，而不是外接矩形。
    ///
    /// 箭头、直线这类斜向图元如果用外接矩形，斜线外面会多出一个四边形框，
    /// Longshot 只在图形本身和首尾两点上给反馈。
    /// - Parameter padding: 向外扩出的量（图片像素），让轮廓落在图形外面而不是压在身上
    public static func outlinePath(for annotation: Annotation, padding: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        switch annotation.kind {
        case .rectangle(let rect):
            let box = rect.insetBy(dx: -padding, dy: -padding)
            let radius = min(annotation.style.cornerRadius, min(rect.width, rect.height) / 2)
            path.addRoundedRect(in: box, cornerWidth: radius, cornerHeight: radius)
        case .ellipse(let rect), .mosaicEllipse(let rect):
            path.addEllipse(in: rect.insetBy(dx: -padding, dy: -padding))
        case .mosaic(let rect), .area(let rect):
            path.addRect(rect.insetBy(dx: -padding, dy: -padding))
        case .highlight(let rect, let ellipse):
            let box = rect.insetBy(dx: -padding, dy: -padding)
            if ellipse { path.addEllipse(in: box) } else { path.addRect(box) }
        case .line(let start, let end), .arrow(let start, let end, _),
             .ruler(let start, let end), .length(let start, let end):
            path.move(to: start)
            path.addLine(to: end)
        case .stroke(let points), .mosaicStroke(let points):
            guard let first = points.first else { break }
            path.move(to: first)
            if points.count > 1 {
                for point in points.dropFirst() { path.addLine(to: point) }
            } else {
                path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y))
            }
        case .text, .labelText, .counter:
            path.addRect(annotation.bounds.insetBy(dx: -padding, dy: -padding))
        }
        return path
    }

    /// 直线/箭头的虚线：间隔按线宽走，粗线也不会连成一坨。
    private static func applyLinePattern(_ context: CGContext, style: AnnotateStyle) {
        if style.linePattern == .dashed {
            context.setLineDash(phase: 0,
                                lengths: [style.lineWidth * 2.4, style.lineWidth * 1.8])
        } else {
            context.setLineDash(phase: 0, lengths: [])
        }
    }

    /// 矩形 / 椭圆。三种绘制样式：
    /// - outline：只描边
    /// - filled：实心填充
    /// - hatched：淡填充 + 45° 斜线，和 Longshot 的 drawBox 图标一致
    private static func drawShape(_ context: CGContext, rect: CGRect,
                                  ellipse: Bool, style: AnnotateStyle) {
        let radius = min(style.cornerRadius, min(rect.width, rect.height) / 2)
        let path: CGPath = ellipse
            ? CGPath(ellipseIn: rect, transform: nil)
            : CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        applyLinePattern(context, style: style)

        switch style.shapeDrawStyle {
        case .outline:
            context.addPath(path)
            context.strokePath()

        case .filled:
            context.saveGState()
            context.setAlpha(style.opacity * style.fillAlpha)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()

        case .hatched:
            // 底色淡一层，让斜线之外也有「区域」的观感
            context.saveGState()
            context.setAlpha(style.opacity * 0.18)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()

            context.saveGState()
            context.addPath(path)
            context.clip()
            let spacing = max(style.lineWidth * 2.2, 7)
            context.setLineWidth(max(style.lineWidth * 0.4, 1))
            var x = rect.minX - rect.height
            while x < rect.maxX + rect.height {
                context.move(to: CGPoint(x: x, y: rect.maxY))
                context.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += spacing
            }
            context.strokePath()
            context.restoreGState()

            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// Longshot 的两种箭头：
    /// - 平箭头（flatArrow）：等宽线杆 + 三角头，头底边是直的
    /// - 内凹箭头（sinkArrow）：等宽线换成「细 → 粗」的楔形杆，头底边再向内切一个 V 形口
    private static func drawArrow(_ context: CGContext, start: CGPoint, end: CGPoint,
                                  width: CGFloat, sinkTail: Bool, dashed: Bool = false) {
        if dashed {
            context.setLineDash(phase: 0, lengths: [width * 2.4, width * 1.8])
        } else {
            context.setLineDash(phase: 0, lengths: [])
        }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(sqrt(dx * dx + dy * dy), 0.001)
        let ux = dx / length
        let uy = dy / length
        let nx = -uy
        let ny = ux

        // 几何来自 Longshot 的 drawFlatArrowParam / drawSinkArrowParam：
        // lineThick 4pt、triangleAngle 45°、baseTriangleHeight 10pt、thicknessAngle 23°。
        // baseTriangleHeight 恰好是 lineThick 的 2.5 倍，所以按线宽等比缩放即可。
        let headLength = min(width * 2.5, length * 0.95)
        // triangleAngle 是「箭头中线到侧边」的半角（45°），所以半宽 = 头长 × tan45° = 头长，
        // 整个头的张角是 90°——和 Assets.car 里 sinkArrow 图标的比例一致（头宽约为线宽的 5 倍）。
        let half = headLength
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)

        // 线杆端口用平头，否则端点会从三角底边两侧支出来
        context.setLineCap(.butt)
        context.setLineJoin(.miter)

        if sinkTail {
            // 第三个变体（sinkArrow）：箭杆是「细 → 粗」的楔形，从尾端细口一路张到箭头，
            // 箭头底边再向内切一个 V 形口，杆从缺口里探进去，和两侧倒刺之间留一道细缝。
            // 杆最宽处不到头的一半：图标里杆宽约是头宽的 40%，再宽就成实心块了
            let bodyHalf = half * 0.45
            // 凹口深浅：按图标量出来约是头长的 1/3，比 tan(23°) 浅一点，倒刺才不会细成锯齿
            let notchDepth = half * 0.34
            let notch = CGPoint(x: base.x + ux * notchDepth, y: base.y + uy * notchDepth)

            // 尾部从一点墨开始，沿杆线性张开到靠头处最粗——就是 Longshot 那种
            // 「由细到粗」的锥形杆，尾端没有平头截面。
            // 楔形杆：尾尖 → 凹口两侧，一直伸进箭头里
            context.beginPath()
            context.move(to: start)
            context.addLine(to: CGPoint(x: notch.x + nx * bodyHalf, y: notch.y + ny * bodyHalf))
            context.addLine(to: CGPoint(x: notch.x - nx * bodyHalf, y: notch.y - ny * bodyHalf))
            context.closePath()
            context.fillPath()

            // 箭头：底边中间向内切一个 V 形口，口子比杆宽，杆和两侧倒刺之间才会留出细缝
            context.beginPath()
            context.move(to: end)
            context.addLine(to: CGPoint(x: base.x + nx * half, y: base.y + ny * half))
            context.addLine(to: notch)
            context.addLine(to: CGPoint(x: base.x - nx * half, y: base.y - ny * half))
            context.closePath()
            context.fillPath()
        } else {
            context.beginPath()
            context.move(to: end)
            context.addLine(to: CGPoint(x: base.x + nx * half, y: base.y + ny * half))
            context.addLine(to: CGPoint(x: base.x - nx * half, y: base.y - ny * half))
            context.closePath()
            context.fillPath()

            context.move(to: start)
            context.addLine(to: base)
            context.strokePath()
        }
    }

    /// 把一行文字的字形墨迹放进 `ink`。
    private static func drawLine(_ line: CTLine, ink: CGRect,
                                 color: CGColor, context: CGContext) {
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        guard bounds.width > 0, bounds.height > 0 else { return }
        context.saveGState()
        // 上下文是 y 向下，CoreText 需要 y 向上：局部再翻一次
        context.translateBy(x: ink.midX - bounds.midX, y: ink.midY + bounds.midY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        context.setFillColor(color)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// 普通文字：左上角对齐，占 textSize 那么大的框。
    private static func drawText(_ context: CGContext, string: String,
                                 origin: CGPoint, style: AnnotateStyle) {
        guard !string.isEmpty else { return }
        let line = CTLineCreateWithAttributedString(attributed(string, style: style))
        let ink = CGRect(origin: origin, size: textSize(string, style: style))
        drawLine(line, ink: ink, color: style.color.cgColor, context: context)
    }

    private static func fillChip(_ context: CGContext, rect: CGRect,
                                 corner: CGFloat, color: CGColor) {
        context.saveGState()
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect,
                               cornerWidth: corner, cornerHeight: corner,
                               transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    /// 带底色的文字标签：实色胶囊 + 白字，贴在点的左上角。
    private static func drawLabelText(_ context: CGContext, string: String,
                                      origin: CGPoint, style: AnnotateStyle) {
        guard !string.isEmpty else { return }
        var labelStyle = style
        labelStyle.fontSize = max(style.fontSize * 0.72, 11)
        let line = CTLineCreateWithAttributedString(attributed(string, style: labelStyle))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let paddingX = labelStyle.fontSize * 0.62
        let paddingY = labelStyle.fontSize * 0.32
        let chip = CGRect(x: origin.x, y: origin.y,
                          width: bounds.width + paddingX * 2,
                          height: bounds.height + paddingY * 2)
        let ink = chip.insetBy(dx: paddingX, dy: paddingY)

        fillChip(context, rect: chip, corner: chip.height * 0.3, color: style.color.cgColor)
        drawLine(line, ink: ink, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                 context: context)
    }

    private static func drawCounter(_ context: CGContext, center: CGPoint,
                                    number: Int, style: AnnotateStyle) {
        let radius = counterRadius(style: style)
        let path = counterPath(shape: style.counterShape, center: center, radius: radius)

        // Longshot 的序号就是一块纯色形状 + 白字，没有描边
        context.saveGState()
        context.setFillColor(style.color.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

        var numberStyle = style
        numberStyle.color = .white
        numberStyle.fontSize = radius * 1.12
        let text = "\(number)"
        let line = CTLineCreateWithAttributedString(attributed(text, style: numberStyle))
        // 气球和水滴的重量集中在上一半，数字跟着往上提，视觉上才是落在形状中心
        let lift: CGFloat
        switch style.counterShape {
        case .circle: lift = 0
        case .balloon: lift = radius * 0.10
        case .blob: lift = radius * 0.30
        }
        let visualCenter = CGPoint(x: center.x, y: center.y - lift)
        drawCentered(line: line, at: visualCenter, context: context)
    }

    /// Longshot 的三种序号形状。轮廓点是从 Assets.car 里的 `bar_count_draw*`
    /// 图标逐行量出来的（28×28 的 alpha 位图），这里按半径归一化后做 Catmull-Rom 平滑。
    private static func counterPath(shape: CounterShape, center: CGPoint, radius r: CGFloat) -> CGPath {
        switch shape {
        case .circle:
            let path = CGMutablePath()
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r,
                                       width: r * 2, height: r * 2))
            return path

        case .balloon:
            // 气球：上半圆，腰部以下收窄，底部收成圆钝的尖
            let profile: [(CGFloat, CGFloat)] = [
                (0, -1.00), (0.59, -0.86), (0.74, -0.71), (0.81, -0.57),
                (0.89, -0.43), (0.89, -0.21), (0.89, 0.00), (0.81, 0.21),
                (0.74, 0.36), (0.59, 0.50), (0.37, 0.64), (0.22, 0.79),
                (0.11, 0.93), (0, 1.00),
            ]
            return smoothProfile(profile, center: center, radius: r)

        case .blob:
            // 水滴：上窄下宽再收尖，最宽处在三分之一高
            let profile: [(CGFloat, CGFloat)] = [
                (0, -1.00), (0.37, -1.00), (0.59, -0.93), (0.74, -0.86),
                (0.89, -0.71), (0.96, -0.57), (1.02, -0.36), (0.96, -0.14),
                (0.81, 0.07), (0.67, 0.29), (0.59, 0.50), (0.37, 0.71),
                (0.22, 0.86), (0.11, 0.93), (0, 1.00),
            ]
            return smoothProfile(profile, center: center, radius: r)
        }
    }

    /// 右半轮廓 → 镜像成闭合曲线。Catmull-Rom 转三次贝塞尔，点少也不会出棱角。
    private static func smoothProfile(_ profile: [(CGFloat, CGFloat)],
                                      center: CGPoint, radius r: CGFloat) -> CGPath {
        // 先按 y 均匀重采样：原始量点疏密不均，直接丢给 Catmull-Rom 会在拐弯处鼓包
        let samples = 48
        var resampled: [(CGFloat, CGFloat)] = []
        for step in 0...samples {
            let y = -1 + 2 * CGFloat(step) / CGFloat(samples)
            resampled.append((interpolate(profile, at: y), y))
        }

        var points = resampled.map { CGPoint(x: center.x + $0.0 * r, y: center.y + $0.1 * r) }
        let mirrored = resampled.dropFirst().dropLast()
            .reversed()
            .map { CGPoint(x: center.x - $0.0 * r, y: center.y + $0.1 * r) }
        points.append(contentsOf: mirrored)

        let path = CGMutablePath()
        guard points.count > 3 else { return path }
        path.move(to: points[0])
        for index in points.indices {
            let p0 = points[(index - 1 + points.count) % points.count]
            let p1 = points[index]
            let p2 = points[(index + 1) % points.count]
            let p3 = points[(index + 2) % points.count]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        return path
    }

    /// 把一行文字的字形墨迹中心落在 `point` 上。
    /// 不能用 `width / 2` —— `1`、`7` 这类字形的左右侧承不对称，会明显偏左。
    private static func drawCentered(line: CTLine, at point: CGPoint, context: CGContext) {
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard bounds.width > 0, bounds.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: point.x - bounds.midX, y: point.y + bounds.midY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - 测量

    private static func drawMeasureLine(_ context: CGContext, start: CGPoint, end: CGPoint,
                                        style: AnnotateStyle, distance: CGFloat) {
        let width = max(style.lineWidth * 0.45, 1.2)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux

        context.saveGState()
        context.setLineWidth(width)
        context.setLineDash(phase: 0, lengths: [width * 4, width * 3])
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])

        // 两端各一道垂直短线，读数边界才清楚
        let cap = max(style.lineWidth * 1.6, 6)
        for point in [start, end] {
            context.move(to: CGPoint(x: point.x + nx * cap, y: point.y + ny * cap))
            context.addLine(to: CGPoint(x: point.x - nx * cap, y: point.y - ny * cap))
            context.strokePath()
        }

        let text = "\(Int(distance.rounded())) px"
        let center = CGPoint(x: (start.x + end.x) / 2 + nx * cap * 2.2,
                             y: (start.y + end.y) / 2 + ny * cap * 2.2)
        drawBadge(context, text: text, center: center, style: style)
        context.restoreGState()
    }

    private static func drawMeasureArea(_ context: CGContext, rect: CGRect, style: AnnotateStyle) {
        let width = max(style.lineWidth * 0.45, 1.2)
        context.saveGState()
        context.setLineWidth(width)
        context.setLineDash(phase: 0, lengths: [width * 4, width * 3])
        context.stroke(rect)
        context.setLineDash(phase: 0, lengths: [])

        // 四个角向内补一小段实线，虚线太长时也能看出边界
        let arm = max(style.lineWidth * 1.4, 5)
        for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            let sx: CGFloat = corner.x == rect.minX ? 1 : -1
            let sy: CGFloat = corner.y == rect.minY ? 1 : -1
            context.move(to: corner)
            context.addLine(to: CGPoint(x: corner.x + sx * arm, y: corner.y))
            context.move(to: corner)
            context.addLine(to: CGPoint(x: corner.x, y: corner.y + sy * arm))
            context.strokePath()
        }

        let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        drawBadge(context, text: text, center: CGPoint(x: rect.midX, y: rect.minY), style: style)
        context.restoreGState()
    }

    private static func drawRuler(_ context: CGContext, start: CGPoint, end: CGPoint,
                                  style: AnnotateStyle) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let width = max(style.lineWidth * 0.45, 1.2)

        context.saveGState()
        context.setLineWidth(width)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        // 每 10 像素一小格、每 5 小格一大格，和屏幕标尺一致
        let step: CGFloat = 10
        var offset: CGFloat = 0
        while offset <= length {
            let major = Int((offset / step).rounded()) % 5 == 0
            let tick = major ? max(style.lineWidth * 2.2, 8) : max(style.lineWidth * 1.1, 4)
            let point = CGPoint(x: start.x + ux * offset, y: start.y + uy * offset)
            context.move(to: CGPoint(x: point.x + nx * tick, y: point.y + ny * tick))
            context.addLine(to: CGPoint(x: point.x, y: point.y))
            context.strokePath()
            offset += step
        }

        let text = "\(Int(length.rounded())) px"
        let center = CGPoint(x: (start.x + end.x) / 2 + nx * max(style.lineWidth * 3, 12),
                             y: (start.y + end.y) / 2 + ny * max(style.lineWidth * 3, 12))
        drawBadge(context, text: text, center: center, style: style)
        context.restoreGState()
    }

    /// 测量读数的小胶囊：实色底 + 白字。
    private static func drawBadge(_ context: CGContext, text: String,
                                  center: CGPoint, style: AnnotateStyle) {
        var labelStyle = style
        labelStyle.fontSize = max(style.fontSize * 0.62, 11)
        let line = CTLineCreateWithAttributedString(attributed(text, style: labelStyle))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padding = labelStyle.fontSize * 0.45
        let height = bounds.height + padding * 2
        let width = bounds.width + padding * 2.6
        let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2,
                          width: width, height: height)

        context.saveGState()
        context.setFillColor(style.color.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2,
                               transform: nil))
        context.fillPath()

        context.translateBy(x: rect.midX - bounds.midX,
                            y: rect.midY + bounds.midY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        let white = NSAttributedString(string: text, attributes: [
            .font: font(style: labelStyle),
            .foregroundColor: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ])
        CTLineDraw(CTLineCreateWithAttributedString(white), context)
        context.restoreGState()
    }

    private static func drawMosaic(_ context: CGContext, rect: CGRect, block: CGFloat,
                                   pattern: MosaicPattern = .square,
                                   cornerRadius: CGFloat = 0,
                                   source: CGImage, imageSize: CGSize,
                                   ellipse: Bool = false) {
        let clipped = rect.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }

        context.saveGState()
        // 只让被马赛克盖住的区域参与运算，边缘不会渗出
        let mask = ellipse ? CGPath(ellipseIn: clipped, transform: nil)
                           : CGPath(rect: clipped, transform: nil)
        context.addPath(mask)
        context.clip()

        if pattern == .blur {
            drawBlurredRegion(context, rect: clipped, radius: block * 0.6, source: source)
        } else if let tiles = sampleTiles(clipped, block: block, source: source) {
            drawTiles(context, rect: clipped, tiles: tiles,
                      pattern: pattern, cornerRadius: cornerRadius)
        }
        context.restoreGState()
    }

    /// 涂抹型马赛克：把笔迹当成粗描边，只在这条带子里做像素化。
    private static func drawMosaicStroke(_ context: CGContext, points: [CGPoint], block: CGFloat,
                                         pattern: MosaicPattern = .square,
                                         width: CGFloat, source: CGImage, imageSize: CGSize) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y))
        } else {
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        let bounds = path.boundingBoxOfPath.insetBy(dx: -width / 2, dy: -width / 2)
        let clipped = bounds.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }

        context.saveGState()
        let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
        context.addPath(stroked)
        context.clip()
        if pattern == .blur {
            drawBlurredRegion(context, rect: clipped, radius: block * 0.6, source: source)
        } else if let tiles = sampleTiles(clipped, block: block, source: source) {
            drawTiles(context, rect: clipped, tiles: tiles, pattern: pattern, cornerRadius: 0)
        }
        context.restoreGState()
    }

    private struct MosaicTiles {
        var columns: Int
        var rows: Int
        var pixels: [UInt8]   // RGBA
    }

    /// 把区域缩到「每块一个像素」，再读回颜色逐块画形状。
    private static func sampleTiles(_ rect: CGRect, block: CGFloat, source: CGImage) -> MosaicTiles? {
        guard let cropped = source.cropping(to: rect.integral) else { return nil }
        let columns = max(1, Int(rect.width / max(block, 2)))
        let rows = max(1, Int(rect.height / max(block, 2)))
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let small = CGContext(data: buffer.baseAddress,
                                        width: columns,
                                        height: rows,
                                        bitsPerComponent: 8,
                                        bytesPerRow: columns * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            small.interpolationQuality = .medium
            small.draw(cropped, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return nil }
        return MosaicTiles(columns: columns, rows: rows, pixels: pixels)
    }

    private static func drawTiles(_ context: CGContext, rect: CGRect,
                                  tiles: MosaicTiles, pattern: MosaicPattern,
                                  cornerRadius: CGFloat) {
        let cellW = rect.width / CGFloat(tiles.columns)
        let cellH = rect.height / CGFloat(tiles.rows)
        context.setShouldAntialias(true)
        for row in 0..<tiles.rows {
            for column in 0..<tiles.columns {
                let index = (row * tiles.columns + column) * 4
                let color = CGColor(srgbRed: CGFloat(tiles.pixels[index]) / 255,
                                    green: CGFloat(tiles.pixels[index + 1]) / 255,
                                    blue: CGFloat(tiles.pixels[index + 2]) / 255,
                                    alpha: 1)
                context.setFillColor(color)
                let x = rect.minX + CGFloat(column) * cellW
                let y = rect.minY + CGFloat(row) * cellH
                let cell = CGRect(x: x, y: y, width: cellW + 0.6, height: cellH + 0.6)

                switch pattern {
                case .square, .blur:
                    let radius = min(cornerRadius, min(cellW, cellH) / 2)
                    context.addPath(CGPath(roundedRect: cell, cornerWidth: radius,
                                           cornerHeight: radius, transform: nil))
                    context.fillPath()

                case .hexagon:
                    // 六边形：宽边在左右，上下收尖
                    let cx = cell.midX, cy = cell.midY
                    let hw = cellW * 0.56, hh = cellH * 0.58
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: cx, y: cy - hh))
                    path.addLine(to: CGPoint(x: cx + hw, y: cy - hh * 0.45))
                    path.addLine(to: CGPoint(x: cx + hw, y: cy + hh * 0.45))
                    path.addLine(to: CGPoint(x: cx, y: cy + hh))
                    path.addLine(to: CGPoint(x: cx - hw, y: cy + hh * 0.45))
                    path.addLine(to: CGPoint(x: cx - hw, y: cy - hh * 0.45))
                    path.closeSubpath()
                    context.addPath(path)
                    context.fillPath()

                case .crystal:
                    // 晶体：错位菱形，接近 Longshot 的碎晶观感
                    let cx = cell.midX, cy = cell.midY
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: cx, y: cy - cellH * 0.62))
                    path.addLine(to: CGPoint(x: cx + cellW * 0.62, y: cy))
                    path.addLine(to: CGPoint(x: cx, y: cy + cellH * 0.62))
                    path.addLine(to: CGPoint(x: cx - cellW * 0.62, y: cy))
                    path.closeSubpath()
                    context.addPath(path)
                    context.fillPath()
                }
            }
        }
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func drawBlurredRegion(_ context: CGContext, rect: CGRect,
                                          radius: CGFloat, source: CGImage) {
        guard radius > 0,
              let filter = CIFilter(name: "CIGaussianBlur") else { return }
        // CIImage 的 y 轴朝上，先把左上原点的 rect 翻过去
        let ciRect = CGRect(x: rect.minX,
                            y: CGFloat(source.height) - rect.maxY,
                            width: rect.width, height: rect.height)
        let input = CIImage(cgImage: source).clampedToExtent().cropped(to: ciRect)
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: ciRect),
              let blurred = ciContext.createCGImage(output, from: ciRect) else { return }
        drawImage(blurred, in: rect, context: context)
    }

    /// 在 y 向下的上下文里画 CGImage：局部翻一次，否则会上下颠倒。
    public static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + rect.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    // MARK: - 导出

    /// 把底图和标注合成一张新图，像素尺寸与底图一致。
    public static func flatten(base: CGImage, annotations: [Annotation]) -> CGImage? {
        guard !annotations.isEmpty else { return base }
        let width = base.width
        let height = base.height
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        drawImage(base, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
        draw(annotations, in: context, imageSize: CGSize(width: width, height: height),
             mosaicSource: base)
        return context.makeImage()
    }
}

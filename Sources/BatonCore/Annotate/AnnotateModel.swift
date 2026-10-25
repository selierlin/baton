import CoreGraphics
import Foundation

/// 标注颜色。存 RGBA 而不是 `NSColor`，才能直接进 JSON / 剪贴板。
public struct AnnotateColor: Codable, Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = AnnotateColor(red: 1.00, green: 0.30, blue: 0.30)
    public static let orange = AnnotateColor(red: 0.98, green: 0.58, blue: 0.14)
    public static let yellow = AnnotateColor(red: 1.00, green: 0.84, blue: 0.04)
    public static let green = AnnotateColor(red: 0.55, green: 0.88, blue: 0.00)
    public static let cyan = AnnotateColor(red: 0.15, green: 0.82, blue: 0.85)
    public static let blue = AnnotateColor(red: 0.15, green: 0.51, blue: 0.96)
    public static let purple = AnnotateColor(red: 0.55, green: 0.36, blue: 0.95)
    public static let pink = AnnotateColor(red: 1.00, green: 0.42, blue: 0.70)
    public static let crimson = AnnotateColor(red: 0.72, green: 0.10, blue: 0.18)
    public static let gray = AnnotateColor(red: 0.55, green: 0.55, blue: 0.58)
    public static let white = AnnotateColor(red: 1, green: 1, blue: 1)
    public static let black = AnnotateColor(red: 0, green: 0, blue: 0)

    /// 属性条上常驻的三个预置色（红/黄/绿，和 Longshot 一致）。
    public static let palette: [AnnotateColor] = [.red, .yellow, .green]

    /// 点开「更多」后能选的完整预置色，顺序按色相走一圈，末尾是黑白。
    public static let swatchPalette: [AnnotateColor] = [
        .red, .orange, .yellow, .green, .cyan, .blue,
        .purple, .pink, .crimson, .gray, .white, .black
    ]

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// 形状的绘制样式。Longshot 属性条里是三个图标：斜线 / 边框 / 实心。
public enum ShapeDrawStyle: String, Codable, Sendable, CaseIterable {
    /// 顺序即属性条上的排列：边框、斜线、实心，和 Longshot 一致
    case outline
    case hatched
    case filled

    public var title: String {
        switch self {
        case .hatched: return "斜线"
        case .outline: return "边框"
        case .filled: return "实心"
        }
    }
}

public enum LinePattern: String, Codable, Sendable, CaseIterable {
    case solid
    case dashed

    public var title: String { self == .solid ? "实线" : "虚线" }
}

public enum MarkerCap: String, Codable, Sendable, CaseIterable {
    case round
    case square

    public var title: String { self == .round ? "圆角" : "直角" }
}

public enum MosaicPattern: String, Codable, Sendable, CaseIterable {
    case square
    case hexagon
    case crystal
    case blur

    public var title: String {
        switch self {
        case .square: return "方形"
        case .hexagon: return "菱形"
        case .crystal: return "晶体"
        case .blur: return "模糊"
        }
    }
}

public enum CounterShape: String, Codable, Sendable, CaseIterable {
    case circle
    case balloon
    case blob

    public var title: String {
        switch self {
        case .circle: return "圆形"
        case .balloon: return "气球"
        case .blob: return "水滴"
        }
    }
}

public enum TextMarkStyle: String, Codable, Sendable, CaseIterable {
    case standard
    case textOutline
    case boxed
    case reverse

    public var title: String {
        switch self {
        case .standard: return "默认文本"
        case .textOutline: return "文字描边"
        case .boxed: return "文本背景"
        case .reverse: return "反向背景"
        }
    }
}

/// 工具即 UI：工具条按这个数组枚举生成，加工具只需往这里追加。
public enum AnnotateTool: String, CaseIterable, Codable, Sendable {
    case select
    case rectangle
    case ellipse
    case line
    /// Longshot 的 `flatArrow`：平头三角形箭头的默认箭头
    case flatArrow
    /// Longshot 的 `sinkArrow`：箭头底部内凹（Inward arrow）
    case sinkArrow
    case pencil
    case marker
    case mosaic
    case text
    case counter
    /// 马赛克的椭圆、涂抹两种变体
    case mosaicEllipse
    case mosaicPencil
    /// 高亮的椭圆、涂抹两种变体（`.marker` 是矩形）
    case markerEllipse
    case markerPencil
    /// 马克笔：不透明的手写笔迹
    case markerPen
    /// 带底色的文字标签
    case labelText
    /// 尺子：拖一条线，沿线画刻度
    case ruler
    /// 长度标注：线 + 像素长度
    case length
    /// 面积标注：矩形 + 宽高
    case area
    /// 取色：调系统吸管，不落图元
    case colorPick

    public var title: String {
        switch self {
        case .select: return "选择"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .line: return "直线"
        case .flatArrow: return "平箭头"
        case .sinkArrow: return "内凹箭头"
        case .pencil: return "画笔"
        case .marker: return "高亮"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        case .counter: return "序号"
        case .mosaicEllipse: return "椭圆马赛克"
        case .mosaicPencil: return "涂抹马赛克"
        case .markerEllipse: return "椭圆高亮"
        case .markerPencil: return "涂抹高亮"
        case .markerPen: return "马克笔"
        case .labelText: return "标签文字"
        case .ruler: return "尺子"
        case .length: return "长度"
        case .area: return "面积"
        case .colorPick: return "取色"
        }
    }

    public var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .flatArrow: return "arrow.up.right"
        case .sinkArrow: return "arrow.up.right.circle"
        case .pencil: return "pencil.tip"
        case .marker: return "highlighter"
        case .mosaic: return "squareshape.split.3x3"
        case .text: return "character.textbox"
        case .counter: return "1.circle"
        case .mosaicEllipse: return "circle.grid.3x3"
        case .mosaicPencil: return "paintbrush"
        case .markerEllipse: return "circle"
        case .markerPencil: return "highlighter"
        case .markerPen: return "pencil"
        case .labelText: return "text.bubble"
        case .ruler: return "ruler"
        case .length: return "arrow.left.and.right"
        case .area: return "square.dashed"
        case .colorPick: return "eyedropper"
        }
    }

    /// 会话内快捷键。数字段照 Longshot 的原表：1 矩形 / 2 直线（含箭头）/
    /// 3 马赛克 / 4 高亮 / 5 尺子 / 6 画笔 / 7 文字 / 8 序号。
    public var key: Character? {
        switch self {
        case .select: return "v"
        case .rectangle: return "1"
        case .line: return "2"
        case .mosaic: return "3"
        case .marker: return "4"
        case .ruler: return "5"
        case .pencil: return "6"
        case .text: return "7"
        case .counter: return "8"
        case .flatArrow, .sinkArrow, .ellipse, .mosaicEllipse, .mosaicPencil,
             .markerEllipse, .markerPencil, .markerPen, .labelText,
             .length, .area, .colorPick:
            return nil
        }
    }

    /// 拖拽类工具（按下-拖动-抬起生成一条标注）。
    public var isDragging: Bool {
        switch self {
        case .select, .text, .labelText, .counter, .colorPick: return false
        default: return true
        }
    }

    /// 自由手绘：按下后持续追加采样点。
    public var isFreehand: Bool {
        switch self {
        case .pencil, .markerPencil, .markerPen, .mosaicPencil: return true
        default: return false
        }
    }
}

public struct AnnotateStyle: Codable, Sendable, Equatable {
    public var color: AnnotateColor
    /// 像素。随图片倍率缩放，2x 截图上 6 看起来才是 3pt。
    public var lineWidth: CGFloat
    public var opacity: Double
    public var fontSize: CGFloat
    /// 马赛克块边长（像素）。
    public var mosaicBlock: CGFloat

    // MARK: Longshot 属性条上的每工具参数

    public var fontName: String
    /// 矩形 / 椭圆的绘制样式：斜线、边框、实心
    public var shapeDrawStyle: ShapeDrawStyle
    /// 直线 / 箭头 / 形状的线型
    public var linePattern: LinePattern
    /// 记号笔笔头
    public var markerCap: MarkerCap
    public var mosaicPattern: MosaicPattern
    public var counterShape: CounterShape
    public var textMarkStyle: TextMarkStyle
    /// 像素。矩形圆角、高亮圆角、马赛克块圆角共用。
    public var cornerRadius: CGFloat
    /// 高亮 / 实心形状的填充透明度
    public var fillAlpha: Double
    /// 序号大小倍率（属性条的「大小」）
    public var counterScale: CGFloat

    public init(color: AnnotateColor = .red,
                lineWidth: CGFloat = 6,
                opacity: Double = 1,
                fontSize: CGFloat = 28,
                mosaicBlock: CGFloat = 16) {
        self.color = color
        self.lineWidth = lineWidth
        self.opacity = opacity
        self.fontSize = fontSize
        self.mosaicBlock = mosaicBlock
        self.fontName = "HelveticaNeue-Bold"
        self.shapeDrawStyle = .outline
        self.linePattern = .solid
        self.markerCap = .round
        self.mosaicPattern = .square
        self.counterShape = .circle
        self.textMarkStyle = .standard
        self.cornerRadius = 0
        self.fillAlpha = 1
        self.counterScale = 1
    }

    private enum CodingKeys: String, CodingKey {
        case color, lineWidth, opacity, fontSize, mosaicBlock, fontName
        case shapeDrawStyle, linePattern, markerCap, mosaicPattern
        case counterShape, textMarkStyle, cornerRadius, fillAlpha, counterScale
    }

    /// 旧版本存下来的标注没有这些字段，缺省时按默认值补齐。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decode(AnnotateColor.self, forKey: .color)
        lineWidth = try c.decode(CGFloat.self, forKey: .lineWidth)
        opacity = try c.decode(Double.self, forKey: .opacity)
        fontSize = try c.decode(CGFloat.self, forKey: .fontSize)
        mosaicBlock = try c.decode(CGFloat.self, forKey: .mosaicBlock)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "HelveticaNeue-Bold"
        shapeDrawStyle = try c.decodeIfPresent(ShapeDrawStyle.self, forKey: .shapeDrawStyle) ?? .outline
        linePattern = try c.decodeIfPresent(LinePattern.self, forKey: .linePattern) ?? .solid
        markerCap = try c.decodeIfPresent(MarkerCap.self, forKey: .markerCap) ?? .round
        mosaicPattern = try c.decodeIfPresent(MosaicPattern.self, forKey: .mosaicPattern) ?? .square
        counterShape = try c.decodeIfPresent(CounterShape.self, forKey: .counterShape) ?? .circle
        textMarkStyle = try c.decodeIfPresent(TextMarkStyle.self, forKey: .textMarkStyle) ?? .standard
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 0
        fillAlpha = try c.decodeIfPresent(Double.self, forKey: .fillAlpha) ?? 1
        counterScale = try c.decodeIfPresent(CGFloat.self, forKey: .counterScale) ?? 1
    }

    /// 按图片倍率把「视觉尺寸」换算成像素尺寸。
    public func scaled(by scale: CGFloat) -> AnnotateStyle {
        var style = self
        style.lineWidth *= scale
        style.fontSize *= scale
        style.mosaicBlock *= scale
        style.cornerRadius *= scale
        return style
    }

    /// 属性条吃的是「逻辑点」，把像素尺寸换回去。
    public func unscaled(by scale: CGFloat) -> AnnotateStyle {
        guard scale > 0 else { return self }
        var style = self
        style.lineWidth /= scale
        style.fontSize /= scale
        style.mosaicBlock /= scale
        style.cornerRadius /= scale
        return style
    }
}

/// 选中后的控制点。矩形类 8 个，线类只有首尾两个。
public enum SelectionHandle: Sendable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case start, end

    public static var square: [SelectionHandle] {
        [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
    }

    public static var line: [SelectionHandle] { [.start, .end] }
}

/// 一条标注。几何量一律存**图片像素坐标（左上原点）**：
/// 画布缩放、导出、贴图重采样都只是换个绘制变换，模型不变。
public struct Annotation: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case line(start: CGPoint, end: CGPoint)
        case arrow(start: CGPoint, end: CGPoint, sinkTail: Bool)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case stroke(points: [CGPoint])
        case mosaic(CGRect)
        case mosaicEllipse(CGRect)
        case mosaicStroke(points: [CGPoint])
        case highlight(CGRect, ellipse: Bool)
        case text(origin: CGPoint, string: String)
        case labelText(origin: CGPoint, string: String)
        case counter(center: CGPoint, number: Int)
        /// 尺子：拖一条线段，沿线显示刻度
        case ruler(start: CGPoint, end: CGPoint)
        /// 长度：线 + 「N px」
        case length(start: CGPoint, end: CGPoint)
        /// 面积：矩形 + 「W × H」
        case area(CGRect)
    }

    public var id: UUID
    public var kind: Kind
    public var style: AnnotateStyle
    /// 产生这条标注的工具。选中后属性条靠它切到对应面板。
    public var tool: AnnotateTool?

    public init(id: UUID = UUID(), kind: Kind, style: AnnotateStyle, tool: AnnotateTool? = nil) {
        self.id = id
        self.kind = kind
        self.style = style
        self.tool = tool
    }

    /// 外接矩形，含线宽余量——命中测试和重绘区域都靠它。
    public var bounds: CGRect {
        let pad = style.lineWidth
        switch kind {
        case .line(let start, let end):
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
                .insetBy(dx: -pad, dy: -pad)
        case .arrow(let start, let end, _):
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
                .insetBy(dx: -pad * 2, dy: -pad * 2)
        case .rectangle(let rect), .ellipse(let rect), .mosaic(let rect), .mosaicEllipse(let rect):
            return rect.insetBy(dx: -pad, dy: -pad)
        case .highlight(let rect, _):
            return rect
        case .stroke(let points), .mosaicStroke(let points):
            guard let first = points.first else { return .zero }
            var rect = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                rect = rect.union(CGRect(origin: point, size: .zero))
            }
            return rect.insetBy(dx: -pad * 3, dy: -pad * 3)
        case .text(let origin, let string), .labelText(let origin, let string):
            let size = AnnotateRenderer.textSize(string, style: style)
            return CGRect(origin: origin, size: size).insetBy(dx: -pad, dy: -pad)
        case .counter(let center, _):
            let radius = AnnotateRenderer.counterRadius(style: style)
            return CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        case .ruler(let start, let end), .length(let start, let end):
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
                .insetBy(dx: -pad * 2, dy: -pad * 2)
        case .area(let rect):
            return rect.insetBy(dx: -pad * 2, dy: -pad * 2)
        }
    }

    /// 选择工具拖动整体平移。
    public mutating func offsetBy(dx: CGFloat, dy: CGFloat) {
        switch kind {
        case .line(let start, let end):
            kind = .line(start: start.offset(dx, dy), end: end.offset(dx, dy))
        case .arrow(let start, let end, let sink):
            kind = .arrow(start: start.offset(dx, dy), end: end.offset(dx, dy), sinkTail: sink)
        case .rectangle(let rect):
            kind = .rectangle(rect.offsetBy(dx: dx, dy: dy))
        case .ellipse(let rect):
            kind = .ellipse(rect.offsetBy(dx: dx, dy: dy))
        case .stroke(let points):
            kind = .stroke(points: points.map { $0.offset(dx, dy) })
        case .mosaic(let rect):
            kind = .mosaic(rect.offsetBy(dx: dx, dy: dy))
        case .mosaicEllipse(let rect):
            kind = .mosaicEllipse(rect.offsetBy(dx: dx, dy: dy))
        case .mosaicStroke(let points):
            kind = .mosaicStroke(points: points.map { $0.offset(dx, dy) })
        case .highlight(let rect, let ellipse):
            kind = .highlight(rect.offsetBy(dx: dx, dy: dy), ellipse: ellipse)
        case .text(let origin, let string):
            kind = .text(origin: origin.offset(dx, dy), string: string)
        case .labelText(let origin, let string):
            kind = .labelText(origin: origin.offset(dx, dy), string: string)
        case .counter(let center, let number):
            kind = .counter(center: center.offset(dx, dy), number: number)
        case .ruler(let start, let end):
            kind = .ruler(start: start.offset(dx, dy), end: end.offset(dx, dy))
        case .length(let start, let end):
            kind = .length(start: start.offset(dx, dy), end: end.offset(dx, dy))
        case .area(let rect):
            kind = .area(rect.offsetBy(dx: dx, dy: dy))
        }
    }

    /// 线类图元用首尾控制点，其余用外接矩形。
    public var isLineLike: Bool {
        switch kind {
        case .line, .arrow, .ruler, .length: return true
        default: return false
        }
    }

    /// 选中框和手柄使用的几何矩形（不含线宽外扩的余量）。
    public var selectionRect: CGRect {
        switch kind {
        case .rectangle(let rect), .ellipse(let rect),
             .mosaic(let rect), .mosaicEllipse(let rect),
             .highlight(let rect, _), .area(let rect):
            return rect
        case .line(let start, let end), .arrow(let start, let end, _),
             .ruler(let start, let end), .length(let start, let end):
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        default:
            return bounds
        }
    }

    public var handles: [SelectionHandle] {
        isLineLike ? SelectionHandle.line : SelectionHandle.square
    }

    /// 有可拖拽的控制点。文字、序号这类只有位置没有尺寸的图元不给手柄，
    /// 免得画出点不动的死手柄。
    public var supportsResize: Bool {
        switch kind {
        case .rectangle, .ellipse, .mosaic, .mosaicEllipse, .highlight, .area,
             .line, .arrow, .ruler, .length:
            return true
        case .stroke, .mosaicStroke, .text, .labelText, .counter:
            return false
        }
    }

    public var editableHandles: [SelectionHandle] {
        supportsResize ? handles : []
    }

    /// 命中测试按**图元本身的几何**判，不用外接矩形。
    ///
    /// 斜着的箭头外接框很大，用矩形判会把框里的空白处也算命中——那地方正是
    /// 用户想再画一条箭头的地方。闭合形状内部算命中：按下不动是选中，
    /// 拖起来照常画新图元，两种意图由手势分开。
    public func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let slack = max(tolerance, 1)
        switch kind {
        case .line(let start, let end), .ruler(let start, let end), .length(let start, let end):
            let reach = max(slack, style.lineWidth / 2 + 1)
            return Self.distance(point, toSegment: start, end) <= reach

        case .arrow(let start, let end, _):
            // 箭头头部比线宽宽得多，按线宽 2.5 倍的头部半宽放宽
            let reach = max(slack, style.lineWidth * 1.6)
            return Self.distance(point, toSegment: start, end) <= reach

        case .stroke(let points):
            return Self.hitsStroke(points, point: point, reach: max(slack, style.lineWidth / 2))

        case .mosaicStroke(let points):
            return Self.hitsStroke(points, point: point,
                                   reach: max(slack, max(style.lineWidth * 5, 24) / 2))

        case .rectangle(let rect), .mosaic(let rect), .area(let rect):
            return rect.insetBy(dx: -slack, dy: -slack).contains(point)

        case .ellipse(let rect), .mosaicEllipse(let rect):
            return Self.hitsEllipse(rect, point: point, slack: slack)

        case .highlight(let rect, let ellipse):
            if ellipse { return Self.hitsEllipse(rect, point: point, slack: slack) }
            return rect.insetBy(dx: -slack, dy: -slack).contains(point)

        case .text(let origin, let string), .labelText(let origin, let string):
            let size = AnnotateRenderer.textSize(string, style: style)
            return CGRect(origin: origin, size: size)
                .insetBy(dx: -slack, dy: -slack).contains(point)

        case .counter(let center, _):
            let radius = AnnotateRenderer.counterRadius(style: style)
            return hypot(point.x - center.x, point.y - center.y) <= radius + slack
        }
    }

    private static func hitsEllipse(_ rect: CGRect, point: CGPoint, slack: CGFloat) -> Bool {
        let rx = rect.width / 2 + slack
        let ry = rect.height / 2 + slack
        guard rx > 0, ry > 0 else { return false }
        let dx = (point.x - rect.midX) / rx
        let dy = (point.y - rect.midY) / ry
        return hypot(dx, dy) <= 1
    }

    private static func hitsStroke(_ points: [CGPoint], point: CGPoint, reach: CGFloat) -> Bool {
        guard let first = points.first else { return false }
        guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) <= reach }
        var previous = first
        for current in points.dropFirst() {
            if distance(point, toSegment: previous, current) <= reach { return true }
            previous = current
        }
        return false
    }

    private static func distance(_ point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    public func handlePoint(_ handle: SelectionHandle) -> CGPoint {
        switch kind {
        case .line(let start, let end), .arrow(let start, let end, _),
             .ruler(let start, let end), .length(let start, let end):
            return handle == .start ? start : end
        default:
            let rect = selectionRect
            switch handle {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .top: return CGPoint(x: rect.midX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .right: return CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .left: return CGPoint(x: rect.minX, y: rect.midY)
            case .start, .end: return CGPoint(x: rect.midX, y: rect.midY)
            }
        }
    }

    /// 拖控制点改几何。不支持的图元原样返回。
    public func resized(_ handle: SelectionHandle, to point: CGPoint) -> Annotation {
        var copy = self
        switch kind {
        case .rectangle(let rect):
            copy.kind = .rectangle(Self.resize(rect, handle: handle, to: point))
        case .ellipse(let rect):
            copy.kind = .ellipse(Self.resize(rect, handle: handle, to: point))
        case .mosaic(let rect):
            copy.kind = .mosaic(Self.resize(rect, handle: handle, to: point))
        case .mosaicEllipse(let rect):
            copy.kind = .mosaicEllipse(Self.resize(rect, handle: handle, to: point))
        case .highlight(let rect, let ellipse):
            copy.kind = .highlight(Self.resize(rect, handle: handle, to: point), ellipse: ellipse)
        case .area(let rect):
            copy.kind = .area(Self.resize(rect, handle: handle, to: point))
        case .line(let start, let end):
            copy.kind = .line(start: handle == .start ? point : start,
                              end: handle == .end ? point : end)
        case .arrow(let start, let end, let sink):
            copy.kind = .arrow(start: handle == .start ? point : start,
                               end: handle == .end ? point : end, sinkTail: sink)
        case .ruler(let start, let end):
            copy.kind = .ruler(start: handle == .start ? point : start,
                               end: handle == .end ? point : end)
        case .length(let start, let end):
            copy.kind = .length(start: handle == .start ? point : start,
                                end: handle == .end ? point : end)
        default:
            break
        }
        return copy
    }

    private static func resize(_ rect: CGRect, handle: SelectionHandle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        case .start, .end: break
        }
        // 拖过对边时翻转，不让矩形变成负尺寸
        if maxX - minX < 2 { return rect }
        if maxY - minY < 2 { return rect }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private extension CGPoint {
    func offset(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}

/// 会话内命令，画布不直接操作窗口，交给控制器决定顺序。
public enum AnnotateCommand: Sendable, Hashable {
    case undo
    case redo
    case copy
    case save
    case pin
    case cancel
    /// 交给外部流程的终态动作（识别 / 打开 / 隔空投送）。
    /// `silent` 对应 Longshot 的 R 与 ⌘R：都进剪贴板，区别只在弹不弹面板。
    case ocr(silent: Bool)
    case qr
    case open
    case airDrop
}

/// 标注文档：只存值，撤销用快照栈。
///
/// 为什么不用命令模式：每条标注都是值类型，一份数组快照只有几十字节到几 KB，
/// 而命令模式要求每个操作都写一对 apply/revert，工具一多就是维护负担。
public final class AnnotateDocument {
    public private(set) var annotations: [Annotation] = []
    public private(set) var selection: UUID?

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private let undoLimit = 100

    public init(annotations: [Annotation] = []) {
        self.annotations = annotations
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public var selectedAnnotation: Annotation? {
        guard let selection else { return nil }
        return annotations.first { $0.id == selection }
    }

    /// 属性条改了颜色/粗细等：有选中元素就改它，否则只改当前工具的默认样式。
    @discardableResult
    public func restyle(id: UUID, style: AnnotateStyle) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }),
              annotations[index].style != style else { return false }
        checkpoint()
        annotations[index].style = style
        return true
    }

    @discardableResult
    public func updateText(id: UUID, string: String) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        switch annotations[index].kind {
        case .text(let origin, _):
            checkpoint()
            annotations[index].kind = .text(origin: origin, string: string)
            return true
        case .labelText(let origin, _):
            checkpoint()
            annotations[index].kind = .labelText(origin: origin, string: string)
            return true
        default:
            return false
        }
    }

    @discardableResult
    public func setCounterNumber(_ number: Int, for id: UUID) -> Bool {
        guard number > 0,
              let index = annotations.firstIndex(where: { $0.id == id }),
              case .counter(let center, let old) = annotations[index].kind,
              old != number else { return false }
        checkpoint()
        annotations[index].kind = .counter(center: center, number: number)
        return true
    }

    /// 下一个序号标注的编号：已有最大号 + 1，删掉中间某个也不会重号。
    public var nextCounterNumber: Int {
        let used = annotations.compactMap { annotation -> Int? in
            if case .counter(_, let number) = annotation.kind { return number }
            return nil
        }
        return (used.max() ?? 0) + 1
    }

    public func add(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
        selection = annotation.id
    }

    public func remove(id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        checkpoint()
        annotations.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    /// 拖动结束后整体替换（拖动过程中改副本，避免每帧压栈）。
    public func replace(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        checkpoint()
        annotations[index] = annotation
    }

    public func select(_ id: UUID?) {
        selection = id
    }

    /// 捕获区域变了：所有图元跟着平移同样的距离（单位是图片像素）。
    ///
    /// 撤销栈也要一起移 —— 否则「画一条箭头 → 调大选区 → ⌘Z」会把箭头撤回到
    /// 旧坐标系下的位置，看上去就是凭空错位。这里不压新快照：改选区是视图调整，
    /// 不是一次可撤销的编辑。
    public func translateAll(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        func shift(_ list: [Annotation]) -> [Annotation] {
            list.map { annotation in
                var moved = annotation
                moved.offsetBy(dx: dx, dy: dy)
                return moved
            }
        }
        annotations = shift(annotations)
        undoStack = undoStack.map(shift)
        redoStack = redoStack.map(shift)
        if let snapshot = transactionSnapshot { transactionSnapshot = shift(snapshot) }
    }

    @discardableResult
    public func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(annotations)
        annotations = previous
        if let selection, !annotations.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(annotations)
        annotations = next
        return true
    }

    /// 命中测试：从最后画的往前找，压在上面的优先。
    public func hitTest(_ point: CGPoint, tolerance: CGFloat = 6) -> UUID? {
        for annotation in annotations.reversed() where annotation.contains(point, tolerance: tolerance) {
            return annotation.id
        }
        return nil
    }

    // MARK: - 连续操作

    private var transactionSnapshot: [Annotation]?

    /// 拖动这类连续操作：按下时记快照，抬手时合成一步，不给每帧都压栈。
    public func beginTransaction() {
        transactionSnapshot = annotations
    }

    public func endTransaction() {
        guard let snapshot = transactionSnapshot else { return }
        transactionSnapshot = nil
        guard snapshot != annotations else { return }
        undoStack.append(snapshot)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// 事务内原地改，不压栈。
    public func updateInPlace(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    private func checkpoint() {
        undoStack.append(annotations)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }
}

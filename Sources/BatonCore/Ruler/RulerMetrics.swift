import CoreGraphics
import Foundation

/// 尺子的纯几何/文本换算。抽出来是为了能直接跑单测，
/// 视图里只剩「拿到数字怎么画」。
public enum RulerMetrics {
    /// 尺寸文案：像素是准数，点值只在 Retina（倍率 > 1）时补出来。
    public static func sizeText(width: Int, height: Int, scale: CGSize) -> String {
        sizeText(width: width, height: height, scale: scale, unit: .pixel)
    }

    /// 按设置里的单位出读数。
    ///
    /// 像素模式保留「px + pt」双写（设计稿对照最常用），
    /// 物理单位模式只给一行——两行数字换来换去反而看不清。
    public static func sizeText(width: Int, height: Int, scale: CGSize,
                                unit: RulerUnit) -> String {
        switch unit {
        case .pixel:
            let pixels = "\(width) × \(height) px"
            guard scale.width > 1.01, scale.height > 1.01 else { return pixels }
            let points = "\(Int((CGFloat(width) / scale.width).rounded())) × \(Int((CGFloat(height) / scale.height).rounded())) pt"
            return "\(pixels)   \(points)"
        default:
            let w = unit.value(pixels: Double(width), pixelsPerPoint: Double(scale.width))
            let h = unit.value(pixels: Double(height), pixelsPerPoint: Double(scale.height))
            return "\(number(w, unit: unit)) × \(number(h, unit: unit)) \(unit.suffix)"
        }
    }

    /// 单轴长度 / 角度这类单值读数。
    public static func lengthText(pixels: Double, pixelsPerPoint: Double, unit: RulerUnit) -> String {
        let value = unit.value(pixels: pixels, pixelsPerPoint: pixelsPerPoint)
        return "\(number(value, unit: unit)) \(unit.suffix)"
    }

    /// cm/inch 给一位小数，px/pt 取整——像素给小数没有意义，反而挡住视线。
    public static func number(_ value: Double, unit: RulerUnit) -> String {
        if unit.usesDecimals {
            return String(format: "%.1f", value)
        }
        return "\(Int(value.rounded()))"
    }

    /// 取色文案，按设置里的格式输出。
    public static func colorText(red: UInt8, green: UInt8, blue: UInt8,
                                 format: RulerColorFormat) -> String {
        switch format {
        case .hex:
            return hex(red: red, green: green, blue: blue)
        case .rgb:
            return "rgb(\(red), \(green), \(blue))"
        case .hsl:
            let (h, s, l) = hsl(red: red, green: green, blue: blue)
            return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        }
    }

    /// RGB → HSL。返回 h ∈ [0, 360)，s/l ∈ [0, 1]。
    public static func hsl(red: UInt8, green: UInt8, blue: UInt8) -> (h: Double, s: Double, l: Double) {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let maxV = max(r, g, b), minV = min(r, g, b)
        let delta = maxV - minV
        let l = (maxV + minV) / 2
        guard delta > 0.0001 else { return (0, 0, l) }

        let s = delta / (1 - abs(2 * l - 1))
        var h: Double
        switch maxV {
        case r: h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: h = (b - r) / delta + 2
        default: h = (r - g) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    /// 两条射线的夹角（0…180°），顶点在 `vertex`。
    public static func degrees(from a: CGPoint, vertex: CGPoint, to b: CGPoint) -> Double {
        let v1 = CGPoint(x: a.x - vertex.x, y: a.y - vertex.y)
        let v2 = CGPoint(x: b.x - vertex.x, y: b.y - vertex.y)
        let len1 = hypot(v1.x, v1.y), len2 = hypot(v2.x, v2.y)
        guard len1 > 0.0001, len2 > 0.0001 else { return 0 }
        let cosine = (v1.x * v2.x + v1.y * v2.y) / (len1 * len2)
        // 浮点误差会让 cos 轻微越界，acos 会返回 nan
        return acos(min(max(cosine, -1), 1)) * 180 / .pi
    }

    public static func angleText(_ degrees: Double) -> String {
        String(format: "%.1f°", degrees)
    }

    /// 单轴约束：水平模式只保留 dx，垂直模式只保留 dy。
    public static func axisLocked(anchor: CGPoint, point: CGPoint, horizontal: Bool) -> CGPoint {
        horizontal ? CGPoint(x: point.x, y: anchor.y) : CGPoint(x: anchor.x, y: point.y)
    }

    /// 读数统一用 `#RRGGBB`，大写，粘贴到设计软件不会因为大小写有歧义。
    public static func hex(red: UInt8, green: UInt8, blue: UInt8) -> String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// Shift 锁正方形：取 |dx|、|dy| 里的大者，按原方向展开。
    /// Longshot 的 `rulerHoldHorizontal/VerticalDistance` 就是这个动作。
    public static func squareLocked(anchor: CGPoint, point: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let adx = abs(dx), ady = abs(dy)
        if adx <= ady {
            return CGPoint(x: anchor.x + (dx <= 0 ? -ady : ady), y: point.y)
        }
        return CGPoint(x: point.x, y: anchor.y + (dy <= 0 ? -adx : adx))
    }

    /// 两点之间归一化后的矩形，宽高恒为正。
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 视图点 → 图片像素（视图与图片同为左上原点，只差倍率）。
    public static func pixelPoint(_ point: CGPoint, scale: CGSize) -> CGPoint {
        CGPoint(x: point.x * scale.width, y: point.y * scale.height)
    }

    /// 视图矩形 → 图片像素矩形；`integral` 后正好落在像素边界上。
    public static func pixelRect(_ rect: CGRect, scale: CGSize) -> CGRect {
        CGRect(x: rect.minX * scale.width,
               y: rect.minY * scale.height,
               width: rect.width * scale.width,
               height: rect.height * scale.height).integral
    }
}

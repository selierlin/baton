import Foundation

/// 纯颜色值文本的识别口径。
///
/// 为什么要认文本：剪贴板里真正带 `NSColor` 对象（`com.apple.cocoa.pasteboard.color`）
/// 的场景极少——只有设计工具的「拷贝色样」会写，而日常的 Copy HEX / Copy RGB
/// 写进来的都是纯文本，不认就永远进不了「颜色」分类。
///
/// 只认「整段就是一个颜色值」：`#fff` 算，`color: #fff;` 不算。
/// 判错代价是把一段文字藏进颜色分类，所以宁严勿宽。
public enum ColorText {
    /// 整段文本是颜色值时返回归一化的大写 `#RRGGBB`，否则 nil。
    ///
    /// 支持：`#RGB`、`#RGBA`、`#RRGGBB`、`#RRGGBBAA`、
    /// `rgb(51, 153, 230)`、`rgba(51 153 230 / .5)`、`hsl(210, 62%, 55%)`、`hsla(…)`。
    /// alpha 只参与解析判定，不进返回值——颜色分类里存的是纯色。
    public static func hex(from text: String) -> String? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 颜色值都很短；长文本再声称自己是颜色，基本都是误判
        guard !raw.isEmpty, raw.count <= 60 else { return nil }
        if let hex = parseHex(raw) { return hex }
        if let hex = parseFunction(raw, name: "rgb", isHSL: false) { return hex }
        if let hex = parseFunction(raw, name: "hsl", isHSL: true) { return hex }
        return nil
    }

    // MARK: - 十六进制

    private static func parseHex(_ text: String) -> String? {
        // 必须带 `#`：裸 hex 太容易和普通单词撞（`abc`、`deadbeef` 都是合法 hex）
        guard text.hasPrefix("#") else { return nil }
        var body = String(text.dropFirst())
        guard (3...8).contains(body.count), body.allSatisfy(\.isHexDigit) else { return nil }
        // 3/4 位是每位重复一字符的简写；7 位是中间多打了一位，不算颜色
        switch body.count {
        case 3, 4:
            body = String(body.prefix(3)).map { "\($0)\($0)" }.joined()
        case 6, 8:
            body = String(body.prefix(6))
        default:
            return nil
        }
        return "#" + body.uppercased()
    }

    // MARK: - rgb() / hsl()

    private static func parseFunction(_ text: String, name: String, isHSL: Bool) -> String? {
        let lowered = text.lowercased()
        // `rgb(` 与 `rgba(`、`hsl(` 与 `hsla(` 是同一套数值，只差末尾的 alpha
        let prefix = [name + "(", name + "a("].first { lowered.hasPrefix($0) }
        guard let prefix, lowered.hasSuffix(")") else { return nil }
        let inner = lowered.dropFirst(prefix.count).dropLast()
        // 逗号、空格、`/` 三种分隔方式在同一份 CSS 里都合法
        let parts = inner
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0.isWhitespace })
            .map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }

        if isHSL {
            guard let hue = parseHue(parts[0]),
                  let saturation = parsePercent(parts[1]),
                  let lightness = parsePercent(parts[2]) else { return nil }
            let rgb = hslToRGB(hue: hue, saturation: saturation, lightness: lightness)
            return hexString(red: rgb.0, green: rgb.1, blue: rgb.2)
        }
        guard let red = parseChannel(parts[0]),
              let green = parseChannel(parts[1]),
              let blue = parseChannel(parts[2]) else { return nil }
        return hexString(red: red, green: green, blue: blue)
    }

    /// `51` 或 `20%`，统一成 0…1。
    private static func parseChannel(_ text: String) -> Double? {
        if text.hasSuffix("%") {
            guard let value = Double(text.dropLast()), (0...100).contains(value) else { return nil }
            return value / 100
        }
        guard let value = Double(text), (0...255).contains(value) else { return nil }
        return value / 255
    }

    private static func parsePercent(_ text: String) -> Double? {
        guard text.hasSuffix("%"), let value = Double(text.dropLast()), (0...100).contains(value) else {
            return nil
        }
        return value / 100
    }

    /// 色相允许 `210`、`210deg`，按 360 取模。
    private static func parseHue(_ text: String) -> Double? {
        var body = text
        if body.hasSuffix("deg") { body.removeLast(3) }
        guard let value = Double(body), value.isFinite, value >= 0 else { return nil }
        return (value.truncatingRemainder(dividingBy: 360)) / 360
    }

    /// 标准 HSL→RGB，各分量 0…1。
    private static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
        guard saturation > 0 else { return (lightness, lightness, lightness) }
        let q = lightness < 0.5
            ? lightness * (1 + saturation)
            : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(hue + 1.0 / 3), channel(hue), channel(hue - 1.0 / 3))
    }

    private static func hexString(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

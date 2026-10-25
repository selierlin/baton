import AppKit

/// 工具条与属性条的配色。
///
/// Longshot 的条子是**跟随系统外观**的：浅色模式 `#E6E6E6` 底 + `#3C3C3C` 图标，
/// 深色模式才是 `#323232` 底 + `#DED4D4` 图标。之前这里把深色值写死了，
/// 于是在浅色系统下整条看起来就是一块黑板。
///
/// 全部用动态色，调用点照旧 `BarPalette.icon.setFill()`，不用感知外观。
enum BarPalette {
    /// 容器底色
    static let background = dynamic(light: 0xE6E6E6, dark: 0x323232)
    /// 容器描边。浅色下 Longshot 实际没有描边，这里留一条极淡的线，
    /// 免得属性条压在浅色截图上时糊成一片。
    static let border = dynamic(light: 0xD8D8D8, dark: 0x555555)
    /// 图标与文字
    static let icon = dynamic(light: 0x3C3C3C, dark: 0xDED4D4)
    /// 当前工具的底
    static let active = dynamic(light: 0xCBCBCB, dark: 0x505050)
    /// 悬停底
    static let hover = dynamic(light: 0xDCDCDC, dark: 0x3E3E3E)
    /// 分隔线（取图标色降透明度）
    static let separator = dynamic(light: 0x3C3C3C, dark: 0xDED4D4)
    /// 条里的控件底：滑杆槽、下拉框
    static let control = dynamic(light: 0xD2D2D2, dark: 0x4A4A4A)
    /// 属性条里更亮的控件底
    static let controlRaised = dynamic(light: 0xDCDCDC, dark: 0x5C5C5C)
    /// 反色文字（画在控件底上的数值）
    static let label = dynamic(light: 0x2E2E2E, dark: 0xE6E6E6)
    /// 滑杆圆钮
    static let knob = dynamic(light: 0xFFFFFF, dark: 0xE6E6E6)

    /// 当前绘制上下文是不是深色。不要在绘制之外拿它做判断。
    static var isDark: Bool {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? srgb(dark)
                : srgb(light)
        }
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

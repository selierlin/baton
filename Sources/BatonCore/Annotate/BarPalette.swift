import AppKit

/// 工具条与属性条的配色。
///
/// 数值全部取自 Longshot 实机截图取样（浅色 / 深色各一轮）：
/// 条底 `#EBEBEB` / `#414141`，图标 `#4D4D4D` / `#E2DCDB`，
/// 分段底 `#D8D8D8` / `#585858`，分段里选中的那一格是 `#FFFFFF` / `#858585`。
///
/// 全部用动态色，调用点照旧 `BarPalette.icon.setFill()`，不用感知外观。
enum BarPalette {
    /// 容器底色
    static let background = dynamic(light: 0xEBEBEB, dark: 0x414141)
    /// 容器描边：深色下 Longshot 是 1pt 纯黑，浅色下几乎看不见
    static let border = dynamic(light: 0xE0E0E0, dark: 0x000000)
    /// 图标与文字
    static let icon = dynamic(light: 0x4D4D4D, dark: 0xE2DCDB)
    /// 按下 / 悬停底（只有悬停和长截图这类二次确认在用）
    static let active = dynamic(light: 0xCBCBCB, dark: 0x505050)
    /// 悬停底
    static let hover = dynamic(light: 0xDFDFDF, dark: 0x4A4A4A)
    /// 竖分隔线（1pt，18pt 高）
    static let separator = dynamic(light: 0x4D4D4D, dark: 0xE2DCDB)
    /// 条里的控件底：滑杆槽
    static let control = dynamic(light: 0xE1E1E1, dark: 0x585858)
    /// 分段控件的槽、颜色胶囊的底
    static let controlRaised = dynamic(light: 0xD8D8D8, dark: 0x585858)
    /// 分段里选中的那一格：浅色下是白块，深色下比槽亮一级
    static let segmentedSelected = dynamic(light: 0xFFFFFF, dark: 0x858585)
    /// 分段格子之间的 1pt 刻度
    static let segmentDivider = dynamic(light: 0xC7C7C7, dark: 0x6B6B6B)
    /// 分段格里的小图标。Longshot 这几个图标是从 Assets.car 直接取的固定位图，
    /// 明暗都是黑的，没有跟着主题换色 —— 照抄，不然槽里的对比会反过来。
    static let chipIcon = NSColor.black
    /// 控件上的文字（下拉框标题、浮层说明）
    static let label = dynamic(light: 0x3C3C3C, dark: 0xE6E6E6)
    /// 滑杆圆钮
    static let knob = dynamic(light: 0xFFFFFF, dark: 0xA9A9A9)
    /// 选中态的高亮蓝，Longshot 用的不是系统强调色
    static let accent = srgb(0x4A9BF9)

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

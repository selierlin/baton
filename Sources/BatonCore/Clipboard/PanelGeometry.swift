import Foundation

/// 面板几何计算。抽屉展开后必须整个落在屏幕可用区域里：
/// 右边放不下就整体左移，屏幕太窄就把抽屉压窄，别把窗口顶出屏幕。
public enum PanelGeometry {
    /// 与屏幕边缘至少留这么多，否则窗口阴影贴着边会被裁掉、看起来像越界
    public static let margin: CGFloat = 24

    /// 展开后的目标宽度。屏幕够宽就是「列表 + 抽屉」；不够就压抽屉，列表宽度不变。
    public static func width(list: CGFloat, drawer: CGFloat, screen: CGRect) -> CGFloat {
        min(list + drawer, max(list, screen.width - margin * 2))
    }

    /// 展开后的左边距。优先让列表原地不动，右边放不下才左移；两边都放不下就贴左边。
    public static func originX(current: CGFloat, width: CGFloat, screen: CGRect) -> CGFloat {
        let left = screen.minX + margin
        let right = screen.maxX - margin - width
        guard right >= left else { return left }
        return min(max(current, left), right)
    }
}

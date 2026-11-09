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

    /// 呼出落点：保存过、且窗口中心还在这块屏上，就沿用；否则落在屏幕上沿居中。
    ///
    /// 判据用「中心是否在这块屏」而不是严格包含：用户可能故意把面板放到贴边，
    /// 收得太紧会导致每次呼出都被抢回默认位。双屏下保存位置属于另一块屏时，
    /// 落到当前屏的默认位，而不是把人拉回原来那块。
    public static func launchOrigin(saved: CGPoint?,
                                    size: CGSize,
                                    screen: CGRect,
                                    topInset: CGFloat = 80) -> CGPoint {
        if let saved,
           screen.contains(CGPoint(x: saved.x + size.width / 2, y: saved.y + size.height / 2)) {
            return clampedOrigin(saved, size: size, screen: screen)
        }
        return clampedOrigin(CGPoint(x: screen.midX - size.width / 2,
                                     y: screen.maxY - topInset - size.height),
                             size: size,
                             screen: screen)
    }

    /// 整个窗口收进可用区域：水平沿用 `originX` 的规则，垂直留出阴影边距。
    public static func clampedOrigin(_ point: CGPoint,
                                     size: CGSize,
                                     screen: CGRect) -> CGPoint {
        CGPoint(x: originX(current: point.x, width: size.width, screen: screen),
                y: min(max(point.y, screen.minY + margin), screen.maxY - margin - size.height))
    }
}

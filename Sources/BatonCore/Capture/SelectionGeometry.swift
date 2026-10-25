import CoreGraphics

/// 选区四周的控制点。名字里的 top/bottom 指**屏幕上的上/下**，
/// 也就是左上原点坐标里的 minY/maxY —— 作图时不用再想翻转。
public enum SelectionAnchor: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    public var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    public var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    public var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    public var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
}

/// 选区的四条边。`inset` 为正表示向外扩，为负表示向内收。
public enum SelectionEdge: CaseIterable, Sendable {
    case top, bottom, left, right
}

/// 选区的几何运算：只做算术，不碰视图、不碰鼠标事件。
///
/// 所有矩形都用**左上原点**（与 `CaptureSelection.globalRect`、画布视图一致）。
/// 视图是左下原点的地方（覆盖层宿主）由调用方翻转，别在这里混进来。
public enum SelectionGeometry {
    /// 选区最小边长（点）。再小就点不中，也没意义。
    public static let minSide: CGFloat = 2

    /// 手柄中心。
    public static func point(of anchor: SelectionAnchor, in rect: CGRect) -> CGPoint {
        let x: CGFloat
        if anchor.movesLeft { x = rect.minX }
        else if anchor.movesRight { x = rect.maxX }
        else { x = rect.midX }
        let y: CGFloat
        if anchor.movesTop { y = rect.minY }
        else if anchor.movesBottom { y = rect.maxY }
        else { y = rect.midY }
        return CGPoint(x: x, y: y)
    }

    /// 命中哪个手柄。角优先于边：四角与四边中点在 corner 附近会重叠，
    /// 用户瞄的是角的时候不该被判成边。
    public static func anchor(at location: CGPoint, in rect: CGRect,
                              tolerance: CGFloat) -> SelectionAnchor? {
        // 离选区太远直接不算，省得整屏都变成「手柄热区」
        let reach = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard reach.contains(location) else { return nil }
        for anchor in SelectionAnchor.allCases where anchor.isCorner {
            if distance(location, point(of: anchor, in: rect)) <= tolerance { return anchor }
        }
        for anchor in SelectionAnchor.allCases where !anchor.isCorner {
            if distance(location, point(of: anchor, in: rect)) <= tolerance { return anchor }
        }
        return nil
    }

    /// 拖某个手柄到 `point`：对边（或对角）保持不动。
    ///
    /// 两条约束同时生效：不越过 `limit`，且边长不小于 `minSide`。
    /// 先夹最小尺寸再夹边界，否则贴边时会被压成负宽度。
    public static func resized(_ rect: CGRect, anchor: SelectionAnchor,
                               to point: CGPoint, limit: CGRect) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY

        if anchor.movesLeft {
            minX = min(max(point.x, limit.minX), maxX - minSide)
        } else if anchor.movesRight {
            maxX = max(min(point.x, limit.maxX), minX + minSide)
        }
        if anchor.movesTop {
            minY = min(max(point.y, limit.minY), maxY - minSide)
        } else if anchor.movesBottom {
            maxY = max(min(point.y, limit.maxY), minY + minSide)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 整体平移：尺寸不变，整块夹在 `limit` 里。贴边时停住，不缩小。
    public static func moved(_ rect: CGRect, dx: CGFloat, dy: CGFloat, limit: CGRect) -> CGRect {
        var x = rect.minX + dx
        var y = rect.minY + dy
        if rect.width <= limit.width {
            x = min(max(x, limit.minX), limit.maxX - rect.width)
        }
        if rect.height <= limit.height {
            y = min(max(y, limit.minY), limit.maxY - rect.height)
        }
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// 单边外扩（`by` > 0）或收缩（`by` < 0）。收缩到 `minSide` 就停。
    public static func inset(_ rect: CGRect, edge: SelectionEdge,
                             by delta: CGFloat, limit: CGRect) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY

        switch edge {
        case .top:
            minY = max(min(minY - delta, maxY - minSide), limit.minY)
        case .bottom:
            maxY = min(max(maxY + delta, minY + minSide), limit.maxY)
        case .left:
            minX = max(min(minX - delta, maxX - minSide), limit.minX)
        case .right:
            maxX = min(max(maxX + delta, minX + minSide), limit.maxX)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 选区变了之后，标注的图片像素坐标该怎么跟着换。
    ///
    /// 标注存的是「裁剪图里的像素」，原点在各张裁剪图的左上角。选区原点一动，
    /// 同一块屏幕内容在新图里的像素坐标就整体平移了，图元必须补上这个位移，
    /// 否则会被当成还贴在**新图**左上角，看上去就是跟着选区一起跑。
    ///
    /// 传的是两张图的 `pixelRect`（同一块屏的像素坐标），不是屏幕矩形：
    /// `pixelRect` 的 origin 是向下取整的，用「点差 × 缩放」会在非整数位置漂 1px，
    /// 来回调几次就明显歪了。
    public static func imageOffset(from oldPixels: CGRect, to newPixels: CGRect) -> CGPoint {
        CGPoint(x: oldPixels.minX - newPixels.minX, y: oldPixels.minY - newPixels.minY)
    }

    /// 方向键 → 边。`command` 外扩、`shift` 收缩，两者都没有时返回 nil（那代表平移）。
    public static func edge(forKeyCode code: UInt16,
                            command: Bool, shift: Bool) -> SelectionEdge? {
        guard command != shift else { return nil }
        switch code {
        case 126: return .top
        case 125: return .bottom
        case 123: return .left
        case 124: return .right
        default: return nil
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

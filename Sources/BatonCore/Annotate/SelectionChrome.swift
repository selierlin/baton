import AppKit
import CoreGraphics

/// 选区四周的 8 个拖拽手柄。
///
/// 单独拎出来是因为它必须画在**覆盖层宿主**上，不能画在画布里：
/// 画布的 bounds 就是选区本身，手柄中心压着边界，画在内部会被裁掉朝外的一半。
public enum SelectionChrome {
    public static let handleSide: CGFloat = 6
    /// 手柄的捕捉半径（点）。方块本身只有 6pt，按住时手会抖，四周各留一圈余量，
    /// 实际热区是以手柄中心为圆心、直径 `reach * 2` 的圆。
    ///
    /// 画布的命中判断、画布的光标反查、宿主的外沿转交都用这一个数，
    /// 三处不一致的话手柄会「里面能抓、外面抓不到」。
    public static let reach: CGFloat = 10

    /// 工具条离选区边缘的间距。
    ///
    /// 必须大于 `reach`：手柄骑在边界上，热区会朝外伸 `reach`，
    /// 间距一旦比它小，贴边那几个手柄就会压到工具条上——
    /// 光标变成缩放箭头，点按钮那一下还可能被当成拖选区。
    /// 所以这里从 `reach` 推出来，改热区不会反过来把工具条顶掉。
    public static let toolbarGap: CGFloat = reach + 0.5

    /// 8 个方块（四角 + 四边中点，中心那格不画）。
    /// 用 min/mid/max 三列三行拼，不依赖 top/bottom 的语义，
    /// 所以在左下原点的宿主视图里也不会画反。
    public static func handles(in rect: CGRect) -> [CGRect] {
        var boxes: [CGRect] = []
        let xs = [rect.minX, rect.midX, rect.maxX]
        let ys = [rect.minY, rect.midY, rect.maxY]
        for x in xs {
            for y in ys where !(x == rect.midX && y == rect.midY) {
                boxes.append(CGRect(x: x - handleSide / 2, y: y - handleSide / 2,
                                    width: handleSide, height: handleSide))
            }
        }
        return boxes
    }

    public static func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        for box in handles(in: rect) { path.addRect(box) }
        return path
    }
}

extension SelectionAnchor {
    /// 拖这个手柄时的光标。
    ///
    /// 用系统的框体缩放光标（`NSCursor.frameResize`）：角上是斜向双箭头、边上是单向
    /// 双箭头，和「只能横向拖」区分得开。画布和覆盖层都要用，所以放在这里共用。
    @MainActor
    public var cursor: NSCursor { SelectionCursors.map[self] ?? .crosshair }
}

/// 光标实例缓存。`frameResize` 每调一次就新建一个对象，而光标是在
/// `mouseMoved` 里取的——不缓存等于每个鼠标事件都造一个。
@MainActor
private enum SelectionCursors {
    static let map: [SelectionAnchor: NSCursor] = Dictionary(
        uniqueKeysWithValues: SelectionAnchor.allCases.map {
            ($0, NSCursor.frameResize(position: $0.resizePosition, directions: .all))
        })
}

private extension SelectionAnchor {
    /// 手柄 → 系统「框体的哪个部位」。
    var resizePosition: NSCursor.FrameResizePosition {
        switch self {
        case .topLeft: return .topLeft
        case .top: return .top
        case .topRight: return .topRight
        case .right: return .right
        case .bottomRight: return .bottomRight
        case .bottom: return .bottom
        case .bottomLeft: return .bottomLeft
        case .left: return .left
        }
    }
}

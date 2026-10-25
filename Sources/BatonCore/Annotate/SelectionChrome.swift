import AppKit
import CoreGraphics

/// 选区四周的 8 个拖拽手柄。
///
/// 单独拎出来是因为它必须画在**覆盖层宿主**上，不能画在画布里：
/// 画布的 bounds 就是选区本身，手柄中心压着边界，画在内部会被裁掉朝外的一半。
public enum SelectionChrome {
    public static let handleSide: CGFloat = 6
    /// 手柄的捕捉半径（点）。方块本身只有 6pt，按住时手会抖，两侧各留一圈余量。
    /// 画布的命中判断和宿主的「外沿转交」必须用同一个数，否则内外手感不一致。
    public static let reach: CGFloat = 6

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

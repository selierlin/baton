import CoreGraphics

/// 选区四周的 8 个拖拽手柄。
///
/// 单独拎出来是因为它必须画在**覆盖层宿主**上，不能画在画布里：
/// 画布的 bounds 就是选区本身，手柄中心压着边界，画在内部会被裁掉朝外的一半。
public enum SelectionChrome {
    public static let handleSide: CGFloat = 6

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

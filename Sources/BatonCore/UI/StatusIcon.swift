import AppKit

/// 菜单栏图标。
///
/// 和 App 图标同一套造型：靛紫圆角方块 + 白棒 + 深色握柄。
/// 但不能直接把 1024 那张缩到 18pt——那张图里棒只占画布 5%，缩下来不到 1pt，
/// 握柄直接消失，只剩一根糊掉的细线。所以这里按状态栏尺寸重画一遍：
/// 比例照搬，笔画按像素加粗。
enum StatusIcon {
    private static let plate = NSColor(srgbRed: 91 / 255, green: 72 / 255, blue: 232 / 255, alpha: 1)
    private static let grip = NSColor(srgbRed: 38 / 255, green: 28 / 255, blue: 96 / 255, alpha: 1)

    static func baton() -> NSImage {
        let side: CGFloat = 18
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            plate.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 16, height: 16),
                         xRadius: 4.4, yRadius: 4.4).fill()

            let from = NSPoint(x: 5.0, y: 5.0)
            let to = NSPoint(x: 13.2, y: 13.2)

            // 握柄：比棒粗一圈，盖住棒的下端
            NSColor.white.setStroke()
            let gripPath = NSBezierPath()
            gripPath.move(to: from)
            gripPath.line(to: NSPoint(x: from.x + (to.x - from.x) * 0.30,
                                      y: from.y + (to.y - from.y) * 0.30))
            gripPath.lineWidth = 5.2
            gripPath.lineCapStyle = .round
            grip.setStroke()
            gripPath.stroke()

            let shaft = NSBezierPath()
            shaft.move(to: from)
            shaft.line(to: to)
            shaft.lineWidth = 2.9
            shaft.lineCapStyle = .round
            NSColor.white.setStroke()
            shaft.stroke()
            return true
        }
    }
}

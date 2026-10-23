import AppKit

/// Longshot 工具条图标。
///
/// 这些图标不是 SF Symbols —— 全部按 Longshot 的 18×18 网格原图重画，
/// 包括线宽、圆角、留白。用矢量重画而不是塞位图，是为了选中/禁用/深浅色
/// 都能直接换色，不会出现「白图标贴在浅底上」的问题。
enum LongshotGlyph {
    case square
    case ellipse
    case line
    case flatArrow
    case sinkArrow
    case mosaicSquare
    case mosaicEllipse
    case mosaicPencil
    case highlightSquare
    case highlightEllipse
    case highlightPencil
    case ruler
    case length
    case area
    case colorCircle
    case pencil
    case markerPen
    case textMark
    case labelText
    case counter
    case undo
    case redo
    case scrollcut
    case ocr
    case video
    case more
    case cancel
    case pin
    case open
    case download
    case copy
    case selector

    /// 工具条图标默认色。Longshot 用的是带一点暖调的浅灰，不是纯白。
    static let iconColor = NSColor(srgbRed: 222 / 255, green: 212 / 255, blue: 212 / 255, alpha: 1)

    /// 画到 `size` 见方的透明图里。`knockout` 用于序号「1」这种需要挖空的地方，
    /// 传 nil 时用目标背景色模拟。
    func image(size: CGFloat = 18,
               color: NSColor = LongshotGlyph.iconColor) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let scale = size / 18
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            Self.draw(self, color: color)
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - 绘制

    private static func draw(_ glyph: LongshotGlyph, color: NSColor) {
        color.setStroke()
        color.setFill()

        switch glyph {
        case .square:
            let path = NSBezierPath(roundedRect: NSRect(x: 2.6, y: 2.6, width: 12.8, height: 12.8),
                                    xRadius: 3.2, yRadius: 3.2)
            path.lineWidth = 1.5
            path.stroke()

        case .ellipse:
            let path = NSBezierPath(ovalIn: NSRect(x: 2.6, y: 2.6, width: 12.8, height: 12.8))
            path.lineWidth = 1.5
            path.stroke()

        case .line:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 3.6, y: 3.6))
            path.line(to: NSPoint(x: 14.4, y: 14.4))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.stroke()

        case .flatArrow:
            drawArrow(shaftEnd: NSPoint(x: 10.8, y: 10.8), color: color)

        case .sinkArrow:
            // 内凹箭头：尾端收成尖，杆由细到粗张成楔形，末端是底边内凹的三角头
            let tail = NSPoint(x: 2.6, y: 2.6)
            let tip = NSPoint(x: 15.4, y: 15.4)
            let ux: CGFloat = 0.70710678
            let uy: CGFloat = 0.70710678
            let nx: CGFloat = -0.70710678
            let ny: CGFloat = 0.70710678
            let headLength: CGFloat = 7.0
            let base = NSPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)
            let half: CGFloat = 4.4
            let notchDepth: CGFloat = 2.7
            let notch = NSPoint(x: base.x + ux * notchDepth, y: base.y + uy * notchDepth)
            let bodyHalf: CGFloat = 1.3
            // 尾端留一丝宽度，缩到 18pt 时尖点才不会被抗锯齿吃掉
            let tailPad: CGFloat = 0.22

            color.setFill()
            let body = NSBezierPath()
            body.move(to: NSPoint(x: tail.x + nx * tailPad, y: tail.y + ny * tailPad))
            body.line(to: NSPoint(x: notch.x + nx * bodyHalf, y: notch.y + ny * bodyHalf))
            body.line(to: NSPoint(x: notch.x - nx * bodyHalf, y: notch.y - ny * bodyHalf))
            body.line(to: NSPoint(x: tail.x - nx * tailPad, y: tail.y - ny * tailPad))
            body.close()
            body.fill()

            let head = NSBezierPath()
            head.move(to: tip)
            head.line(to: NSPoint(x: base.x + nx * half, y: base.y + ny * half))
            head.line(to: notch)
            head.line(to: NSPoint(x: base.x - nx * half, y: base.y - ny * half))
            head.close()
            head.fill()

        case .mosaicSquare:
            let outer = NSRect(x: 2.6, y: 2.6, width: 12.8, height: 12.8)
            drawGrid(in: outer, clippedTo: NSBezierPath(roundedRect: outer, xRadius: 3.0, yRadius: 3.0),
                     color: color)

        case .mosaicEllipse:
            let outer = NSRect(x: 2.6, y: 2.6, width: 12.8, height: 12.8)
            drawGrid(in: outer, clippedTo: NSBezierPath(ovalIn: outer), color: color)

        case .mosaicPencil:
            color.withAlphaComponent(0.55).setFill()
            let body = pencilBody()
            body.fill()
            color.setStroke()
            body.lineWidth = 1.2
            body.lineJoinStyle = .round
            body.stroke()
            // 分段线
            let dividers = NSBezierPath()
            for t in [CGFloat(0.34), 0.62] {
                let a = NSPoint(x: 3.6 + 11.0 * t - 2.4, y: 3.6 + 11.0 * t + 2.4)
                let b = NSPoint(x: 3.6 + 11.0 * t + 2.4, y: 3.6 + 11.0 * t - 2.4)
                dividers.move(to: a)
                dividers.line(to: b)
            }
            dividers.lineWidth = 1.1
            dividers.stroke()

        case .highlightSquare:
            let outer = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.5, width: 13.0, height: 13.0),
                                     xRadius: 3.2, yRadius: 3.2)
            let inner = NSBezierPath(roundedRect: NSRect(x: 5.6, y: 5.6, width: 6.8, height: 6.8),
                                     xRadius: 1.5, yRadius: 1.5)
            outer.append(inner)
            outer.windingRule = .evenOdd
            color.withAlphaComponent(0.85).setFill()
            outer.fill()

        case .highlightEllipse:
            let outer = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 13.0, height: 13.0))
            let inner = NSBezierPath(ovalIn: NSRect(x: 5.4, y: 5.4, width: 7.2, height: 7.2))
            outer.append(inner)
            outer.windingRule = .evenOdd
            color.withAlphaComponent(0.85).setFill()
            outer.fill()

        case .highlightPencil:
            color.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2.6, y: 2.6, width: 12.8, height: 12.8),
                         xRadius: 3.0, yRadius: 3.0).fill()
            // 内部签名画成挖空
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()
            ctx?.setBlendMode(.destinationOut)
            ctx?.translateBy(x: 9, y: 9)
            ctx?.scaleBy(x: 0.74, y: 0.74)
            ctx?.translateBy(x: -9, y: -9)
            NSColor.black.setStroke()
            scribblePath().stroke()
            ctx?.restoreGState()

        case .ruler:
            drawLetterA(in: NSRect(x: 2.2, y: 3.2, width: 5.8, height: 11.6), lineWidth: 1.2)
            let rect = NSRect(x: 9.4, y: 2.6, width: 5.6, height: 12.8)
            let path = NSBezierPath(roundedRect: rect, xRadius: 0.7, yRadius: 0.7)
            path.lineWidth = 1.25
            path.stroke()
            let ticks = NSBezierPath()
            for y in [CGFloat(5.4), 7.9, 10.4, 12.9] {
                ticks.move(to: NSPoint(x: rect.minX, y: y))
                ticks.line(to: NSPoint(x: rect.minX + 3.0, y: y))
            }
            ticks.lineWidth = 1.2
            ticks.stroke()

        case .length:
            let rect = NSRect(x: 4.6, y: 2.6, width: 8.8, height: 12.8)
            let path = NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8)
            path.lineWidth = 1.3
            path.stroke()
            let ticks = NSBezierPath()
            for y in [CGFloat(5.8), 8.2, 10.6, 13.0] {
                ticks.move(to: NSPoint(x: rect.minX, y: y))
                ticks.line(to: NSPoint(x: rect.minX + 4.4, y: y))
            }
            ticks.lineWidth = 1.3
            ticks.stroke()

        case .area:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 9, y: 15.6)); path.line(to: NSPoint(x: 9, y: 12.2))
            path.move(to: NSPoint(x: 9, y: 2.4)); path.line(to: NSPoint(x: 9, y: 5.8))
            path.move(to: NSPoint(x: 2.4, y: 9)); path.line(to: NSPoint(x: 5.8, y: 9))
            path.move(to: NSPoint(x: 12.2, y: 9)); path.line(to: NSPoint(x: 15.6, y: 9))
            path.lineWidth = 2.2
            path.lineCapStyle = .round
            path.stroke()

        case .colorCircle:
            NSBezierPath(ovalIn: NSRect(x: 3.4, y: 3.4, width: 11.2, height: 11.2)).fill()

        case .pencil:
            color.setStroke()
            let path = scribblePath()
            path.stroke()

        case .markerPen:
            // 粗弧，开口朝右：Longshot 的圆头马克笔
            let path = NSBezierPath()
            let center = NSPoint(x: 10.4, y: 9.0)
            path.appendArc(withCenter: center, radius: 5.2,
                           startAngle: 58, endAngle: 302, clockwise: false)
            path.lineWidth = 4.4
            path.lineCapStyle = .butt
            path.stroke()

        case .textMark:
            drawLetterA(in: NSRect(x: 2.6, y: 2.6, width: 12.8, height: 12.8), lineWidth: 1.5)

        case .labelText:
            let bubble = NSBezierPath(roundedRect: NSRect(x: 2.4, y: 5.0, width: 13.2, height: 10.4),
                                      xRadius: 3.0, yRadius: 3.0)
            bubble.move(to: NSPoint(x: 5.4, y: 5.2))
            bubble.line(to: NSPoint(x: 5.4, y: 2.2))
            bubble.line(to: NSPoint(x: 8.2, y: 5.2))
            bubble.lineWidth = 1.4
            bubble.lineJoinStyle = .round
            bubble.stroke()
            drawLetterA(in: NSRect(x: 5.6, y: 6.2, width: 7.0, height: 8.4), lineWidth: 1.2)

        case .counter:
            let ring = NSBezierPath(ovalIn: NSRect(x: 2.4, y: 2.4, width: 13.2, height: 13.2))
            color.withAlphaComponent(0.42).setFill()
            ring.fill()
            color.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
            drawCounterNumber()

        case .undo:
            drawUndo(mirrored: false, color: color)

        case .redo:
            drawUndo(mirrored: true, color: color)

        case .scrollcut:
            // 一页纸：右上角切掉（卷角），底部压一条实心的「截取」条
            let page = NSBezierPath()
            page.move(to: NSPoint(x: 3.0, y: 3.2))
            page.line(to: NSPoint(x: 3.0, y: 15.2))
            page.line(to: NSPoint(x: 11.0, y: 15.2))
            page.line(to: NSPoint(x: 15.0, y: 11.2))
            page.line(to: NSPoint(x: 15.0, y: 3.2))
            page.close()
            page.lineWidth = 1.45
            page.lineJoinStyle = .round
            page.stroke()

            let lines = NSBezierPath()
            for y in [CGFloat(12.0), 9.8] {
                lines.move(to: NSPoint(x: 5.4, y: y))
                lines.line(to: NSPoint(x: 9.2, y: y))
            }
            lines.lineWidth = 1.4
            lines.lineCapStyle = .round
            lines.stroke()

            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 6.2, y: 4.0, width: 9.4, height: 3.0),
                         xRadius: 1.0, yRadius: 1.0).fill()

        case .ocr:
            let corners = NSBezierPath()
            let inset: CGFloat = 2.6, arm: CGFloat = 3.4, r: CGFloat = 1.4
            for (cx, cy, sx, sy) in [(inset, inset, 1.0, 1.0),
                                     (18 - inset, inset, -1.0, 1.0),
                                     (inset, 18 - inset, 1.0, -1.0),
                                     (18 - inset, 18 - inset, -1.0, -1.0)] {
                let corner = NSBezierPath()
                corner.move(to: NSPoint(x: cx + sx * arm, y: cy))
                corner.line(to: NSPoint(x: cx + sx * r, y: cy))
                corner.curve(to: NSPoint(x: cx, y: cy + sy * r),
                             controlPoint1: NSPoint(x: cx + sx * r, y: cy),
                             controlPoint2: NSPoint(x: cx, y: cy + sy * r))
                corner.line(to: NSPoint(x: cx, y: cy + sy * arm))
                corners.append(corner)
            }
            corners.lineWidth = 1.5
            corners.lineCapStyle = .round
            corners.stroke()
            let lines = NSBezierPath()
            for (y, w) in [(CGFloat(11.5), CGFloat(9.0)), (9.0, 9.0), (6.5, 5.6)] {
                lines.move(to: NSPoint(x: 9 - w / 2, y: y))
                lines.line(to: NSPoint(x: 9 + w / 2, y: y))
            }
            lines.lineWidth = 1.5
            lines.lineCapStyle = .round
            lines.stroke()

        case .video:
            let body = NSBezierPath(roundedRect: NSRect(x: 2.0, y: 5.0, width: 10.4, height: 8.0),
                                    xRadius: 2.0, yRadius: 2.0)
            body.lineWidth = 1.5
            body.stroke()
            let lens = NSBezierPath()
            lens.move(to: NSPoint(x: 12.9, y: 8.3))
            lens.line(to: NSPoint(x: 16.0, y: 6.3))
            lens.line(to: NSPoint(x: 16.0, y: 11.7))
            lens.line(to: NSPoint(x: 12.9, y: 9.7))
            lens.close()
            lens.lineWidth = 1.5
            lens.lineJoinStyle = .round
            lens.stroke()

        case .more:
            for x in [CGFloat(4.4), 9.0, 13.6] {
                NSBezierPath(ovalIn: NSRect(x: x - 1.35, y: 7.65, width: 2.7, height: 2.7)).fill()
            }

        case .cancel:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 3.9, y: 3.9))
            path.line(to: NSPoint(x: 14.1, y: 14.1))
            path.move(to: NSPoint(x: 14.1, y: 3.9))
            path.line(to: NSPoint(x: 3.9, y: 14.1))
            path.lineWidth = 2.4
            path.lineCapStyle = .round
            path.stroke()

        case .pin:
            drawPin(color: color)

        case .open:
            let box = NSBezierPath(roundedRect: NSRect(x: 2.6, y: 2.9, width: 9.4, height: 12.2),
                                   xRadius: 1.8, yRadius: 1.8)
            box.lineWidth = 1.5
            box.stroke()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 8.0, y: 9))
            arrow.line(to: NSPoint(x: 15.2, y: 9))
            arrow.move(to: NSPoint(x: 12.0, y: 6.0))
            arrow.line(to: NSPoint(x: 15.2, y: 9))
            arrow.line(to: NSPoint(x: 12.0, y: 12.0))
            arrow.lineWidth = 1.5
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()

        case .download:
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 9, y: 15.2))
            arrow.line(to: NSPoint(x: 9, y: 5.6))
            arrow.move(to: NSPoint(x: 5.4, y: 9.0))
            arrow.line(to: NSPoint(x: 9, y: 5.4))
            arrow.line(to: NSPoint(x: 12.6, y: 9.0))
            arrow.lineWidth = 1.5
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            let base = NSBezierPath()
            base.move(to: NSPoint(x: 4.2, y: 2.8))
            base.line(to: NSPoint(x: 13.8, y: 2.8))
            base.lineWidth = 1.5
            base.lineCapStyle = .round
            base.stroke()

        case .copy:
            // 两张描边的圆角纸，前一张压在后一张的右下角
            let back = NSBezierPath(roundedRect: NSRect(x: 3.0, y: 6.6, width: 9.4, height: 8.8),
                                    xRadius: 1.7, yRadius: 1.7)
            back.lineWidth = 1.45
            back.stroke()

            let front = NSBezierPath(roundedRect: NSRect(x: 6.0, y: 2.6, width: 9.4, height: 8.8),
                                     xRadius: 1.7, yRadius: 1.7)
            // 先把前一张的内部挖掉，后一张的边线才不会穿过去
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()
            ctx?.setBlendMode(.destinationOut)
            NSColor.black.setFill()
            front.fill()
            ctx?.restoreGState()

            front.lineWidth = 1.45
            front.stroke()

        case .selector:
            // 鼠标指针：一个带尾巴的箭头
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 4.2, y: 15.6))
            path.line(to: NSPoint(x: 4.2, y: 4.0))
            path.line(to: NSPoint(x: 7.9, y: 7.6))
            path.line(to: NSPoint(x: 10.4, y: 2.8))
            path.line(to: NSPoint(x: 12.4, y: 3.8))
            path.line(to: NSPoint(x: 9.9, y: 8.5))
            path.line(to: NSPoint(x: 14.8, y: 8.5))
            path.close()
            path.lineWidth = 1.4
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    // MARK: - 局部图形

    private static func drawArrow(shaftEnd: NSPoint, color: NSColor) {
        let shaft = NSBezierPath()
        shaft.move(to: NSPoint(x: 3.0, y: 3.0))
        shaft.line(to: shaftEnd)
        shaft.lineWidth = 1.5
        shaft.lineCapStyle = .round
        shaft.stroke()

        let tip = NSPoint(x: 15.4, y: 15.4)
        let dx: CGFloat = tip.x - shaftEnd.x, dy: CGFloat = tip.y - shaftEnd.y
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux
        let half: CGFloat = 3.1
        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: NSPoint(x: shaftEnd.x + nx * half, y: shaftEnd.y + ny * half))
        head.line(to: NSPoint(x: shaftEnd.x - nx * half, y: shaftEnd.y - ny * half))
        head.close()
        color.setFill()
        head.fill()
    }

    private static func drawGrid(in rect: NSRect, clippedTo clip: NSBezierPath,
                                 color: NSColor) {
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        clip.addClip()

        // 3×3 的小方块，块间留 0.7 的缝——原图是「九宫格」而不是网格线
        let inner = rect.insetBy(dx: 1.9, dy: 1.9)
        let gap: CGFloat = 0.75
        let cell = (inner.width - gap * 2) / 3
        color.setFill()
        for row in 0..<3 {
            for col in 0..<3 {
                let box = NSRect(x: inner.minX + CGFloat(col) * (cell + gap),
                                 y: inner.minY + CGFloat(row) * (cell + gap),
                                 width: cell, height: cell)
                NSBezierPath(roundedRect: box, xRadius: 0.7, yRadius: 0.7).fill()
            }
        }
        ctx?.restoreGState()

        color.setStroke()
        clip.lineWidth = 1.3
        clip.stroke()
    }

    private static func pencilBody() -> NSBezierPath {
        // 沿 45° 的一支铅笔：笔身 + 削尖的笔头
        let start = NSPoint(x: 2.6, y: 2.6)
        let end = NSPoint(x: 13.4, y: 13.4)
        let ux: CGFloat = 0.7071, uy: CGFloat = 0.7071
        let nx: CGFloat = -0.7071, ny: CGFloat = 0.7071
        let half: CGFloat = 2.9

        let p1 = NSPoint(x: start.x + nx * half, y: start.y + ny * half)
        let p2 = NSPoint(x: end.x + nx * half, y: end.y + ny * half)
        let p3 = NSPoint(x: end.x + ux * 1.6, y: end.y + uy * 1.6)
        let p4 = NSPoint(x: end.x + ux * 3.2, y: end.y + uy * 3.2)
        let p5 = NSPoint(x: end.x - nx * half, y: end.y - ny * half)
        let p6 = NSPoint(x: start.x - nx * half, y: start.y - ny * half)

        let path = NSBezierPath()
        path.move(to: p1)
        path.line(to: p2)
        path.line(to: p3)
        path.line(to: p4)
        path.line(to: p5)
        path.line(to: p6)
        path.close()
        return path
    }

    /// 手写体的「l n」：一个高瘦的环，右边接一个小 n。Longshot 的画笔图标。
    private static func scribblePath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 3.8, y: 3.6))
        path.curve(to: NSPoint(x: 8.9, y: 13.4),
                   controlPoint1: NSPoint(x: 6.2, y: 6.0),
                   controlPoint2: NSPoint(x: 7.6, y: 11.0))
        path.curve(to: NSPoint(x: 10.1, y: 14.9),
                   controlPoint1: NSPoint(x: 9.6, y: 14.0),
                   controlPoint2: NSPoint(x: 10.0, y: 14.9))
        path.curve(to: NSPoint(x: 6.9, y: 5.6),
                   controlPoint1: NSPoint(x: 10.2, y: 12.4),
                   controlPoint2: NSPoint(x: 8.3, y: 8.2))
        path.curve(to: NSPoint(x: 8.4, y: 4.4),
                   controlPoint1: NSPoint(x: 5.7, y: 3.4),
                   controlPoint2: NSPoint(x: 7.0, y: 3.1))
        path.curve(to: NSPoint(x: 10.6, y: 8.0),
                   controlPoint1: NSPoint(x: 9.6, y: 5.4),
                   controlPoint2: NSPoint(x: 9.8, y: 7.0))
        path.curve(to: NSPoint(x: 12.2, y: 4.8),
                   controlPoint1: NSPoint(x: 11.4, y: 9.0),
                   controlPoint2: NSPoint(x: 12.4, y: 6.8))
        path.curve(to: NSPoint(x: 14.6, y: 5.2),
                   controlPoint1: NSPoint(x: 11.8, y: 3.2),
                   controlPoint2: NSPoint(x: 13.6, y: 3.7))
        path.lineWidth = 1.75
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    private static func drawLetterA(in rect: NSRect, lineWidth: CGFloat) {
        let path = NSBezierPath()
        let apex = NSPoint(x: rect.midX, y: rect.maxY)
        let left = NSPoint(x: rect.minX, y: rect.minY)
        let right = NSPoint(x: rect.maxX, y: rect.minY)
        path.move(to: left)
        path.line(to: apex)
        path.line(to: right)
        let crossY = rect.minY + rect.height * 0.36
        let t = (crossY - rect.minY) / rect.height
        path.move(to: NSPoint(x: rect.minX + rect.width * t, y: crossY))
        path.line(to: NSPoint(x: rect.maxX - rect.width * t, y: crossY))
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func drawCounterNumber() {
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.setBlendMode(.destinationOut)
        NSColor.black.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 7.2, y: 12.2))
        path.line(to: NSPoint(x: 9.2, y: 14.0))
        path.line(to: NSPoint(x: 9.2, y: 3.6))
        path.lineWidth = 1.9
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
        ctx?.restoreGState()
    }

    private static func drawUndo(mirrored: Bool, color: NSColor) {
        let ctx = NSGraphicsContext.current!
        ctx.cgContext.saveGState()
        if mirrored {
            ctx.cgContext.translateBy(x: 18, y: 0)
            ctx.cgContext.scaleBy(x: -1, y: 1)
        }

        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: 9.4, y: 9.4), radius: 5.9,
                      startAngle: 140, endAngle: -150, clockwise: true)
        arc.lineWidth = 1.65
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()

        // 末端的实心三角，沿切线方向
        let angle = -150.0 * Double.pi / 180
        let end = NSPoint(x: 9.4 + 5.9 * cos(angle), y: 9.4 + 5.9 * sin(angle))
        let tx = sin(angle), ty = -cos(angle)
        let nx = -ty, ny = tx
        let headLength: CGFloat = 4.4, half: CGFloat = 2.3
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: NSPoint(x: end.x - tx * headLength + nx * half,
                              y: end.y - ty * headLength + ny * half))
        head.line(to: NSPoint(x: end.x - tx * headLength - nx * half,
                              y: end.y - ty * headLength - ny * half))
        head.close()
        color.setFill()
        head.fill()

        ctx.cgContext.restoreGState()
    }

    /// 图钉：45° 的菱形钉帽 + 向左下收尖的针，别画成「放大镜」。
    private static func drawPin(color: NSColor) {
        // 菱形帽（四角略圆）
        let top = NSPoint(x: 10.4, y: 15.9)
        let right = NSPoint(x: 15.7, y: 10.7)
        let bottom = NSPoint(x: 10.4, y: 5.5)
        let left = NSPoint(x: 5.1, y: 10.7)
        let head = NSBezierPath()
        head.move(to: top)
        head.line(to: right)
        head.line(to: bottom)
        head.line(to: left)
        head.close()
        head.lineWidth = 1.55
        head.lineJoinStyle = .round
        head.stroke()

        // 针：从帽底收成尖，针尖朝左下
        let tip = NSPoint(x: 1.3, y: 0.9)
        let needle = NSBezierPath()
        needle.move(to: tip)
        needle.line(to: NSPoint(x: 9.2, y: 4.6))
        needle.line(to: NSPoint(x: 7.4, y: 6.8))
        needle.close()
        color.setFill()
        needle.fill()
    }
}

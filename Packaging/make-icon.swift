#!/usr/bin/env swift
// 生成 Baton 的 App 图标（1024×1024 PNG）。
//
// 用法：swift Packaging/make-icon.swift [输出路径]
//
// 版式参考 Big Sur 之后的系统图标：底是接近纯色的高饱和色块（只留极淡的上下明暗），
// 主体符号尽量大、粗、带柔和投影，在 Dock 里一眼能认出轮廓。
// 用代码画而不是留一张位图，是为了以后改配色/角度能直接重跑。

import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Packaging/AppIcon-1024.png"

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("无法创建位图上下文\n".utf8))
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let full = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
full.fill()

// Big Sur 规格：824 的圆角方形居中，四周各留 100
let inset: CGFloat = 100
let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
squircle.addClip()

let w = body.width
let h = body.height

// 底：几乎是纯色的靛紫，只在上沿提亮、下沿压暗，别做明显的渐变
rgb(91, 72, 232).setFill()
body.fill()
NSGradient(starting: rgb(255, 255, 255, 0.14), ending: rgb(255, 255, 255, 0))!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: w, height: h / 2), angle: -90)
NSGradient(starting: rgb(0, 0, 0, 0.12), ending: rgb(0, 0, 0, 0))!
    .draw(in: NSRect(x: body.minX, y: body.minY, width: w, height: h * 0.30), angle: 90)

// 径向光晕：光源在左上，底色才有厚度。纯平的一整块色在深色壁纸上会显得廉价
if let glow = NSGradient(colors: [rgb(255, 255, 255, 0.20), rgb(255, 255, 255, 0)]) {
    glow.draw(fromCenter: NSPoint(x: body.minX + 0.34 * w, y: body.minY + 0.72 * h),
              radius: 0,
              toCenter: NSPoint(x: body.minX + 0.34 * w, y: body.minY + 0.72 * h),
              radius: 0.72 * w,
              options: [])
}

// 指挥棒：左下（手柄）到右上（尖端）。占满对角线，粗到缩成 16px 也是一根棒
let handle = NSPoint(x: body.minX + 0.26 * w, y: body.minY + 0.24 * h)
let tip = NSPoint(x: body.minX + 0.74 * w, y: body.minY + 0.76 * h)

let dx = tip.x - handle.x
let dy = tip.y - handle.y
let length = (dx * dx + dy * dy).squareRoot()
let nx = -dy / length
let ny = dx / length

// 棒身等宽、两端圆头。锥形会让它读成一根针，等宽的胶囊才有「棒」的量感。
// 用旋转坐标系画一个圆角矩形，而不是拼接多边形 + 两个圆：拼接时子路径绕向不一致，
// addClip 会把圆帽挖成半圆缺口
let half: CGFloat = 22
let center = NSPoint(x: (handle.x + tip.x) / 2, y: (handle.y + tip.y) / 2)
let angle = atan2(dy, dx)

let capsule = NSBezierPath(roundedRect: NSRect(x: -length / 2, y: -half,
                                               width: length, height: half * 2),
                           xRadius: half, yRadius: half)
var toStick = AffineTransform(translationByX: center.x, byY: center.y)
toStick.rotate(byRadians: angle)
capsule.transform(using: toStick)

// 柔光晕：各方向均匀，不用带方向的投影——带偏移的阴影在斜棒上容易看成第二根棒
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = rgb(14, 4, 52, 0.5)
shadow.shadowBlurRadius = 52
shadow.shadowOffset = .zero
shadow.set()
rgb(255, 255, 255).setFill()
capsule.fill()
NSGraphicsContext.restoreGraphicsState()

// 垂直于棒的渐变（白 → 浅蓝灰），让棒身有圆柱的转折而不是一块死白
NSGraphicsContext.saveGraphicsState()
capsule.addClip()
NSGradient(starting: rgb(255, 255, 255), ending: rgb(208, 214, 244))!
    .draw(in: capsule.bounds, angle: 135)
NSGraphicsContext.restoreGraphicsState()

// 左上侧一道细高光。两端都离棒的圆头远一点，否则圆头外会冒出一个白点
let shineFrom = 0.18
let shineTo = 0.76
let shine = NSBezierPath()
shine.move(to: NSPoint(x: handle.x + dx * shineFrom + nx * half * 0.42,
                       y: handle.y + dy * shineFrom + ny * half * 0.42))
shine.line(to: NSPoint(x: handle.x + dx * shineTo + nx * half * 0.42,
                       y: handle.y + dy * shineTo + ny * half * 0.42))
// 高光压低到 0.32：白棒本身已经接近纯白，再叠一道 0.85 的白线，
// 放大看就是一道突兀的「折痕」而不是反光
shine.lineWidth = 6
shine.lineCapStyle = .round
rgb(255, 255, 255, 0.32).setStroke()
shine.stroke()


// 握柄：棒下端的一段同轴深色圆柱。没有它，白棒读作棉签；
// 有了它，同一条白线才被读成「工具」
let gripLen = 0.20 * length
let gripHalf = half * 1.26
let grip = NSBezierPath(roundedRect: NSRect(x: -gripLen / 2, y: -gripHalf,
                                            width: gripLen, height: gripHalf * 2),
                        xRadius: gripHalf, yRadius: gripHalf)
// 沿棒方向的单位向量：dx/dy 是分量不是单位向量，直接乘长度会飞出画布
let ux = dx / length, uy = dy / length
// 起点压到棒的圆头之外一点：收在 0.45 处会把白圆头露一条边，
// 看着像握柄和棒之间夹了一道白缝
let gripCenter = NSPoint(x: handle.x + ux * (gripLen / 2 - half * 1.02),
                         y: handle.y + uy * (gripLen / 2 - half * 1.02))
var gripT = AffineTransform(translationByX: gripCenter.x, byY: gripCenter.y)
gripT.rotate(byRadians: angle)
grip.transform(using: gripT)

NSGraphicsContext.saveGraphicsState()
let gs = NSShadow()
gs.shadowColor = rgb(10, 2, 42, 0.45)
gs.shadowBlurRadius = 34
gs.shadowOffset = .zero
gs.set()
rgb(38, 28, 96).setFill()
grip.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
grip.addClip()
NSGradient(starting: rgb(104, 88, 190), ending: rgb(34, 24, 88))!
    .draw(in: grip.bounds, angle: 135)
NSGraphicsContext.restoreGraphicsState()

// 内描边：浅色背景上也能看清圆角边界
squircle.lineWidth = 3
rgb(255, 255, 255, 0.12).setStroke()
squircle.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}
let url = URL(fileURLWithPath: output)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
do {
    try png.write(to: url)
    print("wrote \(url.path)")
} catch {
    FileHandle.standardError.write(Data("写入失败：\(error)\n".utf8))
    exit(1)
}

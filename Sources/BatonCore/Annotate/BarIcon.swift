import AppKit

/// 工具条图标资源。
///
/// 形状取自 Longshot 的 `Assets.car`（`bar_*` 系列）。提取时把每个图标
/// 压成「纯黑 + 原始 alpha」的模板位图，绘制时再按当前配色填充——
/// 这样形状是原厂的，颜色仍归 Baton 管，能跟着明暗外观走。
///
/// 不走 `isTemplate = true`：Baton 是在自定义 `draw(_:)` 里画图标，
/// template 只有 `NSImageView` 会自动染色，这里必须自己合成。
enum BarIcon {
    /// 原图 pt 尺寸从 14 到 22 不等，统一按这个基准缩放，
    /// 才能保住它们彼此的大小关系（小图标就该显小）。
    /// 取 18 是因为主流图标本来就是 18pt 网格，正好铺满按钮。
    private static let baseSize: CGFloat = 18

    /// 找不到资源返回 nil，调用方回退到 `LongshotGlyph` 的手绘版本。
    static func image(asset: String, size: CGFloat, color: NSColor) -> NSImage? {
        guard let mask = maskImage(asset) else { return nil }

        var drawW = CGFloat(mask.width) / 2 * (size / baseSize)
        var drawH = CGFloat(mask.height) / 2 * (size / baseSize)
        let overflow = max(drawW, drawH) / size
        if overflow > 1 {
            drawW /= overflow
            drawH /= overflow
        }

        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let rect = CGRect(x: (size - drawW) / 2, y: (size - drawH) / 2,
                              width: drawW, height: drawH)
            // 先按原样画出黑色轮廓，再用 sourceIn 把 RGB 换成目标色、保住 alpha
            ctx.draw(mask, in: rect)
            ctx.saveGState()
            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()
            return true
        }
    }

    /// 资源只有 @2x 一份：`Bundle.url(forResource:)` 不会自动补 scale 后缀，
    /// 名字必须写全。省掉 @1x 是因为图标尺寸固定 18pt，2x 降采样在任何屏上都够清晰。
    private static func maskImage(_ asset: String) -> CGImage? {
        let bundle = resourceBundle ?? Bundle.module
        guard let url = bundle.url(forResource: "\(asset)@2x", withExtension: "png",
                                   subdirectory: "BarIcons"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// SwiftPM 的 `Bundle.module` 只认 `Baton.app/Baton_BatonCore.bundle`（app 根目录），
    /// 而 `make-app.sh` 是把 bundle 装进 `Contents/Resources`——那是规范位置，也让
    /// 签名检查干净。所以这里自己按顺序找，且必须验过「真能取到图标」才算数：
    /// `Bundle(url:)` 对着一个同名目录也会返回非 nil，光判断不加验证会踩空。
    private static let resourceBundle: Bundle? = {
        let main = Bundle.main
        var candidates: [URL] = []
        if let url = main.url(forResource: "Baton_BatonCore", withExtension: "bundle") {
            candidates.append(url)
        }
        candidates.append(main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Baton_BatonCore.bundle"))
        candidates.append(main.bundleURL.appendingPathComponent("Baton_BatonCore.bundle"))

        for url in candidates {
            guard let bundle = Bundle(url: url),
                  bundle.url(forResource: "bar_pin@2x", withExtension: "png",
                             subdirectory: "BarIcons") != nil else { continue }
            return bundle
        }
        return nil
    }()
}

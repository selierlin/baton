import CoreGraphics

/// 给截图套一圈 macOS 窗口式的外阴影。
///
/// 阴影要露在图像外面，所以画布按四周留白扩出去，四角透明——直接画在图像边界上
/// 的话，阴影会被裁掉一半，看起来像描了一圈灰边。幅度按「点」算再乘 scale，
/// Retina 截图和 1x 截图看起来才是同一种阴影，调用方要给出截图的像素倍率。
public enum CaptureDecorator {
    /// 阴影参数（像素）。拆出来是为了测试能断言，不用去解位图。
    public struct Metrics: Equatable, Sendable {
        public let blur: CGFloat
        /// 正值表示向下（素材来自屏幕，光从上方来）。
        public let offsetY: CGFloat
        /// 图像四周的透明留白。
        public let margin: CGFloat
    }

    /// 参考 macOS 窗口阴影：不透明度 0.45，模糊半径大约短边的 5%。
    private static let shadowAlpha: CGFloat = 0.45

    public static func metrics(for image: CGImage, scale: CGFloat) -> Metrics {
        let factor = max(scale, 1)
        let shortSide = CGFloat(min(image.width, image.height)) / factor
        let blurPoints = min(max(shortSide * 0.05, 10), 40)
        let blur = blurPoints * factor
        let offset = (blurPoints * 0.35 * factor).rounded()
        // 留白必须吃得下「模糊半径 + 向下的偏移」，否则阴影会被画布边缘切掉
        let margin = (blur * 1.4 + offset).rounded(.up)
        return Metrics(blur: blur, offsetY: offset, margin: margin)
    }

    /// 透明画布 + 阴影。复制到剪贴板、存 PNG 用这个。
    public static func shadowed(_ image: CGImage, scale: CGFloat) -> CGImage? {
        draw(image, scale: scale, background: nil)
    }

    /// 白底 + 阴影。JPEG / HEIC 没有 alpha 通道，透明边会被编码成黑边。
    public static func shadowedOnWhite(_ image: CGImage, scale: CGFloat) -> CGImage? {
        draw(image, scale: scale, background: 1)
    }

    private static func draw(_ image: CGImage, scale: CGFloat, background: CGFloat?) -> CGImage? {
        let metrics = metrics(for: image, scale: scale)
        let margin = Int(metrics.margin)
        let width = image.width + margin * 2
        let height = image.height + margin * 2
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        if let background {
            context.setFillColor(CGColor(gray: background, alpha: 1))
            context.fill(canvas)
        }

        context.setShadow(offset: CGSize(width: 0, height: -metrics.offsetY),
                          blur: metrics.blur,
                          color: CGColor(gray: 0, alpha: shadowAlpha))
        context.draw(image, in: CGRect(x: CGFloat(margin),
                                       y: CGFloat(margin),
                                       width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
        return context.makeImage()
    }
}

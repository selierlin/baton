import CoreGraphics
import Foundation
import ImageIO

/// 贴图的位图来源。
///
/// 贴图只在窗口里显示，按窗口实际像素重采样就够了——没必要为每张钉住的图
/// 常驻一份全分辨率位图（本机一张 2880×1800 就是 19.8 MB）。所以：
///
/// - 刚钉上时原图在内存里（截图流程本来就有），显示位图从它降采样；
/// - 落库之后原图就可以丢弃，之后显示改走 `CGImageSource` 的子采样解码，
///   解码出来的直接就是目标尺寸，不会先把整张图摊开；
/// - 需要原图（复制、另存、再落库）时才从文件重新解出来。
public final class PinImageSource: @unchecked Sendable {
    public let pixelSize: CGSize

    private let lock = NSLock()
    private var original: CGImage?
    private let fileURL: URL?
    /// 只缓存当前尺寸：缩放时桶会跳几次，换桶才重新解码。
    private var cached: (bucket: Int, image: CGImage)?

    /// 新钉的图：手上已有全分辨率位图。
    public init(image: CGImage) {
        self.pixelSize = CGSize(width: image.width, height: image.height)
        self.original = image
        self.fileURL = nil
    }

    /// 恢复的贴图：只有 blob 文件和记录里的像素尺寸。
    public init(pixelSize: CGSize, fileURL: URL?) {
        self.pixelSize = pixelSize
        self.original = nil
        self.fileURL = fileURL
    }

    /// 落库成功后调用：内存里的原图没有留下的理由了。
    public func releaseOriginal() {
        lock.lock()
        original = nil
        lock.unlock()
    }

    /// 显示用位图，长边不超过 `maxPixel`。
    ///
    /// 桶按 256 取整，连续缩放时多数事件都能命中缓存，不会一帧解一次。
    public func display(maxPixel: Int) -> CGImage? {
        let bucket = max(64, ((maxPixel + 255) / 256) * 256)

        lock.lock()
        if let cached, cached.bucket == bucket {
            lock.unlock()
            return cached.image
        }
        let source = original
        lock.unlock()

        let image: CGImage?
        if let source {
            image = Self.downsample(source, maxPixel: bucket)
        } else if let fileURL {
            image = Self.subsampled(fileURL, maxPixel: bucket)
        } else {
            image = nil
        }

        if let image {
            lock.lock()
            cached = (bucket, image)
            lock.unlock()
        }
        return image
    }

    /// 原图。复制、另存这类要像素级一致的场合才用。
    public func full() -> CGImage? {
        lock.lock()
        if let original {
            lock.unlock()
            return original
        }
        lock.unlock()
        guard let fileURL, let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - 重采样

    /// 从内存位图降采样。`interpolationQuality = .high` 配一次性缩放，
    /// 比把大图交给每帧的绘制去缩要稳。
    private static func downsample(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > 0 else { return image }
        guard longest > CGFloat(maxPixel) else { return image }

        let ratio = CGFloat(maxPixel) / longest
        let target = CGSize(width: max(1, (width * ratio).rounded()),
                            height: max(1, (height * ratio).rounded()))
        guard let context = CGContext(data: nil,
                                      width: Int(target.width),
                                      height: Int(target.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: target))
        return context.makeImage()
    }

    /// 从文件子采样解码：只解出目标尺寸，中间不会摊开整张图。
    private static func subsampled(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

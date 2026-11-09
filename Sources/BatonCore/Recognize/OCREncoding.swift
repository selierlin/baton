import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 云端 OCR 共用的图片预处理：压到「base64 之后不超过 N 字节」。
///
/// 百度限 base64 后 4MB、腾讯限 7MB，都是按**编码后**的长度算，
/// 所以先降 JPEG 质量，不够再等比缩图——直接缩会先损失清晰度，而降低质量往往就够了。
enum OCREncoding {
    static func encode(_ image: CGImage, base64Limit: Int) throws -> Data {
        guard image.width > 0, image.height > 0 else { throw OCRError.emptyImage }

        func fits(_ data: Data) -> Bool {
            // base64 约为原始 4/3，这里直接按最终字符串长度比。
            data.base64EncodedString().utf8.count <= base64Limit
        }

        for quality in [0.9, 0.75, 0.6] {
            if let data = jpeg(image, quality: quality), fits(data) { return data }
        }

        var current = image
        for _ in 0..<6 {
            guard let smaller = resized(current, factor: 0.7) else { break }
            current = smaller
            for quality in [0.85, 0.65] {
                if let data = jpeg(current, quality: quality), fits(data) { return data }
            }
            if current.width <= 320 || current.height <= 320 { break }
        }
        throw OCRError.requestFailed("图片压缩后仍超过大小限制")
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer,
                                                                 UTType.jpeg.identifier as CFString,
                                                                 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    static func resized(_ image: CGImage, factor: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

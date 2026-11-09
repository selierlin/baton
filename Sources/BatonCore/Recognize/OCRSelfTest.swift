import CoreGraphics
import CoreText
import Foundation

/// 「测试连接」用的测试图。
///
/// 不依赖截图、不依赖屏幕权限：现场画一张白底黑字的 `HELLO 123`，
/// 识别结果里能对上就说明「凭据有效 + 额度还在 + 网络通」三件事都成立。
/// 用英文而不是中文，是因为各家对中文的支持差异大，英文是共同下限。
enum OCRSelfTest {
    static let text = "HELLO 123"

    static func image() throws -> CGImage {
        let width = 360
        let height = 110
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw OCRError.requestFailed("测试图创建失败")
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 56, nil)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else {
            throw OCRError.requestFailed("测试图文字创建失败")
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        // 居中：CGContext 是左下原点，文字的 y 是基线
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
                                       y: (CGFloat(height) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            throw OCRError.requestFailed("测试图生成失败")
        }
        return image
    }
}

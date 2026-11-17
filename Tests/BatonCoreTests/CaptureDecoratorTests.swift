import CoreGraphics
import XCTest
@testable import BatonCore

final class CaptureDecoratorTests: XCTestCase {
    /// 上半红、下半蓝：用来抓「画进画布后上下颠倒」这类错误。
    private func twoToneImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return context.makeImage()!
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let bytesPerPixel = image.bitsPerPixel / 8
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        return (0..<bytesPerPixel).map { data[offset + $0] }
    }

    func testMetricsGrowWithImageButStayInRange() {
        let small = CaptureDecorator.metrics(for: twoToneImage(width: 100, height: 100), scale: 1)
        XCTAssertEqual(small.blur, 10)
        XCTAssertEqual(small.margin, 18)

        let large = CaptureDecorator.metrics(for: twoToneImage(width: 4000, height: 3000), scale: 1)
        XCTAssertEqual(large.blur, 40)
        XCTAssertGreaterThan(large.margin, large.blur + large.offsetY)
    }

    func testShadowedCanvasKeepsImageUprightAndTransparentAround() throws {
        let source = twoToneImage(width: 200, height: 200)
        let metrics = CaptureDecorator.metrics(for: source, scale: 1)
        let margin = Int(metrics.margin)
        let output = try XCTUnwrap(CaptureDecorator.shadowed(source, scale: 1))

        XCTAssertEqual(output.width, 200 + margin * 2)
        XCTAssertEqual(output.height, 200 + margin * 2)

        // 四角必须是透明的：阴影没被画布边缘切成灰框
        XCTAssertEqual(rgba(output, x: 0, y: 0)[3], 0)
        XCTAssertEqual(rgba(output, x: output.width - 1, y: output.height - 1)[3], 0)

        // 图像本体：顶部仍是红色，底部仍是蓝色（没有被上下翻转）
        let centerX = output.width / 2
        let top = rgba(output, x: centerX, y: margin + 4)
        let bottom = rgba(output, x: centerX, y: output.height - margin - 5)
        XCTAssertGreaterThan(top[0], 240)
        XCTAssertLessThan(top[2], 15)
        XCTAssertGreaterThan(bottom[2], 240)
        XCTAssertLessThan(bottom[0], 15)
    }

    /// JPEG / HEIC 没有 alpha，透明边会被编码成黑边。
    func testOpaqueVariantFillsWhiteInsteadOfTransparent() throws {
        let source = twoToneImage(width: 200, height: 200)
        let output = try XCTUnwrap(CaptureDecorator.shadowedOnWhite(source, scale: 1))

        let corner = rgba(output, x: 0, y: 0)
        XCTAssertEqual(corner[3], 255)
        XCTAssertGreaterThan(corner[0], 250)
        XCTAssertGreaterThan(corner[1], 250)
        XCTAssertGreaterThan(corner[2], 250)
    }
}

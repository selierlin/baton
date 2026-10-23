import CoreGraphics
import ImageIO
import XCTest
@testable import BatonCore

final class PinImageSourceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-pin-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func writePNG(_ image: CGImage) throws -> URL {
        let url = directory.appendingPathComponent("pin.png")
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        return url
    }

    /// 显示位图按窗口设备像素取，不保留全分辨率
    func testDisplayImageIsResampledToRequestedPixels() {
        let source = PinImageSource(image: makeImage(width: 1200, height: 800))
        let display = source.display(maxPixel: 600)

        XCTAssertEqual(max(display?.width ?? 0, display?.height ?? 0), 768, "桶按 256 向上取整")
        // 比例保持不变
        XCTAssertEqual(Double(display!.width) / Double(display!.height), 1.5, accuracy: 0.01)
    }

    /// 恢复的贴图不解全图：直接从 blob 子采样出窗口尺寸
    func testFileBackedSourceDecodesOnlyDisplaySize() throws {
        let url = try writePNG(makeImage(width: 1600, height: 1200))
        let source = PinImageSource(pixelSize: CGSize(width: 1600, height: 1200), fileURL: url)

        XCTAssertEqual(source.pixelSize, CGSize(width: 1600, height: 1200))
        let display = source.display(maxPixel: 400)
        XCTAssertEqual(max(display?.width ?? 0, display?.height ?? 0), 512, "桶按 256 向上取整")

        // 导出时才回原图
        XCTAssertEqual(source.full()?.width, 1600)
    }

    /// 落库后丢掉内存里的原图，full() 仍能从文件取回
    func testReleaseOriginalKeepsExportWorking() throws {
        let url = try writePNG(makeImage(width: 800, height: 600))
        let source = PinImageSource(image: makeImage(width: 800, height: 600))
        source.releaseOriginal()

        // 只有内存图的来源，原图丢了就取不回来
        XCTAssertNil(source.full())

        let backed = PinImageSource(pixelSize: CGSize(width: 800, height: 600), fileURL: url)
        XCTAssertEqual(backed.full()?.width, 800)
    }

    /// 同一桶内重复取图走缓存，不重复解码
    func testDisplayImageIsCachedPerBucket() {
        let source = PinImageSource(image: makeImage(width: 1000, height: 1000))
        let first = source.display(maxPixel: 300)
        let second = source.display(maxPixel: 400)
        XCTAssertTrue(first === second, "300 和 400 落在同一个 512 桶")
    }
}

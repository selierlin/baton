import AppKit
import XCTest
@testable import BatonCore

@MainActor
final class OverlayMaskTests: XCTestCase {
    func testDimCoversWholeScreenBeforeAnySelection() throws {
        let context = CGContext(data: nil, width: 100, height: 100,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let display = DisplayFrame(displayID: 1,
                                   screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                   pixelSize: CGSize(width: 100, height: 100),
                                   nativeScale: 1)
        let frame = CapturedFrame(image: context.makeImage()!, display: display)

        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                               display: display,
                               image: frame.image,
                               mainScreenHeight: 100,
                               mode: .area,
                               probe: nil)

        // 刚进截图态、还没拖框：遮罩必须已经铺满整屏。
        // 之前这里只在 mouseDown 后才更新，用户点完热键看不到任何变化。
        let dim = try XCTUnwrap(view.layer?.sublayers?[1] as? CAShapeLayer)
        let path = try XCTUnwrap(dim.path)
        XCTAssertEqual(path.boundingBox, view.bounds)
        XCTAssertEqual(dim.fillColor?.alpha ?? 0, 0.30, accuracy: 0.01)
    }

    /// 先铺窗、后抓帧：图没到时窗口必须完全透明，否则就是「按下去屏幕先黑一下」
    func testPlaceholderStaysTransparentUntilImageArrives() throws {
        let display = DisplayFrame(displayID: 1,
                                   screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                   pixelSize: CGSize(width: 100, height: 100),
                                   nativeScale: 1)
        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                               display: display,
                               image: nil,
                               mainScreenHeight: 100,
                               mode: .area,
                               probe: nil)

        let dim = try XCTUnwrap(view.layer?.sublayers?[1] as? CAShapeLayer)
        XCTAssertTrue(dim.isHidden, "冻结帧没到就不该压暗")
        XCTAssertFalse(view.hasImage)

        let context = CGContext(data: nil, width: 100, height: 100,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        view.setImage(context.makeImage()!)

        XCTAssertTrue(view.hasImage)
        XCTAssertFalse(dim.isHidden)
    }
}

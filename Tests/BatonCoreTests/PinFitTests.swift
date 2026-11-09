import CoreGraphics
import XCTest
@testable import BatonCore

/// 贴图首次落位的倍率。
///
/// 这条规则的差别用户一眼就能看出来：截图贴图必须「截多大贴多大」，
/// 被缩 4% 都会觉得贴上去小了一圈；文件图则相反，要留出余量别盖满屏。
@MainActor
final class PinFitTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// 截多大的区域就贴多大，包括贴满整屏这种极端情况
    func testScreenshotKeepsOriginalSize() {
        XCTAssertEqual(PinWindowController.fitZoom(baseSize: CGSize(width: 925, height: 700),
                                                   in: screen), 1)
        XCTAssertEqual(PinWindowController.fitZoom(baseSize: CGSize(width: 1300, height: 720),
                                                   in: screen), 1)
        XCTAssertEqual(PinWindowController.fitZoom(baseSize: CGSize(width: 1440, height: 900),
                                                   in: screen), 1)
    }

    /// 比屏幕还大的图（窗口截图可能把屏外部分也抓进来）仍然缩到屏内
    func testImageLargerThanScreenShrinks() {
        let zoom = PinWindowController.fitZoom(baseSize: CGSize(width: 2880, height: 1800),
                                               in: screen)
        XCTAssertEqual(zoom, 0.5, accuracy: 0.0001)
    }

    /// 文件图留 20% 余量
    func testFilePinKeepsBreathingRoom() {
        let zoom = PinWindowController.fitZoom(baseSize: CGSize(width: 1200, height: 760),
                                               in: screen, fraction: 0.8)
        XCTAssertEqual(zoom, 0.8 * 900 / 760, accuracy: 0.0001)
        XCTAssertLessThan(zoom, 1)
    }

    /// 小图不放大：贴图和原图一样大才有意义
    func testSmallImageIsNotUpscaled() {
        XCTAssertEqual(PinWindowController.fitZoom(baseSize: CGSize(width: 200, height: 100),
                                                   in: screen), 1)
    }

    func testZeroSizeIsSafe() {
        XCTAssertEqual(PinWindowController.fitZoom(baseSize: .zero, in: screen), 1)
    }
}

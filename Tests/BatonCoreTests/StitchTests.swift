import XCTest
@testable import BatonCore

/// 长截图偏移估计：用合成图验证「滚了多少」能被认出来，
/// 以及内容不动 / 换页时不会硬拼。
final class StitchTests: XCTestCase {
    private func gradientFrame(width: Int = 40, height: Int = 400, shift: Int = 0) -> GrayFrame {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // 确定性噪声：模拟真实页面的纹理。
                // 只跟 (行, 列) 有关，滚动后整片一起移动，匹配仍然精确；
                // 同时没有垂直周期，未滚动时不会撞上错位解。
                var seed = UInt32(truncatingIfNeeded: (y + shift) &* 2654435761)
                seed ^= UInt32(x) &* 2246822519
                pixels[y * width + x] = UInt8((seed >> 13) & 0xFF)
            }
        }
        return GrayFrame(pixels: pixels, width: width, height: height)
    }

    func testFindsVerticalScroll() {
        let previous = gradientFrame(shift: 0)
        let current = gradientFrame(shift: 120)

        let match = FrameStitcher.verticalOffset(previous: previous, current: current)
        XCTAssertNotNil(match)
        // 120 个降采样行 × 4 像素/行
        XCTAssertEqual(match?.offset, 480)
        XCTAssertLessThan(match?.mae ?? 999, 1)
    }

    func testRejectsUnchangedFrame() {
        let previous = gradientFrame(shift: 0)
        let current = gradientFrame(shift: 0)

        // 原样对齐就是零误差，直接判「没滚」，不去找一个伪偏移
        XCTAssertNil(FrameStitcher.verticalOffset(previous: previous, current: current))
    }

    func testRejectsMismatchedSize() {
        let previous = gradientFrame(width: 40, height: 400)
        let current = gradientFrame(width: 32, height: 400)
        XCTAssertNil(FrameStitcher.verticalOffset(previous: previous, current: current))
    }

    func testSmallScrollStillDetected() {
        let previous = gradientFrame(shift: 0)
        let current = gradientFrame(shift: 12)
        let match = FrameStitcher.verticalOffset(previous: previous, current: current)
        XCTAssertEqual(match?.offset, 48)
    }
}

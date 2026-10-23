import CoreGraphics
import XCTest
@testable import BatonCore

final class RulerSnapTests: XCTestCase {
    /// 64×64 的合成图：左 32 列黑、右 32 列白（可改成别的分界）。
    private func makeImage(width: Int = 64, height: Int = 64,
                           color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let index = (y * width + x) * 4
                bytes[index] = b
                bytes[index + 1] = g
                bytes[index + 2] = r
                bytes[index + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    func testSnapsLeftEdgeToVerticalBoundary() {
        // 第 32 列开始变白；选区左边界落在 36，容差 6 内能够到 32
        let image = makeImage { x, _ in x < 32 ? (0, 0, 0) : (255, 255, 255) }
        let rect = CGRect(x: 36, y: 12, width: 16, height: 40)

        let snapped = RulerSnap.snap(rect, in: image)

        XCTAssertEqual(snapped.minX, 32)
        // 右边界附近全是白，不该乱动
        XCTAssertEqual(snapped.maxX, rect.maxX)
        XCTAssertEqual(snapped.minY, rect.minY)
        XCTAssertEqual(snapped.maxY, rect.maxY)
    }

    func testSnapsTopAndBottomEdgesToHorizontalBoundary() {
        // 第 20 行开始变白：上边界 24 → 20，下边界 40 不在 20 的容差内，保持
        let image = makeImage { _, y in y < 20 ? (0, 0, 0) : (255, 255, 255) }
        let rect = CGRect(x: 8, y: 24, width: 40, height: 16)

        let snapped = RulerSnap.snap(rect, in: image)

        XCTAssertEqual(snapped.minY, 20)
        XCTAssertEqual(snapped.maxY, rect.maxY)
        XCTAssertEqual(snapped.minX, rect.minX)
    }

    func testFlatColorKeepsRect() {
        let image = makeImage { _, _ in (120, 130, 140) }
        let rect = CGRect(x: 10, y: 10, width: 30, height: 30)

        XCTAssertEqual(RulerSnap.snap(rect, in: image), rect)
    }

    func testTinyRectIsLeftAlone() {
        let image = makeImage { x, _ in x < 32 ? (0, 0, 0) : (255, 255, 255) }
        let rect = CGRect(x: 30, y: 10, width: 4, height: 4)

        XCTAssertEqual(RulerSnap.snap(rect, in: image), rect)
    }

    func testBestRespectsWindowAndThreshold() {
        // 索引 0 和末尾永远不参与（没有左右邻居）
        let strength: [Double] = [0, 5, 9, 40, 12, 3, 0]
        XCTAssertEqual(RulerSnap.best(in: strength, target: 2, window: 2, minimum: 20), 3)
        XCTAssertNil(RulerSnap.best(in: strength, target: 2, window: 0, minimum: 20))
        XCTAssertNil(RulerSnap.best(in: strength, target: 5, window: 1, minimum: 20))
        XCTAssertNil(RulerSnap.best(in: [], target: 1, window: 2, minimum: 20))
    }

    func testColumnStrengthFindsBoundaryPeak() {
        let image = makeImage { x, _ in x < 32 ? (0, 0, 0) : (255, 255, 255) }
        let buffer = Buffer(image)!
        let strength = buffer.columnStrength(rows: 0..<64)

        // 边界落在 31 与 32 之间，两列都看得到这条缝，其余列都是 0
        XCTAssertEqual(strength[32], 255, accuracy: 0.5)
        XCTAssertEqual(strength[31], 255, accuracy: 0.5)
        XCTAssertEqual(strength[30], 0, accuracy: 0.5)
        XCTAssertEqual(strength[33], 0, accuracy: 0.5)
    }
}

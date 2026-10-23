import AppKit
import CoreGraphics
import XCTest
@testable import BatonCore

final class OCRTransportTests: XCTestCase {
    private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 60, h: CGFloat = 20) -> OCRLine {
        OCRLine(text: text, points: [
            CGPoint(x: x, y: y),
            CGPoint(x: x + w, y: y),
            CGPoint(x: x + w, y: y + h),
            CGPoint(x: x, y: y + h),
        ])
    }

    func testReadingOrderGroupsSameRowAndSortsByColumn() {
        // 同一「行」的 y 略有抖动应聚在一起，行内按 x 从左到右；下一行排后面。
        let right = line("right", x: 300, y: 11)
        let left = line("left", x: 10, y: 13)
        let bottom = line("bottom", x: 10, y: 200)

        let ordered = VisionOCRTransport.readingOrder([bottom, right, left])
        XCTAssertEqual(ordered.map(\.text), ["left", "right", "bottom"])
    }

    func testReadingOrderKeepsSeparateRowsApart() {
        // 两行差 30pt（行高 20），不能被当成一行
        let first = line("first", x: 10, y: 10)
        let second = line("second", x: 10, y: 40)

        let ordered = VisionOCRTransport.readingOrder([second, first])
        XCTAssertEqual(ordered.map(\.text), ["first", "second"])
    }

    func testBoundingRectUnionsPoints() {
        let item = line("x", x: 40, y: 60, w: 100, h: 30)
        XCTAssertEqual(item.boundingRect, CGRect(x: 40, y: 60, width: 100, height: 30))
    }

    func testRecognizesSyntheticImageWithTopLeftOrigin() async throws {
        let image = try makeImage(lines: ["Hello Baton", "第二行文字"])

        let result = try await VisionOCRTransport().recognize(OCRRequest(image: image))
        XCTAssertGreaterThanOrEqual(result.lines.count, 2, "应至少识别出两行：\(result.lines.map(\.text))")

        let first = try XCTUnwrap(result.lines.first)
        let last = try XCTUnwrap(result.lines.last)
        // 左上原点：第一行的 y 必须小于最后一行
        XCTAssertLessThan(first.boundingRect.minY, last.boundingRect.minY)
        // 坐标是像素，不能全是 0..1 的归一化值
        XCTAssertGreaterThan(first.boundingRect.maxX, 1)
    }

    private func makeImage(lines: [String],
                           size: CGSize = CGSize(width: 600, height: 220)) throws -> CGImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36),
            .foregroundColor: NSColor.black,
        ]
        for (index, text) in lines.enumerated() {
            let y = size.height - 70 - CGFloat(index) * 80
            (text as NSString).draw(at: NSPoint(x: 24, y: y), withAttributes: attributes)
        }
        image.unlockFocus()

        var rect = CGRect(origin: .zero, size: size)
        return try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    }
}

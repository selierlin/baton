import AppKit
import CoreGraphics
import XCTest
@testable import BatonCore

final class QRScannerTests: XCTestCase {
    /// 现场生成一张二维码图，避免往仓库里塞测试图片。
    private func makeQRImage(_ text: String, side: CGFloat = 240) throws -> CGImage {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(text.data(using: .utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        let output = try XCTUnwrap(filter.outputImage)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: side / output.extent.width,
                                                              y: side / output.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    func testDetectsPayloadAndBox() async throws {
        let target = "https://baton.app/download?ref=test"
        let image = try makeQRImage(target)

        let codes = await QRScanner.scan(image)
        let code = try XCTUnwrap(codes.first)
        XCTAssertEqual(code.payload, target)

        // 框应当盖住图的大部分，偏到角落说明坐标口径错了（左上 vs 左下、点 vs 像素）
        let box = code.boundingRect
        XCTAssertGreaterThan(box.width, CGFloat(image.width) * 0.5)
        XCTAssertLessThan(box.minX, CGFloat(image.width) * 0.25)
        XCTAssertLessThan(box.minY, CGFloat(image.height) * 0.25)
    }

    func testBlankImageHasNoCodes() async throws {
        let image = NSImage(size: NSSize(width: 200, height: 120))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 120).fill()
        image.unlockFocus()
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))

        let codes = await QRScanner.scan(cgImage)
        XCTAssertTrue(codes.isEmpty)
    }

    func testReadingOrderSortsRowsThenColumns() {
        func code(_ payload: String, x: CGFloat, y: CGFloat, side: CGFloat = 100) -> QRCode {
            QRCode(payload: payload, rect: CGRect(x: x, y: y, width: side, height: side))
        }
        // 同一行的两张码纵向有几个点的抖动，不能拆成两行
        let right = code("right", x: 300, y: 12)
        let left = code("left", x: 20, y: 8)
        let bottom = code("bottom", x: 20, y: 260)

        let ordered = QRScanner.readingOrder([bottom, right, left])
        XCTAssertEqual(ordered.map(\.payload), ["left", "right", "bottom"])
    }
}

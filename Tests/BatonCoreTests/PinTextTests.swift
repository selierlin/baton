import AppKit
import ImageIO
import XCTest
@testable import BatonCore

/// 文字贴图：排版尺寸 + 「剪贴板里只有文字时也能钉」。
@MainActor
final class PinTextTests: XCTestCase {
    private func scratchPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("baton-pin-text-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    // MARK: - 排版

    func testBaseWidthIsFixedAndShortTextGetsMinHeight() {
        let content = PinTextContent(text: "一行字")
        XCTAssertEqual(content.baseSize.width, PinTextContent.baseWidth)
        XCTAssertGreaterThanOrEqual(content.baseSize.height, 44)
        XCTAssertLessThan(content.baseSize.height, 80)
    }

    /// 长文本不能把卡片撑到屏幕外：展示串裁到上限、补省略号，原文仍在
    func testLongTextIsCappedAtMaxHeight() {
        let long = String(repeating: "很长的一段话。", count: 400)
        let content = PinTextContent(text: long)

        XCTAssertLessThanOrEqual(content.baseSize.height, PinTextContent.maxBaseHeight)
        XCTAssertGreaterThan(content.baseSize.height, PinTextContent.maxBaseHeight - 40)
        XCTAssertTrue(content.displayText.hasSuffix("…"))
        XCTAssertLessThan(content.displayText.count, long.count)
        XCTAssertEqual(content.text, long, "全文不能被裁掉，⌘C 要复制完整原文")
    }

    /// 换行不能退化成单行：一段中等长度的文字应当排成多行
    func testMediumTextWrapsIntoMultipleLines() {
        let content = PinTextContent(text: String(repeating: "换行验证。", count: 20))
        XCTAssertGreaterThan(content.baseSize.height, 60)
        XCTAssertEqual(content.displayText, content.text, "没超上限就不该裁")
    }

    func testBlankTextIsDetected() {
        XCTAssertTrue(PinTextContent(text: "  \n\t ").isBlank)
        XCTAssertFalse(PinTextContent(text: "x").isBlank)
    }

    // MARK: - 剪贴板

    func testTextOnlyClipboardPinsTextCard() {
        let pasteboard = scratchPasteboard()
        pasteboard.setString("一条要钉住的命令 rm -rf …", forType: .string)

        let pins = PinController()
        XCTAssertTrue(pins.pinPasteboard(from: pasteboard))
        XCTAssertEqual(pins.count, 1)
        pins.closeAll()
    }

    func testBlankClipboardIsRejected() {
        let pasteboard = scratchPasteboard()
        pasteboard.setString("   \n ", forType: .string)

        let pins = PinController()
        XCTAssertFalse(pins.pinPasteboard(from: pasteboard))
        XCTAssertEqual(pins.count, 0)
    }

    /// 图文都在时仍按「图」钉：用户复制的是一张图，文字只是附带的
    func testImageWinsWhenClipboardHasBoth() {
        let pasteboard = scratchPasteboard()
        let image = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        pasteboard.setData(data as Data, forType: .png)
        pasteboard.setString("附带说明", forType: .string)

        let pins = PinController()
        XCTAssertTrue(pins.pinPasteboard(from: pasteboard))
        XCTAssertEqual(pins.count, 1)
        pins.closeAll()
    }
}

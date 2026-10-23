import AppKit
import XCTest
@testable import BatonCore

/// 用私有剪贴板验证解析，不碰系统剪贴板。
final class PasteboardReaderTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
    }

    func testReadsPlainText() throws {
        pasteboard.clearContents()
        pasteboard.setString("hello 剪贴板", forType: .string)

        let snapshot = try XCTUnwrap(PasteboardReader.read(pasteboard, sourceApp: "Xcode"))
        XCTAssertEqual(snapshot.kind, .text)
        XCTAssertEqual(snapshot.text, "hello 剪贴板")
        XCTAssertEqual(snapshot.byteSize, "hello 剪贴板".utf8.count)
    }

    func testWhitespaceOnlyIsIgnored() {
        pasteboard.clearContents()
        pasteboard.setString("   \n  ", forType: .string)
        XCTAssertNil(PasteboardReader.read(pasteboard, sourceApp: nil))
    }

    func testReadsImageAndNormalizesToPNG() throws {
        pasteboard.clearContents()
        let image = Self.makeImage(width: 40, height: 20)
        pasteboard.writeObjects([image])

        let snapshot = try XCTUnwrap(PasteboardReader.read(pasteboard, sourceApp: nil))
        XCTAssertEqual(snapshot.kind, .image)
        XCTAssertEqual(snapshot.pixelWidth, 40)
        XCTAssertEqual(snapshot.pixelHeight, 20)
        XCTAssertEqual(snapshot.text, "图片 40×20")

        let png = try XCTUnwrap(snapshot.pngData)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "应重编码为 PNG")
    }

    func testSameContentHasSameHash() throws {
        pasteboard.clearContents()
        pasteboard.setString("dedupe me", forType: .string)
        let first = try XCTUnwrap(PasteboardReader.read(pasteboard, sourceApp: nil))

        pasteboard.clearContents()
        pasteboard.setString("dedupe me", forType: .string)
        let second = try XCTUnwrap(PasteboardReader.read(pasteboard, sourceApp: nil))

        XCTAssertEqual(first.contentHash, second.contentHash)
    }

    private static func makeImage(width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}

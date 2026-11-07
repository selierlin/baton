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

    func testReadsImageAndConvertsTIFFToPNG() throws {
        pasteboard.clearContents()
        let image = Self.makeImage(width: 40, height: 20)
        pasteboard.writeObjects([image])

        let snapshot = try XCTUnwrap(PasteboardReader.read(pasteboard, sourceApp: nil))
        XCTAssertEqual(snapshot.kind, .image)
        XCTAssertEqual(snapshot.pixelWidth, 40)
        XCTAssertEqual(snapshot.pixelHeight, 20)
        XCTAssertEqual(snapshot.text, "图片 40×20")

        let png = try XCTUnwrap(snapshot.imageData)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "TIFF 应转成 PNG")
        XCTAssertEqual(snapshot.imageExt, "png")
        XCTAssertEqual(snapshot.contents.count, 1)
        XCTAssertEqual(snapshot.contents.first?.type, "public.png")
    }

    /// 已经是 PNG 的图不能重编码：字节变了就等于换了张图，GIF 还会丢动画。
    func testPNGIsStoredByteIdentical() throws {
        let png = try Self.pngData(width: 12, height: 8)
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        let snapshot = try XCTUnwrap(PasteboardReader.read(pasteboard, sourceApp: nil))
        XCTAssertEqual(snapshot.imageData, png)
        XCTAssertEqual(snapshot.imageExt, "png")
    }

    func testKeepsRichTextRepresentations() throws {
        pasteboard.clearContents()
        let html = "<b>加粗</b>"
        pasteboard.setString(html, forType: .html)
        pasteboard.setString("加粗", forType: .string)

        let snapshot = try XCTUnwrap(PasteboardReader.read(pasteboard, sourceApp: nil))
        XCTAssertEqual(snapshot.kind, .text)
        XCTAssertEqual(snapshot.text, "加粗")
        XCTAssertEqual(Set(snapshot.contents.map(\.type)), ["public.html", "public.utf8-plain-text"],
                       "富文本和纯文本都要留下")
    }

    func testFinderFilesSkipIconImages() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).txt")
        try "x".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])

        let snapshot = try XCTUnwrap(PasteboardReader.read(pasteboard, sourceApp: nil))
        XCTAssertEqual(snapshot.kind, .file)
        XCTAssertEqual(snapshot.filePaths, fileURL.path)
        XCTAssertEqual(snapshot.contents.first?.type, "public.file-url")
        XCTAssertFalse(snapshot.contents.contains { $0.type == "public.tiff" })
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

    private static func pngData(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(makeImage(width: width, height: height)
            .representations.first as? NSBitmapImageRep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
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

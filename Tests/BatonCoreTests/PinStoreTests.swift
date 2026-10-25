import CoreGraphics
import ImageIO
import XCTest
@testable import BatonCore

final class PinStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeImage(width: Int = 40, height: Int = 30, gray: CGFloat = 0.5) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func makeStore(maxItems: Int = 800) throws -> (ClipboardStore, PinStore) {
        let database = try BatonDatabase(directory: directory)
        let clipboard = ClipboardStore(database: database, maxItems: maxItems)
        return (clipboard, PinStore(clipboard: clipboard))
    }

    func testSaveAndReload() throws {
        let (_, pins) = try makeStore()
        let frame = CGRect(x: 100, y: 200, width: 300, height: 150)
        let id = try pins.save(image: makeImage(), scale: 2, frame: frame, screenUUID: "ABC")

        let stored = pins.loadAll()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, id)
        XCTAssertEqual(stored.first?.frame, frame)
        XCTAssertEqual(stored.first?.scale, 2)
        XCTAssertEqual(stored.first?.source.pixelSize.width, 40)
    }

    /// 同一张图钉两处：两条 pin 记录，一条 item（blob 只有一份）
    func testSameImagePinnedTwiceSharesOneItem() throws {
        let (clipboard, pins) = try makeStore()
        let image = makeImage()
        let first = try pins.save(image: image, scale: 2,
                                  frame: CGRect(x: 0, y: 0, width: 20, height: 15), screenUUID: nil)
        let second = try pins.save(image: image, scale: 2,
                                   frame: CGRect(x: 500, y: 500, width: 20, height: 15), screenUUID: nil)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(pins.loadAll().count, 2)
        XCTAssertEqual(try clipboard.recent(limit: 10).filter { $0.clipKind == .image }.count, 1)
    }

    func testUpdateFramePersists() throws {
        let (_, pins) = try makeStore()
        let id = try pins.save(image: makeImage(), scale: 2,
                               frame: CGRect(x: 0, y: 0, width: 20, height: 15), screenUUID: nil)
        pins.updateFrame(id: id, frame: CGRect(x: 42, y: 84, width: 60, height: 40), screenUUID: "S2")

        let reloaded = try makeStore().1.loadAll()
        XCTAssertEqual(reloaded.first?.frame, CGRect(x: 42, y: 84, width: 60, height: 40))
    }

    /// 裁剪历史时被钉住的 item 必须留下，否则屏幕上那张图会变成空白
    func testTrimKeepsPinnedItems() throws {
        let (clipboard, pins) = try makeStore(maxItems: 2)
        let pinned = try pins.save(image: makeImage(gray: 0.1), scale: 1,
                                   frame: CGRect(x: 0, y: 0, width: 40, height: 30), screenUUID: nil)

        for index in 0..<5 {
            _ = try clipboard.insert(ClipDraft(kind: .text,
                                               contentHash: "hash-\(index)",
                                               text: "文本 \(index)",
                                               byteSize: 4))
        }
        _ = try clipboard.trim()

        let remaining = try clipboard.recent(limit: 50)
        XCTAssertLessThanOrEqual(remaining.count, 2)
        let hasPinnedItem = remaining.contains { $0.clipKind == .image }
        XCTAssertTrue(hasPinnedItem, "被贴图引用的 item 不应被裁掉")
        XCTAssertEqual(pins.loadAll().count, 1)
        _ = pinned
    }

    func testDeleteRemovesOnlyPinInstance() throws {
        let (clipboard, pins) = try makeStore()
        let id = try pins.save(image: makeImage(), scale: 2,
                               frame: CGRect(x: 0, y: 0, width: 20, height: 15), screenUUID: nil)
        pins.delete(id: id)
        XCTAssertTrue(pins.loadAll().isEmpty)
        XCTAssertEqual(try clipboard.recent(limit: 10).count, 1, "item 仍留给剪贴板历史")
    }

    func testOpacityRoundTrip() throws {
        let (_, pins) = try makeStore()
        let id = try pins.save(image: makeImage(), scale: 2,
                               frame: CGRect(x: 0, y: 0, width: 20, height: 15),
                               screenUUID: nil, opacity: 1)
        pins.updateOpacity(id: id, opacity: 0.6)
        XCTAssertEqual(pins.loadAll().first?.opacity ?? 0, 0.6, accuracy: 0.001)
    }

    /// 落库返回的 blob 是「丢掉内存原图」的唯一依据，必须能直接拿来解码
    func testBlobURLForPinID() throws {
        let (_, pins) = try makeStore()
        let id = try pins.save(image: makeImage(width: 64, height: 48), scale: 2,
                               frame: CGRect(x: 0, y: 0, width: 32, height: 24), screenUUID: nil)

        let url = try XCTUnwrap(pins.blobURL(forPinID: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let image = try XCTUnwrap(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.width, 64, "blob 里应该是原图，不是窗口显示用的缩略图")

        XCTAssertNil(pins.blobURL(forPinID: "no-such-pin"))
    }

    func testFrameCodecHandlesNegativeOrigin() {
        // 副屏在主屏左侧时 origin 为负，JSON 编解码不能丢
        let rect = CGRect(x: -1200, y: -300, width: 800, height: 600)
        XCTAssertEqual(PinStore.decode(PinStore.encode(rect)), rect)
    }
}

/// 贴图的非窗口逻辑（隐藏状态、文件导入的失败分支）。
///
/// 不测「贴出一张图」：那会真建 NSWindow，在有界面会话里跑没问题，
/// 但在无人值守/无窗口服务的环境会假死，不值得为了覆盖率冒这个险。
@MainActor
final class PinControllerStateTests: XCTestCase {
    /// 不是图片的文件必须老实返回 false，不能把半张空位图钉到屏幕上
    func testPinFileRejectsNonImage() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-not-an-image-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = PinController()
        XCTAssertFalse(controller.pinFile(url))
        XCTAssertEqual(controller.count, 0, "失败不能留下空窗口")
    }

    /// 没有任何贴图时隐藏/显示应当是幂等的（菜单项会在 count == 0 时被拦，但控制器自身也要稳）
    func testHiddenToggleWithoutPinsIsSafe() {
        let controller = PinController()
        controller.toggleHidden()
        XCTAssertTrue(controller.isHidden)
        controller.toggleHidden()
        XCTAssertFalse(controller.isHidden)
        controller.closeAll()
        XCTAssertFalse(controller.isHidden, "全部关闭后必须回到「可见」状态，否则下次贴图会看不见")
    }
}

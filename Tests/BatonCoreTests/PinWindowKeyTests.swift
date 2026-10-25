import AppKit
import CoreGraphics
import XCTest
@testable import BatonCore

/// 贴图窗口的键位落到窗口上的效果：空格开工具条、R 缩略图、方向键挪窗口、Esc 两段退出。
///
/// 这里跑的是真窗口（不接存储，`store: nil`），能覆盖「子面板挂没挂上」
/// 「画布有没有插进 contentView」这类只有把窗口立起来才暴露的接线错误。
@MainActor
final class PinWindowKeyTests: XCTestCase {
    private var controller: PinWindowController!
    private var closed = false
    private var databaseDirectory: URL?

    override func tearDownWithError() throws {
        controller?.close()
        controller = nil
        if let databaseDirectory { try? FileManager.default.removeItem(at: databaseDirectory) }
    }

    private func makePin(width: CGFloat = 400, height: CGFloat = 200,
                         withStore: Bool = false) throws -> (PinWindowController, CGImage) {
        let context = CGContext(data: nil, width: Int(width), height: Int(height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var store: PinStore?
        if withStore {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("baton-pin-window-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            databaseDirectory = directory
            store = PinStore(clipboard: ClipboardStore(database: try BatonDatabase(directory: directory)))
        }
        return (makeController(image: context.makeImage()!, store: store), context.makeImage()!)
    }

    private func makeController(image: CGImage, store: PinStore? = nil) -> PinWindowController {
        closed = false
        let controller = PinWindowController(source: PinImageSource(image: image),
                                             scale: 1,
                                             anchor: nil,
                                             initialFrame: nil,
                                             opacity: 1,
                                             store: store,
                                             pinID: nil,
                                             onClose: { [weak self] _ in self?.closed = true })
        controller.show()
        self.controller = controller
        return controller
    }

    private func key(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil, characters: "",
                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
    }

    func testSpaceOpensAndClosesEditing() throws {
        let (controller, _) = try makePin()
        XCTAssertFalse(controller.debugEditing)
        XCTAssertFalse(controller.debugBarVisible)

        XCTAssertTrue(controller.handleKey(key(49)))
        XCTAssertTrue(controller.debugEditing, "空格要调起工具条并进入标注")
        XCTAssertTrue(controller.debugBarVisible, "工具条面板得真的浮出来")

        XCTAssertTrue(controller.handleKey(key(49)))
        XCTAssertFalse(controller.debugEditing)
        XCTAssertFalse(controller.debugBarVisible, "再按一次要收回去")
    }

    /// 第一次 Esc 只退编辑，别把整张贴图带走
    func testEscapeLeavesEditingBeforeClosing() throws {
        let (controller, _) = try makePin()
        controller.handleKey(key(49))

        XCTAssertTrue(controller.handleKey(key(53)))
        XCTAssertFalse(controller.debugEditing)
        XCTAssertFalse(closed, "编辑态的第一下 Esc 不该关窗")

        XCTAssertTrue(controller.handleKey(key(53)))
        XCTAssertTrue(closed, "只读态再按 Esc 才退出贴图")
    }

    func testThumbnailShrinksAndRestores() throws {
        let (controller, _) = try makePin(width: 800, height: 400)
        let normal = controller.debugFrame
        let longest = max(normal.width, normal.height)

        XCTAssertTrue(controller.handleKey(key(15)))  // R
        let thumbnail = controller.debugFrame
        XCTAssertLessThan(max(thumbnail.width, thumbnail.height), longest)
        XCTAssertEqual(max(thumbnail.width, thumbnail.height), 160, accuracy: 1)

        XCTAssertTrue(controller.handleKey(key(15)))
        // 窗口 frame 会被系统对齐到整点，允许 1pt 的取整差；倍率必须是原值
        XCTAssertEqual(controller.debugZoom, 1, accuracy: 0.001)
        XCTAssertEqual(controller.debugFrame.width, normal.width, accuracy: 1)
        XCTAssertEqual(controller.debugFrame.height, normal.height, accuracy: 1)
    }

    func testPlainEqualsZoomsIn() throws {
        let (controller, _) = try makePin()
        let before = controller.debugFrame.width
        controller.handleKey(key(24))
        XCTAssertGreaterThan(controller.debugFrame.width, before)
    }

    func testArrowsMoveWindowByOnePoint() throws {
        let (controller, _) = try makePin()
        let before = controller.debugFrame
        controller.handleKey(key(124))  // →
        XCTAssertEqual(controller.debugFrame.origin.x, before.origin.x + 1, accuracy: 0.01)
        XCTAssertEqual(controller.debugFrame.origin.y, before.origin.y, accuracy: 0.01)

        controller.handleKey(key(126, .shift))  // ⇧↑
        XCTAssertEqual(controller.debugFrame.origin.y, before.origin.y + 10, accuracy: 0.01)
    }

    /// 没进过标注的贴图按 ⌘Z 不该炸，也不该被贴图这层截走
    func testCommandUndoIsNotClaimed() throws {
        let (controller, _) = try makePin()
        XCTAssertFalse(controller.handleKey(key(6, .command)))
    }

    /// 落库会丢掉内存里的原图。丢掉之后：
    /// 缩放要能换桶重新出图，空格要能建出画布——两条路都得靠 blob 兜着。
    func testPinnedImageSurvivesStoreRelease() throws {
        let (controller, _) = try makePin(width: 800, height: 400, withStore: true)
        XCTAssertTrue(controller.debugHasContent)

        // 连放三次会跨过显示桶（1600 → 2128），只有文件在才解得出新尺寸；
        // 没有就只剩那个透明边框 —— 用户看到的就是「缩放后变黑框」
        XCTAssertTrue(controller.handleKey(key(24)))
        XCTAssertTrue(controller.handleKey(key(24)))
        XCTAssertTrue(controller.handleKey(key(24)))
        XCTAssertTrue(controller.debugHasContent, "换桶后要能从 blob 重新解出显示图")

        XCTAssertTrue(controller.handleKey(key(49)))
        XCTAssertTrue(controller.debugEditing, "原图取不回来时 ensureCanvas 会拿到 nil")
        XCTAssertTrue(controller.debugBarVisible)
    }
}

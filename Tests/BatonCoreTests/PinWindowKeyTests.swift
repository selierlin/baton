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
    // 这几个只是用例自己的账本，不参与 UI 隔离；tearDown 在 Xcode 16 的 XCTest 里是
    // 非隔离的，标成 nonisolated 才能在收尾里读它们（真正需要主线程的窗口关闭放到用例开头）。
    nonisolated(unsafe) private var controller: PinWindowController!
    nonisolated(unsafe) private var closed = false
    nonisolated(unsafe) private var databaseDirectory: URL?

    override func tearDownWithError() throws {
        // 窗口由下一个用例的 makeController 负责关（见那里），这里只清临时库
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
        // 上一个用例留下的窗口：在这儿关掉既在主线程上，也省一次 tearDown 的隔离问题
        controller?.close()
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

    /// 缩略图态要连「还原目标」一起落库，否则重启后 baseZoom 被缩略倍率顶掉，R 变成空操作。
    func testThumbnailStateIsPersistedWithBaseZoom() throws {
        let context = CGContext(data: nil, width: 800, height: 400,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-pin-thumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseDirectory = directory
        let store = PinStore(clipboard: ClipboardStore(database: try BatonDatabase(directory: directory)))

        let controller = makeController(image: context.makeImage()!, store: store)
        let normal = controller.debugFrame
        XCTAssertTrue(controller.handleKey(key(15)))
        XCTAssertEqual(max(controller.debugFrame.width, controller.debugFrame.height), 160, accuracy: 1)

        // 落库是 0.4s 防抖，等它跑完
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let stored = try XCTUnwrap(store.loadAll().first)
        XCTAssertTrue(stored.isThumbnail, "缩略图态要落库")
        XCTAssertEqual(stored.baseZoom ?? 0, normal.width / 800, accuracy: 0.01, "还原目标要落库")
        XCTAssertEqual(max(stored.frame.width, stored.frame.height), 160, accuracy: 1.5)
    }

    /// 旧版本把缩略图尺寸写成了真实尺寸：恢复时要认出来，R 才能放回适配倍率。
    func testRestorePlanRecoversLegacyThumbnailFrame() {
        let base = CGSize(width: 925, height: 700)
        let plan = PinWindowController.restorePlan(frame: CGRect(x: 0, y: 0, width: 160, height: 121),
                                                   baseSize: base, fitZoom: 1)
        XCTAssertTrue(plan.isThumbnail)
        XCTAssertEqual(plan.baseZoom, 1)
        XCTAssertEqual(plan.zoom, 160 / 925, accuracy: 0.001)
    }

    func testRestorePlanKeepsNormalFrame() {
        let base = CGSize(width: 925, height: 700)
        let frame = CGRect(x: 100, y: 100, width: 462.5, height: 350)
        let plan = PinWindowController.restorePlan(frame: frame, baseSize: base, fitZoom: 1)
        XCTAssertFalse(plan.isThumbnail)
        XCTAssertEqual(plan.baseZoom, plan.zoom, accuracy: 0.0001)
    }

    /// 原图本身就不比 160 大时，160 点就是它的正常尺寸，不能当成缩略图。
    func testRestorePlanDoesNotMistakeSmallSourceForThumbnail() {
        let plan = PinWindowController.restorePlan(frame: CGRect(x: 0, y: 0, width: 160, height: 120),
                                                   baseSize: CGSize(width: 120, height: 90), fitZoom: 1)
        XCTAssertFalse(plan.isThumbnail)
    }

    func testPlainEqualsZoomsIn() throws {
        let (controller, _) = try makePin()
        let before = controller.debugFrame.width
        controller.handleKey(key(24))
        XCTAssertGreaterThan(controller.debugFrame.width, before)
    }

    /// 滚轮缩放后，R 收起再按回来要回到滚动后的大小，而不是创建时的大小。
    func testScrollZoomBecomesRestoreTarget() throws {
        let (controller, _) = try makePin(width: 800, height: 400)
        XCTAssertEqual(controller.debugZoom, 1, accuracy: 0.001)

        controller.debugScroll(lines: 5)
        let zoomed = controller.debugZoom
        XCTAssertGreaterThan(zoomed, 1.1, "滚轮要能放大")
        XCTAssertEqual(controller.debugFrame.width, 800 * zoomed, accuracy: 1)

        XCTAssertTrue(controller.handleKey(key(15)))
        XCTAssertEqual(max(controller.debugFrame.width, controller.debugFrame.height), 160, accuracy: 1)

        XCTAssertTrue(controller.handleKey(key(15)))
        XCTAssertEqual(controller.debugZoom, zoomed, accuracy: 0.001, "R 要还原到滚出来的大小")
    }

    func testScrollDownShrinks() throws {
        let (controller, _) = try makePin(width: 800, height: 400)
        let before = controller.debugZoom
        controller.debugScroll(lines: -5)
        XCTAssertLessThan(controller.debugZoom, before)
    }

    /// 缩略态里滚一下就退回原样再继续放大，别让还原目标跟着缩水。
    func testScrollFromThumbnailReturnsToBaseFirst() throws {
        let (controller, _) = try makePin(width: 800, height: 400)
        XCTAssertTrue(controller.handleKey(key(15)))
        XCTAssertTrue(controller.debugSnapshot.isThumbnail)

        controller.debugScroll(lines: 5)
        XCTAssertFalse(controller.debugSnapshot.isThumbnail, "滚一下就该退出缩略态")
        XCTAssertGreaterThan(controller.debugZoom, 1, "是在原样倍率上继续放大，不是从缩略倍率放大")

        XCTAssertTrue(controller.handleKey(key(15)))
        XCTAssertEqual(max(controller.debugFrame.width, controller.debugFrame.height), 160, accuracy: 1)
        XCTAssertTrue(controller.handleKey(key(15)))
        XCTAssertGreaterThan(controller.debugZoom, 1)
    }

    /// 缩略态里滚一下要围着指针长大。
    ///
    /// 这条以前是坏的：先回原样、再叠一格分成两次缩放，第二次拿的还是缩略窗口里的
    /// 坐标，窗口已经变大，同一个点就落到别处，图被甩出屏幕——再按 R 收到屏幕外，
    /// 用户看到的就是「贴图不见了」。
    func testScrollFromThumbnailKeepsPointerAnchor() throws {
        let (controller, _) = try makePin(width: 800, height: 400)
        XCTAssertTrue(controller.handleKey(key(15)))
        let thumbnail = controller.debugFrame
        XCTAssertEqual(thumbnail.width, 160, accuracy: 1)

        // 缩略窗口 160×80，挑一个靠边但不贴角的点，坐标换算错了才能露出来
        let local = NSPoint(x: 120, y: 60)
        let anchor = CGPoint(x: thumbnail.minX + local.x, y: thumbnail.minY + local.y)
        controller.debugZoomGesture(step: 0.1, at: local)

        // 目标倍率 = 原样 1 × 1.1；从缩略档 0.2 涨到 1.1，锚点按 5.5 倍撑开
        XCTAssertEqual(controller.debugZoom, 1.1, accuracy: 0.001)
        XCTAssertFalse(controller.debugSnapshot.isThumbnail)
        XCTAssertEqual(controller.debugFrame.width, 800 * 1.1, accuracy: 2)
        XCTAssertEqual(controller.debugFrame.minX, anchor.x - local.x * 5.5, accuracy: 2,
                       "指针那一点缩放前后得钉在同一处")
        XCTAssertEqual(controller.debugFrame.minY, anchor.y - local.y * 5.5, accuracy: 2)
    }

    /// 缩略态靠加粗边框提示「图还开着」，退出缩略态要跟着退回细边框。
    func testThumbnailEmphasizesBorder() throws {
        let (controller, _) = try makePin(width: 800, height: 400)
        XCTAssertFalse(controller.debugBorderEmphasized)

        XCTAssertTrue(controller.handleKey(key(15)))
        XCTAssertTrue(controller.debugSnapshot.isThumbnail)
        XCTAssertTrue(controller.debugBorderEmphasized, "缩略态要加粗边框")

        XCTAssertTrue(controller.handleKey(key(15)))
        XCTAssertFalse(controller.debugBorderEmphasized, "放回原样边框退回细的")
    }

    /// 缩略态里滚一下也算退出，边框同样要退回去
    func testScrollingOutOfThumbnailDropsBoldBorder() throws {
        let (controller, _) = try makePin(width: 800, height: 400)
        XCTAssertTrue(controller.handleKey(key(15)))
        XCTAssertTrue(controller.debugBorderEmphasized)

        controller.debugScroll(lines: 5)
        XCTAssertFalse(controller.debugSnapshot.isThumbnail)
        XCTAssertFalse(controller.debugBorderEmphasized)
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

    /// 只读态拖拽要能搬窗口，标注态拖拽要老老实实画图。
    ///
    /// 这条以前是坏的：`PinView` 自己实现了 `mouseDown`（双击缩放），
    /// AppKit 的 `isMovableByWindowBackground` 就再不触发，怎么拖都不动。
    func testDragMovesWindowOnlyWhenNotEditing() throws {
        let (controller, _) = try makePin()
        let view = try XCTUnwrap(controller.debugHitView(at: CGPoint(x: 200, y: 100)),
                                 "只读态的事件应该落在贴图视图上")
        let before = controller.debugFrame

        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 200, y: 100)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 240, y: 125)))

        XCTAssertEqual(controller.debugFrame.origin.x, before.origin.x + 40, accuracy: 0.5)
        XCTAssertEqual(controller.debugFrame.origin.y, before.origin.y + 25, accuracy: 0.5,
                       "窗口坐标 y 向上，拖到上方就是向上挪")
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 240, y: 125)))
    }

    func testDragDuringEditingDoesNotMoveWindow() throws {
        let (controller, _) = try makePin()
        XCTAssertTrue(controller.handleKey(key(49)))

        let hitView = try XCTUnwrap(controller.debugHitView(at: CGPoint(x: 200, y: 100)))
        XCTAssertFalse(hitView.mouseDownCanMoveWindow, "标注态画布不能把拖拽漏给窗口")

        let before = controller.debugFrame
        hitView.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 200, y: 100)))
        hitView.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 260, y: 150)))
        XCTAssertEqual(controller.debugFrame, before, "标注态拖拽必须只在画布上落笔")
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

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint,
                       click: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 1, context: nil, eventNumber: 0,
                           clickCount: click, pressure: 1)!
    }
}

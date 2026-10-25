import AppKit
import CoreGraphics
import XCTest
@testable import BatonCore

/// 贴图窗口的键位表。
///
/// 这张表是照 Longshot 的 `app_scXXXX_pin*` 抄的，最容易出的错不是「没实现」，
/// 而是**被截图态的键位抢走**：画布是 first responder，它的 `r` 是 OCR、
/// `⌘D` 是保存、方向键是挪图元。所以这里逐条钉住「贴图里该是什么」。
final class PinShortcutsTests: XCTestCase {
    private func event(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero,
                         modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: keyCode)!
    }

    func testSpaceTogglesToolbar() {
        XCTAssertEqual(PinShortcuts.action(for: event(49)), .toggleEdit)
    }

    func testRTogglesThumbnail() {
        XCTAssertEqual(PinShortcuts.action(for: event(15)), .thumbnail)
    }

    func testPlainEqualsAndMinusZoom() {
        XCTAssertEqual(PinShortcuts.action(for: event(24)), .zoomIn)
        XCTAssertEqual(PinShortcuts.action(for: event(27)), .zoomOut)
    }

    /// ⌘ 让给不透明度（Longshot 就是这么分的），别跟缩放混
    func testCommandVariantsChangeOpacity() {
        XCTAssertEqual(PinShortcuts.action(for: event(24, .command)), .opacityUp)
        XCTAssertEqual(PinShortcuts.action(for: event(27, .command)), .opacityDown)
    }

    func testCommandDSavesAndShiftCommandDSavesAndCopies() {
        XCTAssertEqual(PinShortcuts.action(for: event(2, .command)), .save)
        XCTAssertEqual(PinShortcuts.action(for: event(2, [.command, .shift])), .saveAndCopy)
    }

    func testReturnCopies() {
        XCTAssertEqual(PinShortcuts.action(for: event(36)), .copy)
        XCTAssertEqual(PinShortcuts.action(for: event(76)), .copy)
    }

    func testEscapeIsTwoStage() {
        XCTAssertEqual(PinShortcuts.action(for: event(53)), .escape)
    }

    func testArrowsNudgeByOneOrTen() {
        XCTAssertEqual(PinShortcuts.action(for: event(124)), .nudge(dx: 1, dy: 0))
        XCTAssertEqual(PinShortcuts.action(for: event(123)), .nudge(dx: -1, dy: 0))
        XCTAssertEqual(PinShortcuts.action(for: event(126)), .nudge(dx: 0, dy: 1))
        XCTAssertEqual(PinShortcuts.action(for: event(125)), .nudge(dx: 0, dy: -1))

        XCTAssertEqual(PinShortcuts.action(for: event(124, .shift)), .nudge(dx: 10, dy: 0))
        XCTAssertEqual(PinShortcuts.action(for: event(125, .shift)), .nudge(dx: 0, dy: -10))
    }

    /// ⌘Z / ⌘C 这些归画布（它要撤销、要复制合成图），贴图这层不许截胡
    func testCommandUndoStaysWithCanvas() {
        XCTAssertNil(PinShortcuts.action(for: event(6, .command)))  // ⌘Z
    }

    /// 带 Control / Option 的组合是系统的，别抢
    func testSystemModifiersPassThrough() {
        XCTAssertNil(PinShortcuts.action(for: event(15, .option)))
        XCTAssertNil(PinShortcuts.action(for: event(15, .control)))
    }
}

/// 画布在贴图窗口里的两种状态：只读（事件穿透）和编辑（吃掉事件、拦住窗口拖动）。
@MainActor
final class PinCanvasInteractivityTests: XCTestCase {
    private func makeCanvas() -> AnnotateCanvasView {
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let canvas = AnnotateCanvasView(image: context.makeImage()!, style: AnnotateStyle())
        canvas.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = canvas
        return canvas
    }

    func testReadOnlyCanvasLetsEventsThrough() {
        let canvas = makeCanvas()
        canvas.interactive = false
        XCTAssertNil(canvas.hitTest(CGPoint(x: 100, y: 50)), "只读时事件要落到下面的贴图视图")
        XCTAssertTrue(canvas.mouseDownCanMoveWindow, "只读时拖拽应该移动窗口")
    }

    func testEditingCanvasTakesEventsAndBlocksWindowDrag() {
        let canvas = makeCanvas()
        canvas.interactive = true
        XCTAssertTrue(canvas.hitTest(CGPoint(x: 100, y: 50)) === canvas)
        XCTAssertFalse(canvas.mouseDownCanMoveWindow, "编辑时拖拽必须画图，不能搬窗口")
    }

    /// 宿主截键之后，画布自己的 `r`（OCR）不该再触发。
    func testKeyInterceptorWinsOverCanvasKeymap() {
        let canvas = makeCanvas()
        var commands: [AnnotateCommand] = []
        canvas.onCommand = { commands.append($0) }

        // 没有拦截时：r 是 OCR
        canvas.keyDown(with: keyEvent(15))
        XCTAssertEqual(commands.count, 1)

        // 拦截之后：一个命令都不发
        commands.removeAll()
        canvas.keyInterceptor = { _ in true }
        canvas.keyDown(with: keyEvent(15))
        XCTAssertTrue(commands.isEmpty, "被宿主接管后画布不该再按自己的键位表处理")
    }

    /// 收起工具条后，悬停高亮和光标形状都得跟着退——用户看到的是
    /// 「空格收起了工具条，鼠标还是十字，划到图元上还变成抓手」。
    func testLeavingEditingDropsHoverAndCursor() {
        let canvas = makeCanvasWithRectangle()
        canvas.interactive = true
        canvas.mouseMoved(with: moveEvent(at: CGPoint(x: 100, y: 50)))
        XCTAssertNotNil(canvas.hoveredID, "编辑态划过图元要亮")
        XCTAssertTrue(canvas.currentCursor === NSCursor.openHand)

        canvas.interactive = false
        XCTAssertNil(canvas.hoveredID, "退标注要把悬停清掉")
        XCTAssertTrue(canvas.currentCursor === NSCursor.arrow, "退标注要回到箭头")
    }

    /// 追踪区不看 `hitTest`：只读态的 `mouseMoved` 照样送到画布，
    /// 画布必须自己闭眼，否则已经「不归它管」的区域还在改光标。
    func testReadOnlyCanvasIgnoresHover() {
        let canvas = makeCanvasWithRectangle()
        canvas.interactive = false
        canvas.mouseMoved(with: moveEvent(at: CGPoint(x: 100, y: 50)))
        XCTAssertNil(canvas.hoveredID)
        XCTAssertTrue(canvas.currentCursor === NSCursor.arrow)
    }

    private func makeCanvasWithRectangle() -> AnnotateCanvasView {
        let canvas = makeCanvas()
        canvas.document.add(Annotation(kind: .rectangle(CGRect(x: 10, y: 10, width: 180, height: 80)),
                                       style: canvas.style))
        return canvas
    }

    private func moveEvent(at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 0, pressure: 0)!
    }

    private func keyEvent(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil, characters: "r",
                         charactersIgnoringModifiers: "r", isARepeat: false, keyCode: keyCode)!
    }
}

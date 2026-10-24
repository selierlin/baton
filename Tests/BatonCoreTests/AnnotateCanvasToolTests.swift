import AppKit
import CoreGraphics
import XCTest
@testable import BatonCore

/// 画布交互：
/// - 绘制工具落笔后不留选中框
/// - 悬停已有图元有反馈，单击选中，拖动照常画新的
/// - 选中后拖控制点改几何、拖本体整体移动、方向键微调
@MainActor
final class AnnotateCanvasToolTests: XCTestCase {
    private let side: CGFloat = 200

    private func makeImage(size: Int = 200) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    private func makeCanvas() -> (AnnotateCanvasView, NSWindow) {
        let canvas = AnnotateCanvasView(image: makeImage(), style: AnnotateStyle())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: side, height: side),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        return (canvas, window)
    }

    /// 图片坐标（左上原点、y 向下）→ 窗口坐标（左下原点）。画布 1:1 显示，只差一次翻转。
    private func windowPoint(_ image: CGPoint) -> CGPoint {
        CGPoint(x: image.x, y: side - image.y)
    }

    private func mouse(_ type: NSEvent.EventType, at image: CGPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: windowPoint(image), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)
    }

    private func send(_ canvas: AnnotateCanvasView, _ window: NSWindow,
                      _ type: NSEvent.EventType, at image: CGPoint) {
        guard let event = mouse(type, at: image, in: window) else {
            XCTFail("构造 \(type) 事件失败")
            return
        }
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        case .leftMouseUp: canvas.mouseUp(with: event)
        case .mouseMoved: canvas.mouseMoved(with: event)
        default: break
        }
    }

    private func drag(_ canvas: AnnotateCanvasView, in window: NSWindow,
                      from start: CGPoint, to end: CGPoint) {
        send(canvas, window, .leftMouseDown, at: start)
        send(canvas, window, .leftMouseDragged, at: end)
        send(canvas, window, .leftMouseUp, at: end)
    }

    private func click(_ canvas: AnnotateCanvasView, in window: NSWindow, at point: CGPoint) {
        send(canvas, window, .leftMouseDown, at: point)
        send(canvas, window, .leftMouseUp, at: point)
    }

    private func key(_ canvas: AnnotateCanvasView, in window: NSWindow, code: UInt16) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: code) else {
            return XCTFail("构造按键事件失败")
        }
        canvas.keyDown(with: event)
    }

    /// 画一条箭头（20,20）→（140,90），斜线中点大约在（80,55）。
    private func drawArrow() -> (AnnotateCanvasView, NSWindow) {
        let (canvas, window) = makeCanvas()
        canvas.tool = .flatArrow
        drag(canvas, in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 140, y: 90))
        return (canvas, window)
    }

    // MARK: - 落笔

    func testDrawArrowLeavesNoSelection() {
        let (canvas, _) = drawArrow()
        XCTAssertEqual(canvas.document.annotations.count, 1)
        XCTAssertNil(canvas.document.selection, "箭头画完后不应留下外接四边形选中框")
    }

    func testDrawRectangleLeavesNoSelection() {
        let (canvas, window) = makeCanvas()
        canvas.tool = .rectangle
        drag(canvas, in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 100))

        XCTAssertEqual(canvas.document.annotations.count, 1)
        XCTAssertNil(canvas.document.selection)
    }

    // MARK: - 悬停与选中

    func testHoverTracksAnnotationUnderCursor() {
        let (canvas, window) = drawArrow()
        let arrow = canvas.document.annotations[0]

        send(canvas, window, .mouseMoved, at: CGPoint(x: 80, y: 55))
        XCTAssertEqual(canvas.hoveredID, arrow.id, "鼠标移到箭头上要有悬停反馈")

        send(canvas, window, .mouseMoved, at: CGPoint(x: 170, y: 20))
        XCTAssertNil(canvas.hoveredID, "离开图元要清掉悬停态")
    }

    func testClickSelectsExistingArrowWhileArrowToolActive() {
        let (canvas, window) = drawArrow()
        let arrow = canvas.document.annotations[0]

        click(canvas, in: window, at: CGPoint(x: 80, y: 55))

        XCTAssertEqual(canvas.document.selection, arrow.id, "箭头工具下单击已有图元也要能选中")
        XCTAssertEqual(canvas.document.annotations.count, 1, "单击不该再落一条新箭头")
    }

    func testDragFromExistingArrowStillDrawsNewOne() {
        let (canvas, window) = drawArrow()
        let first = canvas.document.annotations[0]

        // 从已有箭头的线身上起笔，拖出去：应当画新的，而不是移动旧的
        drag(canvas, in: window, from: CGPoint(x: 80, y: 55), to: CGPoint(x: 160, y: 30))

        XCTAssertEqual(canvas.document.annotations.count, 2, "拖动仍然是画新图元")
        XCTAssertEqual(canvas.document.annotations[0], first, "旧箭头不该被挪动")
    }

    func testClickOnEmptyAreaClearsSelection() {
        let (canvas, window) = drawArrow()
        click(canvas, in: window, at: CGPoint(x: 80, y: 55))
        XCTAssertNotNil(canvas.document.selection)

        click(canvas, in: window, at: CGPoint(x: 180, y: 180))
        XCTAssertNil(canvas.document.selection)
    }

    // MARK: - 改几何

    func testDraggingSelectedElementMovesIt() {
        let (canvas, window) = drawArrow()
        click(canvas, in: window, at: CGPoint(x: 80, y: 55))

        drag(canvas, in: window, from: CGPoint(x: 80, y: 55), to: CGPoint(x: 100, y: 75))

        guard case .arrow(let start, let end, _) = canvas.document.annotations[0].kind else {
            return XCTFail("图元类型变了")
        }
        XCTAssertEqual(start.x, 40, accuracy: 0.01)
        XCTAssertEqual(start.y, 40, accuracy: 0.01)
        XCTAssertEqual(end.x, 160, accuracy: 0.01)
        XCTAssertEqual(end.y, 110, accuracy: 0.01)
        XCTAssertEqual(canvas.document.annotations.count, 1, "整体移动不该多出图元")
    }

    func testDraggingTailHandleResizesArrow() {
        let (canvas, window) = drawArrow()
        click(canvas, in: window, at: CGPoint(x: 80, y: 55))

        // 起点手柄（20,20）拖到（40,40）
        drag(canvas, in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 40, y: 40))

        guard case .arrow(let start, let end, _) = canvas.document.annotations[0].kind else {
            return XCTFail("图元类型变了")
        }
        XCTAssertEqual(start.x, 40, accuracy: 0.01)
        XCTAssertEqual(start.y, 40, accuracy: 0.01)
        XCTAssertEqual(end.x, 140, accuracy: 0.01, "拖尾端不该动到头")
        XCTAssertEqual(end.y, 90, accuracy: 0.01)
    }

    func testArrowKeysNudgeSelectedElement() {
        let (canvas, window) = drawArrow()
        click(canvas, in: window, at: CGPoint(x: 80, y: 55))

        key(canvas, in: window, code: 124) // →
        key(canvas, in: window, code: 124) // →
        key(canvas, in: window, code: 126) // ↑

        guard case .arrow(let start, _, _) = canvas.document.annotations[0].kind else {
            return XCTFail("图元类型变了")
        }
        XCTAssertEqual(start.x, 22, accuracy: 0.01, "右移两次 = 2 像素")
        XCTAssertEqual(start.y, 19, accuracy: 0.01, "上移一次 = 1 像素")
    }

    func testDeleteRemovesSelectedElement() {
        let (canvas, window) = drawArrow()
        click(canvas, in: window, at: CGPoint(x: 80, y: 55))

        key(canvas, in: window, code: 51) // Delete

        XCTAssertTrue(canvas.document.annotations.isEmpty)
        XCTAssertTrue(canvas.document.canUndo)
    }
}

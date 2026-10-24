import AppKit
import CoreGraphics
import XCTest
@testable import BatonCore

/// 选区调整：拖手柄改尺寸、方向键移/扩缩，以及它和「画图元」的边界。
///
/// 这里驱动的是真实 mouseDown/Dragged/Up 和 keyDown，
/// 所以能覆盖「手柄优先级」「拖手柄不落笔」这类只在事件序列里才暴露的问题。
@MainActor
final class SelectionAdjustTests: XCTestCase {
    private let side: CGFloat = 200
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func makeCanvas(selection: CGRect = CGRect(x: 0, y: 0, width: 200, height: 200))
    -> (AnnotateCanvasView, NSWindow) {
        let context = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let canvas = AnnotateCanvasView(image: context.makeImage()!, style: AnnotateStyle())
        canvas.adjustableSelection = true
        canvas.selectionFrame = selection
        canvas.selectionLimit = screen

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: side, height: side),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        return (canvas, window)
    }

    private func windowPoint(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x, y: side - local.y)
    }

    private func send(_ canvas: AnnotateCanvasView, _ window: NSWindow,
                      _ type: NSEvent.EventType, at local: CGPoint) {
        guard let event = NSEvent.mouseEvent(with: type, location: windowPoint(local),
                                             modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else {
            return XCTFail("构造 \(type) 事件失败")
        }
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        case .leftMouseUp: canvas.mouseUp(with: event)
        default: break
        }
    }

    private func key(_ canvas: AnnotateCanvasView, _ window: NSWindow,
                     code: UInt16, flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: code) else {
            return XCTFail("构造按键事件失败")
        }
        canvas.keyDown(with: event)
    }

    // MARK: - 拖手柄

    func testDraggingCornerHandleGrowsSelection() {
        let (canvas, window) = makeCanvas()
        var reported: [CGRect] = []
        canvas.onSelectionChange = { reported.append($0) }

        send(canvas, window, .leftMouseDown, at: CGPoint(x: 200, y: 200))
        send(canvas, window, .leftMouseDragged, at: CGPoint(x: 260, y: 260))
        send(canvas, window, .leftMouseUp, at: CGPoint(x: 260, y: 260))

        XCTAssertEqual(reported.count, 1, "一次拖动只该报一个最终值")
        XCTAssertEqual(reported.first, CGRect(x: 0, y: 0, width: 260, height: 260))
    }

    func testDraggingEdgeHandleMovesOnlyThatEdge() {
        let (canvas, window) = makeCanvas()
        var reported: CGRect?
        canvas.onSelectionChange = { reported = $0 }

        // 左边中点 (0,100) → 右边，只该改 minX
        send(canvas, window, .leftMouseDown, at: CGPoint(x: 0, y: 100))
        send(canvas, window, .leftMouseDragged, at: CGPoint(x: 60, y: 100))
        send(canvas, window, .leftMouseUp, at: CGPoint(x: 60, y: 100))

        XCTAssertEqual(reported?.minX, 60)
        XCTAssertEqual(reported?.maxX, 200)
        XCTAssertEqual(reported?.minY, 0)
        XCTAssertEqual(reported?.maxY, 200)
    }

    func testDraggingHandleDoesNotDrawAnnotation() {
        let (canvas, window) = makeCanvas()
        canvas.tool = .rectangle

        // 从左上角手柄拖出去：如果没拦住，这一下会变成画一个矩形
        send(canvas, window, .leftMouseDown, at: CGPoint(x: 0, y: 0))
        send(canvas, window, .leftMouseDragged, at: CGPoint(x: 80, y: 80))
        send(canvas, window, .leftMouseUp, at: CGPoint(x: 80, y: 80))

        XCTAssertTrue(canvas.document.annotations.isEmpty, "拖选区手柄不该顺手画出一个矩形")
    }

    func testResizeStopsAtMinimumSize() {
        let (canvas, window) = makeCanvas()
        var reported: CGRect?
        canvas.onSelectionChange = { reported = $0 }

        send(canvas, window, .leftMouseDown, at: CGPoint(x: 200, y: 200))
        send(canvas, window, .leftMouseDragged, at: CGPoint(x: 0, y: 0))
        send(canvas, window, .leftMouseUp, at: CGPoint(x: 0, y: 0))

        XCTAssertEqual(reported?.width, SelectionGeometry.minSide)
        XCTAssertEqual(reported?.height, SelectionGeometry.minSide)
    }

    // MARK: - 方向键

    func testArrowMovesSelectionWhenNothingSelected() {
        let (canvas, window) = makeCanvas()
        var reported: CGRect?
        canvas.onSelectionChange = { reported = $0 }

        key(canvas, window, code: 124) // →
        XCTAssertEqual(reported, CGRect(x: 1, y: 0, width: 200, height: 200))

        // 第二次按键在已更新的位置上继续累加，不是回到起点
        reported = nil
        key(canvas, window, code: 125) // ↓
        XCTAssertEqual(reported, CGRect(x: 1, y: 1, width: 200, height: 200))
    }

    func testCommandArrowExtendsOneEdge() {
        // 选区放在屏幕中间：贴着屏幕边时外扩会被钳住，测不出增量的方向
        let (canvas, window) = makeCanvas(selection: CGRect(x: 100, y: 100, width: 200, height: 200))
        var reported: CGRect?
        canvas.onSelectionChange = { reported = $0 }

        key(canvas, window, code: 124, flags: .command) // ⌘→ 右边外扩
        XCTAssertEqual(reported, CGRect(x: 100, y: 100, width: 201, height: 200))

        reported = nil
        key(canvas, window, code: 126, flags: .command) // ⌘↑ 上边外扩
        XCTAssertEqual(reported, CGRect(x: 100, y: 99, width: 201, height: 201))
    }

    func testShiftArrowShrinksOneEdge() {
        let (canvas, window) = makeCanvas()
        var reported: CGRect?
        canvas.onSelectionChange = { reported = $0 }

        key(canvas, window, code: 124, flags: .shift) // ⇧→ 右边收缩
        XCTAssertEqual(reported, CGRect(x: 0, y: 0, width: 199, height: 200))
    }

    func testArrowMovesAnnotationWhenOneIsSelected() {
        // 回归：选中图元之后方向键必须还给图元，不能被选区抢走
        let (canvas, window) = makeCanvas()
        canvas.tool = .flatArrow
        send(canvas, window, .leftMouseDown, at: CGPoint(x: 20, y: 20))
        send(canvas, window, .leftMouseDragged, at: CGPoint(x: 140, y: 90))
        send(canvas, window, .leftMouseUp, at: CGPoint(x: 140, y: 90))

        guard let id = canvas.document.annotations.first?.id else { return XCTFail("没画出箭头") }
        canvas.document.select(id)
        let before = canvas.document.annotations[0].bounds
        var selectionMoved = false
        canvas.onSelectionChange = { _ in selectionMoved = true }

        key(canvas, window, code: 124) // →

        XCTAssertFalse(selectionMoved, "有选中图元时方向键不该动选区")
        XCTAssertEqual(canvas.document.annotations[0].bounds.minX, before.minX + 1)
    }
}

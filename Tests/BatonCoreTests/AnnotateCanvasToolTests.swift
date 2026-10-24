import AppKit
import CoreGraphics
import XCTest
@testable import BatonCore

/// 画布交互：绘制工具落笔后不该留下选中框。
///
/// 回归背景——`document.add` 会把新图元设为选中，而选中框是轴对齐矩形；
/// 箭头、直线这类斜向图元画完就多出一个外接四边形虚线框，Longshot 没有这个框。
@MainActor
final class AnnotateCanvasToolTests: XCTestCase {
    private func makeImage(size: Int = 200) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    /// 拖一条线：按下 → 拖到 → 抬手，坐标用窗口坐标。
    private func drag(_ canvas: AnnotateCanvasView, in window: NSWindow,
                      from start: CGPoint, to end: CGPoint) {
        let events: [(NSEvent.EventType, CGPoint)] = [
            (.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end),
        ]
        for (type, point) in events {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else {
                XCTFail("构造 \(type) 事件失败")
                return
            }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
    }

    private func makeCanvas() -> (AnnotateCanvasView, NSWindow) {
        let canvas = AnnotateCanvasView(image: makeImage(), style: AnnotateStyle())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        return (canvas, window)
    }

    func testDrawArrowLeavesNoSelection() {
        let (canvas, window) = makeCanvas()
        canvas.tool = .flatArrow
        drag(canvas, in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 140, y: 90))

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

    func testSelectToolStillSelectsOnClick() {
        let (canvas, window) = makeCanvas()
        canvas.tool = .rectangle
        drag(canvas, in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 100))

        canvas.tool = .select
        drag(canvas, in: window, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 60, y: 60))

        XCTAssertEqual(canvas.document.selection, canvas.document.annotations.first?.id,
                       "选择工具点中元素仍要有选中框")
    }
}

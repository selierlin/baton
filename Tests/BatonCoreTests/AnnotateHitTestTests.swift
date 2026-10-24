import CoreGraphics
import XCTest
@testable import BatonCore

/// 命中测试：按图形自身几何判，不按外接矩形。
///
/// 背景——箭头、直线斜着放时外接矩形很大，用矩形判会让框内大片空白
/// 也「点得中」，那里恰恰是用户想继续画的地方。
final class AnnotateHitTestTests: XCTestCase {
    private let style = AnnotateStyle()

    func testArrowIgnoresBoundingBoxCorners() {
        let arrow = Annotation(kind: .arrow(start: CGPoint(x: 0, y: 0),
                                            end: CGPoint(x: 100, y: 100),
                                            sinkTail: false),
                               style: style)
        XCTAssertTrue(arrow.contains(CGPoint(x: 50, y: 50), tolerance: 4), "线身上要能点中")
        XCTAssertFalse(arrow.contains(CGPoint(x: 90, y: 10), tolerance: 4),
                       "外接框的另一角离斜线很远，不该命中")
    }

    func testStrokeHitsAlongPolylineOnly() {
        let stroke = Annotation(kind: .stroke(points: [CGPoint(x: 0, y: 0),
                                                      CGPoint(x: 100, y: 0),
                                                      CGPoint(x: 100, y: 100)]),
                                style: style)
        XCTAssertTrue(stroke.contains(CGPoint(x: 50, y: 2), tolerance: 4))
        XCTAssertTrue(stroke.contains(CGPoint(x: 100, y: 60), tolerance: 4))
        XCTAssertFalse(stroke.contains(CGPoint(x: 40, y: 60), tolerance: 4))
    }

    func testRectangleInteriorIsHittable() {
        let rect = Annotation(kind: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 80)),
                              style: style)
        XCTAssertTrue(rect.contains(CGPoint(x: 50, y: 40), tolerance: 4), "框内按下要能选中")
        XCTAssertFalse(rect.contains(CGPoint(x: 120, y: 40), tolerance: 4))
    }

    func testEllipseCornersAreNotHittable() {
        let ellipse = Annotation(kind: .ellipse(CGRect(x: 0, y: 0, width: 100, height: 100)),
                                 style: style)
        XCTAssertTrue(ellipse.contains(CGPoint(x: 50, y: 50), tolerance: 2))
        XCTAssertFalse(ellipse.contains(CGPoint(x: 2, y: 2), tolerance: 2),
                       "外接框的角在椭圆外，不该命中")
    }

    func testTextHitsItsInkBox() {
        let text = Annotation(kind: .text(origin: CGPoint(x: 10, y: 10), string: "标注"),
                              style: style, tool: .text)
        let size = AnnotateRenderer.textSize("标注", style: style)
        XCTAssertTrue(text.contains(CGPoint(x: 10 + size.width / 2, y: 10 + size.height / 2),
                                    tolerance: 2))
        XCTAssertFalse(text.contains(CGPoint(x: 10 + size.width + 40, y: 10), tolerance: 2))
    }

    func testResizeHandlesMatchCapability() {
        let text = Annotation(kind: .text(origin: .zero, string: "a"), style: style)
        XCTAssertFalse(text.supportsResize)
        XCTAssertTrue(text.editableHandles.isEmpty, "点不动的手柄不该画出来")

        let arrow = Annotation(kind: .arrow(start: .zero, end: CGPoint(x: 40, y: 40), sinkTail: false),
                               style: style)
        XCTAssertEqual(arrow.editableHandles, SelectionHandle.line, "箭头只有头尾两个点")

        let rect = Annotation(kind: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)), style: style)
        XCTAssertEqual(rect.editableHandles.count, 8, "矩形四条边加四个角")
    }
}

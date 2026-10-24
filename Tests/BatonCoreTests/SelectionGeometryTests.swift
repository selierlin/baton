import CoreGraphics
import XCTest
@testable import BatonCore

/// 选区几何：拖点、平移、单边扩缩。
///
/// 这些算错不会崩，只会表现成「拖动时跳一下」「贴边缩不回去」，
/// 肉眼很难定位，所以把边界条件全部钉成断言。
final class SelectionGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let rect = CGRect(x: 100, y: 100, width: 200, height: 150)

    func testAnchorPointsSitOnEdgesAndCorners() {
        XCTAssertEqual(SelectionGeometry.point(of: .topLeft, in: rect), CGPoint(x: 100, y: 100))
        XCTAssertEqual(SelectionGeometry.point(of: .topRight, in: rect), CGPoint(x: 300, y: 100))
        XCTAssertEqual(SelectionGeometry.point(of: .bottomLeft, in: rect), CGPoint(x: 100, y: 250))
        XCTAssertEqual(SelectionGeometry.point(of: .bottomRight, in: rect), CGPoint(x: 300, y: 250))
        XCTAssertEqual(SelectionGeometry.point(of: .top, in: rect), CGPoint(x: 200, y: 100))
        XCTAssertEqual(SelectionGeometry.point(of: .left, in: rect), CGPoint(x: 100, y: 175))
    }

    func testCornerHitWinsOverEdgeHit() {
        // 左上角点同时落在「左边中点」的容差之外，但四个角与四条边中点在同一坐标系，
        // 这里验证的是优先级：贴着角按下去必须判成角，否则拖起来会变成单边缩放。
        let nearCorner = CGPoint(x: 101, y: 101)
        XCTAssertEqual(SelectionGeometry.anchor(at: nearCorner, in: rect, tolerance: 6), .topLeft)
        let nearEdge = CGPoint(x: 200, y: 99)
        XCTAssertEqual(SelectionGeometry.anchor(at: nearEdge, in: rect, tolerance: 6), .top)
    }

    func testPointFarFromRectHitsNothing() {
        XCTAssertNil(SelectionGeometry.anchor(at: CGPoint(x: 500, y: 500), in: rect, tolerance: 6))
        // 选区内部但离所有手柄都远：不算命中（内部拖拽是画图元，不是拖选区）
        XCTAssertNil(SelectionGeometry.anchor(at: CGPoint(x: 200, y: 175), in: rect, tolerance: 6))
    }

    func testResizeKeepsOppositeCornerFixed() {
        let result = SelectionGeometry.resized(rect, anchor: .bottomRight,
                                               to: CGPoint(x: 400, y: 350), limit: screen)
        XCTAssertEqual(result.minX, 100)
        XCTAssertEqual(result.minY, 100)
        XCTAssertEqual(result.maxX, 400)
        XCTAssertEqual(result.maxY, 350)
    }

    func testResizeEdgeOnlyMovesThatEdge() {
        let result = SelectionGeometry.resized(rect, anchor: .top,
                                               to: CGPoint(x: 999, y: 50), limit: screen)
        XCTAssertEqual(result.minX, 100, "拖上边中点左右不该动")
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.minY, 50)
        XCTAssertEqual(result.maxY, 250)
    }

    func testResizeStopsAtMinimumSide() {
        let result = SelectionGeometry.resized(rect, anchor: .bottomRight,
                                               to: CGPoint(x: 0, y: 0), limit: screen)
        XCTAssertEqual(result.width, SelectionGeometry.minSide)
        XCTAssertEqual(result.height, SelectionGeometry.minSide)
        XCTAssertEqual(result.minX, 100, "对边不动")
        XCTAssertEqual(result.minY, 100)
    }

    func testResizeIsClampedToLimit() {
        let result = SelectionGeometry.resized(rect, anchor: .topLeft,
                                               to: CGPoint(x: -50, y: -50), limit: screen)
        XCTAssertEqual(result.minX, 0)
        XCTAssertEqual(result.minY, 0)
        XCTAssertEqual(result.maxX, 300)
        XCTAssertEqual(result.maxY, 250)
    }

    func testMoveKeepsSizeAndStopsAtScreenEdge() {
        let moved = SelectionGeometry.moved(rect, dx: 10, dy: -20, limit: screen)
        XCTAssertEqual(moved.origin, CGPoint(x: 110, y: 80))
        XCTAssertEqual(moved.size, rect.size)

        let pushed = SelectionGeometry.moved(rect, dx: 10_000, dy: 10_000, limit: screen)
        XCTAssertEqual(pushed.maxX, screen.maxX)
        XCTAssertEqual(pushed.maxY, screen.maxY)
        XCTAssertEqual(pushed.size, rect.size)
    }

    func testInsetExtendsAndShrinksOneEdge() {
        let wider = SelectionGeometry.inset(rect, edge: .right, by: 25, limit: screen)
        XCTAssertEqual(wider.maxX, 325)
        XCTAssertEqual(wider.minX, 100)

        let narrower = SelectionGeometry.inset(rect, edge: .right, by: -25, limit: screen)
        XCTAssertEqual(narrower.maxX, 275)
        XCTAssertEqual(narrower.minX, 100)
    }

    func testInsetStopsAtMinimumAndLimit() {
        let collapsed = SelectionGeometry.inset(rect, edge: .top, by: -10_000, limit: screen)
        XCTAssertEqual(collapsed.height, SelectionGeometry.minSide)
        XCTAssertEqual(collapsed.maxY, 250, "底边不动")

        let over = SelectionGeometry.inset(rect, edge: .left, by: 10_000, limit: screen)
        XCTAssertEqual(over.minX, 0, "不越过屏幕左边界")
    }

    func testEdgeKeyMappingRequiresExactlyOneModifier() {
        XCTAssertEqual(SelectionGeometry.edge(forKeyCode: 126, command: true, shift: false), .top)
        XCTAssertEqual(SelectionGeometry.edge(forKeyCode: 125, command: false, shift: true), .bottom)
        XCTAssertNil(SelectionGeometry.edge(forKeyCode: 126, command: true, shift: true),
                     "两个修饰键同时按下时语义含糊，不做")
        XCTAssertNil(SelectionGeometry.edge(forKeyCode: 126, command: false, shift: false),
                     "没有修饰键时是平移，不是扩缩")
        XCTAssertNil(SelectionGeometry.edge(forKeyCode: 36, command: true, shift: false))
    }
}

/// 手柄路径：8 个方块，位置骑在选区边界上。
///
/// 手柄画在覆盖层宿主上（不是画布内），所以位置必须是「边界 ± 半个手柄」，
/// 中心落在边线上；这里把它钉死，免得以后调尺寸时整体偏移。
final class SelectionChromeTests: XCTestCase {
    func testEightHandlesSitOnEdgesAndCorners() {
        let rect = CGRect(x: 100, y: 50, width: 200, height: 100)
        let boxes = SelectionChrome.handles(in: rect)

        XCTAssertEqual(boxes.count, 8, "四角 + 四边中点，中心那一格不画")
        for box in boxes {
            XCTAssertEqual(box.width, SelectionChrome.handleSide, accuracy: 0.01)
            XCTAssertEqual(box.height, SelectionChrome.handleSide, accuracy: 0.01)
        }

        // 每个手柄的中心必须正好落在选区边界或角上
        let centers = boxes.map { CGPoint(x: $0.midX, y: $0.midY) }
        XCTAssertTrue(centers.contains { abs($0.x - rect.minX) < 0.01 && abs($0.y - rect.minY) < 0.01 })
        XCTAssertTrue(centers.contains { abs($0.x - rect.maxX) < 0.01 && abs($0.y - rect.maxY) < 0.01 })
        XCTAssertTrue(centers.contains { abs($0.x - rect.midX) < 0.01 && abs($0.y - rect.minY) < 0.01 })
        XCTAssertTrue(centers.contains { abs($0.x - rect.maxX) < 0.01 && abs($0.y - rect.midY) < 0.01 })
        // 中心不该有手柄：那里是图元的点击区
        XCTAssertFalse(centers.contains { abs($0.x - rect.midX) < 0.01 && abs($0.y - rect.midY) < 0.01 })
    }

    func testPathCoversAllHandles() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 20)
        let path = SelectionChrome.path(in: rect)
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.boundingBox.minX, -SelectionChrome.handleSide / 2, accuracy: 0.01,
                       "手柄向外溢出半个身位，这正是它不能画在画布里的原因")
        XCTAssertEqual(path.boundingBox.maxX, 40 + SelectionChrome.handleSide / 2, accuracy: 0.01)
    }
}

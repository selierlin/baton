import CoreGraphics
import XCTest
@testable import BatonCore

/// 抽屉展开不能顶出屏幕：这几个数字直接决定 Tab 之后窗口是不是被裁掉。
final class PanelGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    /// 列表居中、右边装得下抽屉：位置不动。
    func testCenteredPanelKeepsPosition() {
        XCTAssertEqual(PanelGeometry.width(list: 580, drawer: 360, screen: screen), 940)
        XCTAssertEqual(PanelGeometry.originX(current: 430, width: 940, screen: screen), 430)
    }

    /// 面板靠在右边：整体左移，右边留出边距。
    func testPanelNearRightEdgeMovesLeft() {
        let x = PanelGeometry.originX(current: 900, width: 940, screen: screen)
        XCTAssertEqual(x, 1440 - PanelGeometry.margin - 940)
        XCTAssertEqual(x + 940, 1440 - PanelGeometry.margin)
    }

    /// 屏幕太窄：抽屉被压窄，而不是把窗口推出去。
    func testNarrowScreenShrinksDrawer() {
        let narrow = CGRect(x: 0, y: 0, width: 800, height: 600)
        let width = PanelGeometry.width(list: 580, drawer: 360, screen: narrow)
        XCTAssertEqual(width, 800 - PanelGeometry.margin * 2)
        XCTAssertGreaterThan(width, 580, "抽屉可以窄，但不能把列表挤掉")

        let x = PanelGeometry.originX(current: 0, width: width, screen: narrow)
        XCTAssertEqual(x, PanelGeometry.margin)
        XCTAssertEqual(x + width, 800 - PanelGeometry.margin)
    }

    /// 左边也不够放时贴左边，不能变成负数。
    func testTooWideFallsBackToLeftEdge() {
        let tiny = CGRect(x: 0, y: 0, width: 600, height: 600)
        let width = PanelGeometry.width(list: 580, drawer: 360, screen: tiny)
        XCTAssertEqual(width, 580, "压到列表宽度就停，不然列表本身没法用")
        XCTAssertEqual(PanelGeometry.originX(current: 300, width: width, screen: tiny),
                       PanelGeometry.margin)
    }

    /// 收起后按列表宽度收，右边靠边会往左挪回来。
    func testCollapsedPanelIsPulledBackOnScreen() {
        XCTAssertEqual(PanelGeometry.originX(current: 1200, width: 580, screen: screen),
                       1440 - PanelGeometry.margin - 580)
    }
}

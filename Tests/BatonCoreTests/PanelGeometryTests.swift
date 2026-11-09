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

    // MARK: - 呼出落点

    private let size = CGSize(width: 580, height: 640)

    /// 没有保存位置：这块屏上沿居中，距顶 80。
    func testFirstRunCentersOnScreenTop() {
        let origin = PanelGeometry.launchOrigin(saved: nil, size: size, screen: screen)
        XCTAssertEqual(origin.x, 1440 / 2 - 290)
        XCTAssertEqual(origin.y, 875 - 80 - 640)
    }

    /// 保存位置就在这块屏：沿用，不再回默认位。
    func testSavedOriginOnSameScreenIsReused() {
        let saved = CGPoint(x: 120, y: 200)
        XCTAssertEqual(PanelGeometry.launchOrigin(saved: saved, size: size, screen: screen), saved)
    }

    /// 保存位置属于另一块屏：落到当前屏默认位，而不是把人拉回去。
    func testSavedOriginOnOtherScreenFallsBackToCurrentScreen() {
        let saved = CGPoint(x: 1600, y: 200)
        let origin = PanelGeometry.launchOrigin(saved: saved, size: size, screen: screen)
        XCTAssertEqual(origin.x, 1440 / 2 - 290)
        XCTAssertEqual(origin.y, 875 - 80 - 640)
    }

    /// 副屏在主屏左侧（负坐标）：默认位要跟着那块屏走，不能算到主屏上。
    func testLeftSideScreenUsesItsOwnCoordinates() {
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 875)
        let origin = PanelGeometry.launchOrigin(saved: nil, size: size, screen: left)
        XCTAssertEqual(origin.x, -1440 + 720 - 290)
        XCTAssertEqual(origin.y, 155)
    }

    /// 保存位置贴边但中心还在屏内：收回边距，不要顶出屏幕。
    func testSavedOriginNearEdgeIsClamped() {
        let saved = CGPoint(x: -100, y: 100)
        let origin = PanelGeometry.launchOrigin(saved: saved, size: size, screen: screen)
        XCTAssertEqual(origin.x, PanelGeometry.margin)
        XCTAssertEqual(origin.y, 100)
    }

    /// 副屏比主屏矮：默认位仍要整窗可见。
    func testShorterScreenKeepsPanelInside() {
        let short = CGRect(x: 0, y: 0, width: 1280, height: 700)
        let origin = PanelGeometry.launchOrigin(saved: nil, size: size, screen: short)
        XCTAssertGreaterThanOrEqual(origin.y, short.minY + PanelGeometry.margin)
        XCTAssertLessThanOrEqual(origin.y + size.height, short.maxY - PanelGeometry.margin)
    }
}

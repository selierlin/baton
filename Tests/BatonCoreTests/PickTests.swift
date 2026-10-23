import CoreGraphics
import XCTest
@testable import BatonCore

final class WindowPickerTests: XCTestCase {
    private func window(id: Int = 1,
                        pid: pid_t = 100,
                        owner: String = "App",
                        layer: Int = 0,
                        alpha: Double = 1,
                        bounds: CGRect,
                        title: String? = nil) -> WindowInfo {
        WindowInfo(windowID: id, ownerPID: pid, ownerName: owner,
                   title: title, layer: layer, alpha: alpha, bounds: bounds)
    }

    func testPicksFrontmostWindowContainingPoint() {
        let front = window(id: 1, owner: "Front", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let back = window(id: 2, owner: "Back", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))

        let hit = WindowPicker.pick(CGPoint(x: 400, y: 300), from: [front, back])
        XCTAssertEqual(hit?.windowID, 1)
    }

    func testPicksTopmostThatActuallyContainsPoint() {
        // 前面的窗口只覆盖左半边，右半边应落到后面的窗口
        let front = window(id: 1, bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        let back = window(id: 2, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))

        XCTAssertEqual(WindowPicker.pick(CGPoint(x: 200, y: 300), from: [front, back])?.windowID, 1)
        XCTAssertEqual(WindowPicker.pick(CGPoint(x: 1000, y: 300), from: [front, back])?.windowID, 2)
    }

    func testSkipsOwnProcess() {
        let own = window(id: 1, pid: 42, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let other = window(id: 2, pid: 43, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))

        let hit = WindowPicker.pick(CGPoint(x: 10, y: 10), from: [own, other], excludingPID: 42)
        XCTAssertEqual(hit?.windowID, 2)
    }

    func testSkipsMenuBarAndDockLayers() {
        let menuBar = window(id: 1, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1440, height: 24))
        XCTAssertNil(WindowPicker.pick(CGPoint(x: 700, y: 10), from: [menuBar]))
    }

    func testSkipsTransparentAndTinyWindows() {
        let invisible = window(id: 1, alpha: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let sliver = window(id: 2, bounds: CGRect(x: 0, y: 0, width: 20, height: 600))
        XCTAssertNil(WindowPicker.pick(CGPoint(x: 10, y: 10), from: [invisible]))
        XCTAssertNil(WindowPicker.pick(CGPoint(x: 10, y: 10), from: [sliver]))
    }

    func testReturnsNilOutsideEveryWindow() {
        let only = window(bounds: CGRect(x: 100, y: 100, width: 200, height: 200))
        XCTAssertNil(WindowPicker.pick(CGPoint(x: 10, y: 10), from: [only]))
    }

    func testDisplayLabelFallsBackToOwner() {
        let noTitle = window(owner: "Ghostty", bounds: .zero)
        XCTAssertEqual(noTitle.displayLabel, "Ghostty")

        let titled = window(owner: "访达", bounds: .zero, title: "下载")
        XCTAssertEqual(titled.displayLabel, "访达 — 下载")
    }

    // MARK: - 活动窗口

    /// 前台 App 可能有一堆附属窗口（工具面板、浮层），列表是「前到后」，
    /// 取第一个合格的就是它的主窗口；别的 App 的窗口再靠前也不能要。
    func testActiveWindowTakesFrontmostAppsFirstWindow() {
        let other = window(id: 9, pid: 200, owner: "Other",
                           bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let chrome = window(id: 7, pid: 100, owner: "Chrome",
                            bounds: CGRect(x: 100, y: 100, width: 1200, height: 800))
        let chromePanel = window(id: 8, pid: 100, owner: "Chrome",
                                 bounds: CGRect(x: 200, y: 200, width: 300, height: 200))

        let hit = WindowPicker.activeWindow(frontmostPID: 100, from: [other, chrome, chromePanel])
        XCTAssertEqual(hit?.windowID, 7)
    }

    /// 前台就是 Baton 自己（LSUIElement 打开设置窗时会出现）：不能截自己
    func testActiveWindowRejectsOwnProcess() {
        let own = window(id: 1, pid: 42, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertNil(WindowPicker.activeWindow(frontmostPID: 42, from: [own], excludingPID: 42))
    }

    func testActiveWindowSkipsIneligibleWindows() {
        // 只有菜单栏那种层级的窗口时，宁可返回 nil 也不截一条菜单栏
        let menuBar = window(id: 1, pid: 100, layer: 24,
                             bounds: CGRect(x: 0, y: 0, width: 1440, height: 24))
        XCTAssertNil(WindowPicker.activeWindow(frontmostPID: 100, from: [menuBar]))
    }
}

final class PickServiceClipTests: XCTestCase {
    func testClipsAcrossDisplayBoundary() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let spanning = CGRect(x: -200, y: 100, width: 2000, height: 400)

        let clipped = PickService.clip(spanning, to: display)
        XCTAssertEqual(clipped, CGRect(x: 0, y: 100, width: 1440, height: 400))
    }

    func testFullyOutsideIsRejected() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertNil(PickService.clip(CGRect(x: 2000, y: 0, width: 100, height: 100), to: display))
    }

    func testSubPixelSliverIsRejected() {
        let display = CGRect(x: 0, y: 0, width: 100, height: 100)
        // 只压到边界线，宽 0
        XCTAssertNil(PickService.clip(CGRect(x: 100, y: 0, width: 50, height: 50), to: display))
    }
}

import XCTest
@testable import BatonCore

final class SelectionOrderTests: XCTestCase {
    func testClickOrderIsKept() {
        // 先点第 3 行、再点第 1 行：粘贴栈必须是 3 → 1
        var order = SelectionOrder()
        order.sync(with: IndexSet(integer: 2))
        order.sync(with: IndexSet([0, 2]))
        XCTAssertEqual(order.rows, [2, 0])
    }

    func testDeselectRemovesRow() {
        var order = SelectionOrder()
        order.sync(with: IndexSet(integer: 0))
        order.sync(with: IndexSet([0, 1]))
        // ⌘ 再点一次第 2 行 = 取消选择
        order.sync(with: IndexSet(integer: 0))
        XCTAssertEqual(order.rows, [0])
    }

    func testSingleAddAppendsToTail() {
        var order = SelectionOrder()
        order.sync(with: IndexSet(integer: 1))
        order.sync(with: IndexSet([1, 5]))
        order.sync(with: IndexSet([1, 5, 3]))
        XCTAssertEqual(order.rows, [1, 5, 3])
    }

    func testShiftExpandingDownIsAscending() {
        var order = SelectionOrder()
        order.sync(with: IndexSet(integer: 3))
        // ⇧↓ 一路扩到第 6 行
        order.sync(with: IndexSet(3...6))
        XCTAssertEqual(order.rows, [3, 4, 5, 6])
    }

    func testShiftExpandingUpIsDescending() {
        var order = SelectionOrder()
        order.sync(with: IndexSet(integer: 3))
        // ⇧↑ 一路扩到第 0 行：手是先摸到 2，再到 1、0
        order.sync(with: IndexSet(0...3))
        XCTAssertEqual(order.rows, [3, 2, 1, 0])
    }

    func testFreshMultiSelectIsAscending() {
        // ⌘A：没有锚点，按行号从新到旧
        var order = SelectionOrder()
        order.sync(with: IndexSet(0...4))
        XCTAssertEqual(order.rows, [0, 1, 2, 3, 4])
    }

    func testReset() {
        var order = SelectionOrder()
        order.sync(with: IndexSet([0, 3]))
        order.reset()
        XCTAssertEqual(order.rows, [])
    }
}

import CoreGraphics
import XCTest
@testable import BatonCore

/// 改选区时图元整体平移。
///
/// 关键在于撤销栈也要跟着移：否则「画两笔 → 调大选区 → ⌘Z」会把上一笔
/// 撤回到旧坐标系下的位置，屏幕上看到的就是凭空错位。
///
/// 断言一律用「平移前后的差值」，不写死绝对坐标——`bounds` 会把描边算进去，
/// 写死数字会让测试在改线宽时无故失败。
final class AnnotateTranslateTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat) -> Annotation {
        Annotation(kind: .rectangle(CGRect(x: x, y: y, width: 30, height: 20)),
                   style: AnnotateStyle(), tool: .rectangle)
    }

    private func assertShifted(_ pairs: [(CGRect, CGRect)], dx: CGFloat, dy: CGFloat,
                               file: StaticString = #filePath, line: UInt = #line) {
        for (before, after) in pairs {
            XCTAssertEqual(after.minX, before.minX + dx, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(after.minY, before.minY + dy, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(after.size, before.size, file: file, line: line)
        }
    }

    func testTranslateAllMovesEveryAnnotation() {
        let document = AnnotateDocument()
        document.add(rect(10, 20))
        document.add(rect(100, 20))
        let before = document.annotations.map(\.bounds)

        document.translateAll(dx: 50, dy: 70)

        assertShifted(Array(zip(before, document.annotations.map(\.bounds))), dx: 50, dy: 70)
    }

    func testUndoAfterTranslateLandsInNewCoordinates() {
        let document = AnnotateDocument()
        document.add(rect(10, 20))
        document.add(rect(100, 20))
        let first = document.annotations[0].bounds

        document.translateAll(dx: 50, dy: 70)
        document.undo()

        XCTAssertEqual(document.annotations.count, 1)
        assertShifted([(first, document.annotations[0].bounds)], dx: 50, dy: 70)
    }

    func testRedoAfterTranslateLandsInNewCoordinates() {
        let document = AnnotateDocument()
        document.add(rect(10, 20))
        document.add(rect(100, 20))
        let before = document.annotations.map(\.bounds)

        document.translateAll(dx: 50, dy: 70)
        document.undo()
        document.redo()

        assertShifted(Array(zip(before, document.annotations.map(\.bounds))), dx: 50, dy: 70)
    }

    func testZeroOffsetIsNoOp() {
        let document = AnnotateDocument()
        document.add(rect(10, 20))
        let before = document.annotations[0].bounds
        document.translateAll(dx: 0, dy: 0)
        XCTAssertEqual(document.annotations[0].bounds, before)
    }
}

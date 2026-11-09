import AppKit
import XCTest
@testable import BatonCore

/// 列表上的键盘通路。
///
/// 面板的动作都在 `handle(command:)`，但原生入口只有搜索框的 `doCommandBy`。
/// 鼠标点过行之后第一响应者是表格，回车/ Esc / Tab / ⌫ 全部失效 ——
/// 多选连粘恰好要先点选再回车，所以这条必须钉死。
@MainActor
final class ClipboardPanelKeyTests: XCTestCase {
    func testReturnMapsToInsertNewline() {
        let table = ClipboardTableView()
        var received: Selector?
        table.onCommand = { received = $0; return true }

        table.keyDown(with: key(36, "\r"))

        XCTAssertEqual(received, #selector(NSResponder.insertNewline(_:)))
    }

    func testKeypadEnterAlsoPastes() {
        let table = ClipboardTableView()
        var received: Selector?
        table.onCommand = { received = $0; return true }

        table.keyDown(with: key(76, "\r"))

        XCTAssertEqual(received, #selector(NSResponder.insertNewline(_:)))
    }

    func testEscapeTabAndDeleteAreForwarded() {
        let cases: [(UInt16, Selector)] = [
            (53, #selector(NSResponder.cancelOperation(_:))),
            (48, #selector(NSResponder.insertTab(_:))),
            (51, #selector(NSResponder.deleteBackward(_:))),
        ]

        for (code, expected) in cases {
            let table = ClipboardTableView()
            var received: Selector?
            table.onCommand = { received = $0; return true }

            table.keyDown(with: key(code, ""))

            XCTAssertEqual(received, expected, "keyCode \(code)")
        }
    }

    /// 上下键必须留给 NSTableView：原生的扩选和滚动都靠它
    func testArrowKeysAreNotIntercepted() {
        for code: UInt16 in [125, 126] {
            let table = ClipboardTableView()
            var received: Selector?
            table.onCommand = { received = $0; return true }

            table.keyDown(with: key(code, ""))

            XCTAssertNil(received, "keyCode \(code) 不该被接管")
        }
    }

    /// ⌘ 组合留给系统（⌘A 全选、⌘C 复制）
    func testCommandCombosBypassHandler() {
        let table = ClipboardTableView()
        var received: Selector?
        table.onCommand = { received = $0; return true }

        table.keyDown(with: key(36, "\r", flags: .command))

        XCTAssertNil(received)
    }

    /// 处理器返回 false 时交回原生处理，不能吞掉事件
    func testUnhandledCommandFallsThrough() {
        let table = ClipboardTableView()
        table.onCommand = { _ in false }

        table.keyDown(with: key(36, "\r"))
    }

    private func key(_ code: UInt16, _ characters: String,
                     flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: flags,
                         timestamp: 0,
                         windowNumber: 0,
                         context: nil,
                         characters: characters,
                         charactersIgnoringModifiers: characters,
                         isARepeat: false,
                         keyCode: code)!
    }
}

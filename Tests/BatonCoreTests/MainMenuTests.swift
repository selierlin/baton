import AppKit
import XCTest
@testable import BatonCore

/// 主菜单不是给人看的，是给 ⌘V 用的：文本编辑的快捷键都由菜单项承载，
/// 没有这几条，设置页里的输入框就只能手敲。
///
/// 不在 `setUp` 里装菜单：Xcode 16 的 XCTest 把 `setUp` 算成非隔离的，
/// `@MainActor` 测试类里覆写它会直接编不过（CI 上已经撞过）。
@MainActor
final class MainMenuTests: XCTestCase {
    private func item(_ title: String, in menuTitle: String) -> NSMenuItem? {
        MainMenu.install()
        return NSApplication.shared.mainMenu?.items
            .first { $0.submenu?.title == menuTitle }?
            .submenu?.items
            .first { $0.title == title }
    }

    func testEditMenuCarriesPaste() throws {
        let paste = try XCTUnwrap(item("粘贴", in: "编辑"), "没有「编辑」菜单或粘贴项")
        XCTAssertEqual(paste.action, Selector(("paste:")))
        XCTAssertEqual(paste.keyEquivalent, "v")
        XCTAssertTrue(paste.keyEquivalentModifierMask.contains(.command))
    }

    func testEditMenuCoversTheOtherTextFieldShortcuts() throws {
        let expected: [(String, String, String)] = [
            ("剪切", "cut:", "x"),
            ("复制", "copy:", "c"),
            ("全选", "selectAll:", "a"),
        ]
        for (title, action, key) in expected {
            let entry = try XCTUnwrap(item(title, in: "编辑"), "缺少 \(title)")
            XCTAssertEqual(entry.action, Selector((action)), title)
            XCTAssertEqual(entry.keyEquivalent, key, title)
        }
    }

    /// ⌘Z 留在画布自己的 keyDown 里：菜单项会把按键截走，撤销就断了
    func testUndoIsNotTakenOverByTheMenu() {
        XCTAssertNil(item("撤销", in: "编辑"))
    }
}

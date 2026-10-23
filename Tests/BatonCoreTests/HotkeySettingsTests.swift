import Carbon.HIToolbox
import XCTest
@testable import BatonCore

final class HotkeySettingsTests: XCTestCase {
    func testDefaultCombosDoNotCollide() {
        let combos = HotkeyAction.allCases.map(\.defaultCombo)
        XCTAssertEqual(Set(combos).count, combos.count)
    }

    func testOverrideWinsAndFallsBackToDefault() {
        var settings = HotkeySettings.default
        XCTAssertEqual(settings.combo(for: .ruler), HotkeyAction.ruler.defaultCombo)

        let custom = KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | optionKey))
        settings.set(custom, for: .ruler)
        XCTAssertEqual(settings.combo(for: .ruler), custom)

        // 改回默认值应当删掉覆盖项，而不是把默认值也写进文件
        settings.set(HotkeyAction.ruler.defaultCombo, for: .ruler)
        XCTAssertNil(settings.overrides[HotkeyAction.ruler.rawValue])
        XCTAssertTrue(settings.overrides.isEmpty)
    }

    func testConflictFindsTheOtherAction() {
        var settings = HotkeySettings.default
        let ruler = settings.combo(for: .ruler)

        XCTAssertEqual(settings.conflict(of: ruler, ignoring: .pin), .ruler)
        // 和自己比不算冲突
        XCTAssertNil(settings.conflict(of: ruler, ignoring: .ruler))

        settings.set(KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey)),
                     for: .pin)
        XCTAssertNil(settings.conflict(of: KeyCombo(keyCode: UInt32(kVK_ANSI_M),
                                                   modifiers: UInt32(cmdKey)),
                                       ignoring: .pin))
    }

    func testStoreRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-hotkeys-\(UUID().uuidString)", isDirectory: true)
        let store = try HotkeySettingsStore(directory: dir)

        XCTAssertEqual(store.load(), .default)

        var settings = HotkeySettings.default
        settings.set(KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | shiftKey)),
                     for: .scroll)
        try store.save(settings)

        let reloaded = try HotkeySettingsStore(directory: dir).load()
        XCTAssertEqual(reloaded, settings)
        XCTAssertEqual(reloaded.combo(for: .scroll).display, "⌃⇧K")

        try? FileManager.default.removeItem(at: dir)
    }

    func testDisplayOrdersModifiersLikeApple() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_R),
                             modifiers: UInt32(cmdKey | optionKey | shiftKey | controlKey))
        XCTAssertEqual(combo.display, "⌃⌥⇧⌘R")
        XCTAssertEqual(HotkeyAction.ruler.defaultCombo.display, "⌥⌘R")
        XCTAssertEqual(HotkeyAction.clipboard.defaultCombo.display, "⇧⌘V")
    }

    /// 菜单右侧那一列：字母必须是**小写**，否则 AppKit 会当成大写再补一个 ⇧。
    func testMenuKeyEquivalentUsesLowercaseLetters() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(shiftKey | cmdKey))
        XCTAssertEqual(combo.menuKeyEquivalent, "y")
        XCTAssertEqual(combo.menuModifierMask, [.shift, .command])
        XCTAssertEqual(combo.display, "⇧⌘Y")
    }

    func testMenuKeyEquivalentForAllDefaultCombos() {
        for action in HotkeyAction.allCases {
            let combo = action.defaultCombo
            let key = combo.menuKeyEquivalent
            XCTAssertNotNil(key, "\(action.rawValue) 的默认键应当能渲染到菜单")
            XCTAssertEqual(key?.count, 1)
            XCTAssertFalse(combo.menuModifierMask.isEmpty)
        }
    }

    /// 数字键的 keycode 也是错位的（1=18、2=19…），别按顺序推。
    func testMenuKeyEquivalentForDigits() {
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey)).menuKeyEquivalent, "1")
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey)).menuKeyEquivalent, "5")
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(cmdKey)).menuKeyEquivalent, "0")
    }

    /// 认不出来的键（自定义键盘/扩展键）返回 nil，调用方据此留空而不是显示错字符。
    func testMenuKeyEquivalentForUnknownKeyIsNil() {
        XCTAssertNil(KeyCombo(keyCode: 200, modifiers: UInt32(cmdKey)).menuKeyEquivalent)
    }

    // MARK: - 注册后校验

    func testAuditFindsDuplicateCombos() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | optionKey))
        let warnings = HotkeyAudit.warnings(actions: [("区域标注", combo), ("截图贴图", combo)],
                                            system: [])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("区域标注"))
        XCTAssertTrue(warnings[0].contains("截图贴图"))
    }

    func testAuditFindsSystemSymbolicCollision() {
        // ⌘⇧3 = keycode 20 + cmd|shift：系统截屏全屏，Carbon 注册会成功但收不到
        let combo = KeyCombo(keyCode: 20, modifiers: UInt32(cmdKey | shiftKey))
        let system = [SystemSymbolicHotKey(keyCode: 20,
                                           modifiers: UInt32(cmdKey | shiftKey),
                                           enabled: true)]
        let warnings = HotkeyAudit.warnings(actions: [("区域截图", combo)], system: system)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("系统快捷键"))
    }

    /// 系统字典里会混进 `0x20000` 之类的杂位，比较前必须只留四个修饰位。
    func testAuditMasksExtraModifierBits() {
        let combo = KeyCombo(keyCode: 20, modifiers: UInt32(cmdKey | shiftKey))
        let system = [SystemSymbolicHotKey(keyCode: 20,
                                           modifiers: UInt32(cmdKey | shiftKey) | 0x20000,
                                           enabled: true)]
        XCTAssertEqual(HotkeyAudit.warnings(actions: [("区域截图", combo)], system: system).count, 1)
    }

    func testAuditIgnoresDisabledSystemHotkey() {
        let combo = KeyCombo(keyCode: 20, modifiers: UInt32(cmdKey | shiftKey))
        let system = [SystemSymbolicHotKey(keyCode: 20,
                                           modifiers: UInt32(cmdKey | shiftKey),
                                           enabled: false)]
        XCTAssertTrue(HotkeyAudit.warnings(actions: [("区域截图", combo)], system: system).isEmpty)
    }

    /// 默认那八个组合不该撞系统快捷键——撞了说明默认值就得改，这属于回归。
    func testDefaultCombosDoNotHitSystemShortcuts() {
        let actions = HotkeyAction.allCases.map { ($0.title, $0.defaultCombo) }
        XCTAssertTrue(HotkeyAudit.warnings(actions: actions).isEmpty)
    }
}

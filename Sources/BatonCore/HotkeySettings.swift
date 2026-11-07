import AppKit
import Carbon.HIToolbox
import Foundation

/// 可配置的全局热键。`rawValue` 就是存盘键，改名会让用户已有的配置失效。
public enum HotkeyAction: String, CaseIterable, Sendable {
    case annotate
    case pin
    case scroll
    case ruler
    case ocr
    case translateCapture
    case translateSelection
    case clipboard
    case fullScreen
    case lastArea
    case lastAreaSave
    case timed
    case lastShot
    case activeWindow
    case togglePins
    case recordArea
    case recordScreen
    case recordWindow
    case recordApp

    public var title: String {
        switch self {
        case .annotate: return "区域标注（截图）"
        case .pin: return "截图贴图"
        case .scroll: return "长截图"
        case .ruler: return "屏幕尺子"
        case .ocr: return "截图 OCR"
        case .translateCapture: return "截图翻译"
        case .translateSelection: return "划词翻译"
        case .clipboard: return "剪贴板历史"
        case .fullScreen: return "全屏截图"
        case .lastArea: return "截取上一次区域"
        case .lastAreaSave: return "上一次区域并保存"
        case .timed: return "延迟截图"
        case .lastShot: return "回溯上一次截图"
        case .activeWindow: return "截取活动窗口"
        case .togglePins: return "隐藏/显示所有贴图"
        case .recordArea: return "区域录制"
        case .recordScreen: return "全屏录制"
        case .recordWindow: return "窗口录制"
        case .recordApp: return "应用录制"
        }
    }

    /// 默认组合。`⌥⌘` 那批是为了避开 App 内常被占用的 `⇧⌘` 组合；
    /// 截图家族用 `⌃⌘ + 数字`，避开系统 `⇧⌘3/4/5`。
    public var defaultCombo: KeyCombo {
        switch self {
        case .annotate: return KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | optionKey))
        case .pin: return KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey))
        case .scroll: return KeyCombo(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey))
        case .ruler: return KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey))
        case .ocr: return KeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey | shiftKey))
        case .translateCapture: return KeyCombo(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(cmdKey | shiftKey))
        case .translateSelection: return KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey))
        case .clipboard: return KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
        case .fullScreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | controlKey))
        case .lastArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | controlKey))
        case .lastAreaSave: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | controlKey))
        case .timed: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | controlKey))
        case .lastShot: return KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | controlKey))
        case .activeWindow: return KeyCombo(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(cmdKey | controlKey))
        case .togglePins: return KeyCombo(keyCode: UInt32(kVK_ANSI_7), modifiers: UInt32(cmdKey | controlKey))
        case .recordArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(cmdKey | controlKey))
        case .recordScreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey | controlKey))
        case .recordWindow: return KeyCombo(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(cmdKey | controlKey))
        case .recordApp: return KeyCombo(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(cmdKey | controlKey))
        }
    }
}

/// 只存「改过的」那几个：默认值留在代码里，将来改默认值老用户也能拿到。
public struct HotkeySettings: Codable, Sendable, Equatable {
    public var overrides: [String: KeyCombo]
    /// 被取消绑定的动作：功能还在菜单里，只是不再占全局快捷键，也不会和谁撞。
    /// 存 rawValue 而不是 KeyCombo：恢复绑定时要能回到用户改过的那个组合，
    /// 而不是一声不响变回默认值。
    public var disabled: Set<String>

    public init(overrides: [String: KeyCombo] = [:], disabled: Set<String> = []) {
        self.overrides = overrides
        self.disabled = disabled
    }

    public static let `default` = HotkeySettings()

    // 旧文件只有 overrides 一个键；缺 disabled 要补空集合，不能让整份配置解码失败
    private enum CodingKeys: String, CodingKey {
        case overrides, disabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overrides = try container.decodeIfPresent([String: KeyCombo].self, forKey: .overrides) ?? [:]
        disabled = try container.decodeIfPresent(Set<String>.self, forKey: .disabled) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(overrides, forKey: .overrides)
        // 空集合不写，文件里只留真的取消过的那几个
        if !disabled.isEmpty {
            try container.encode(disabled, forKey: .disabled)
        }
    }

    public func combo(for action: HotkeyAction) -> KeyCombo {
        overrides[action.rawValue] ?? action.defaultCombo
    }

    /// 取消绑定过的动作不注册全局热键，也不参与重复/撞系统的校验
    public func isEnabled(_ action: HotkeyAction) -> Bool {
        !disabled.contains(action.rawValue)
    }

    /// 新组合若和别的动作撞了，返回被撞的那个动作。已取消绑定的不算占位。
    public func conflict(of combo: KeyCombo, ignoring action: HotkeyAction) -> HotkeyAction? {
        HotkeyAction.allCases.first {
            $0 != action && isEnabled($0) && self.combo(for: $0) == combo
        }
    }

    public mutating func set(_ combo: KeyCombo?, for action: HotkeyAction) {
        // 重新设一次就是「我要用它」，顺手解除取消绑定
        disabled.remove(action.rawValue)
        if let combo, combo != action.defaultCombo {
            overrides[action.rawValue] = combo
        } else {
            overrides.removeValue(forKey: action.rawValue)
        }
    }

    /// 取消绑定：不注册这个热键，但保留改过的组合，恢复时还用它。
    public mutating func unbind(_ action: HotkeyAction) {
        disabled.insert(action.rawValue)
    }

    /// 恢复绑定（回到取消之前用的那个组合）。
    public mutating func restore(_ action: HotkeyAction) {
        disabled.remove(action.rawValue)
    }
}

public struct HotkeySettingsStore: Sendable {
    public let url: URL

    public init(directory: URL? = nil) throws {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: true)
            dir = base.appendingPathComponent("Baton", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("hotkeys.json")
    }

    public func load() -> HotkeySettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(HotkeySettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: HotkeySettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

// MARK: - 展示与录入

public extension KeyCombo {
    /// 按 Apple 的习惯排：⌃⌥⇧⌘ + 键名。
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// 菜单右侧那一列快捷键。AppKit 只能靠 `keyEquivalent` + mask 渲染，
    /// 所以把硬件 keycode 反推成一个字符；字母统一小写，⇧ 交给 mask 负责，
    /// 否则 AppKit 会因为是大写再补一个 ⇧，显示成 ⇧⇧⌘Y。
    var menuKeyEquivalent: String? {
        Self.character(keyCode).map(String.init)
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        return mask
    }

    private static func character(_ keyCode: UInt32) -> Character? {
        if let letter = ansiLetter(keyCode) { return letter }
        switch Int(keyCode) {
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        case kVK_Space: return " "
        case kVK_Return: return Character(UnicodeScalar(NSCarriageReturnCharacter)!)
        case kVK_Tab: return Character(UnicodeScalar(NSTabCharacter)!)
        case kVK_Escape: return "\u{1B}"
        case kVK_Delete: return Character(UnicodeScalar(NSBackspaceCharacter)!)
        case kVK_ForwardDelete: return Character(UnicodeScalar(NSDeleteCharacter)!)
        case kVK_LeftArrow: return Character(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case kVK_RightArrow: return Character(UnicodeScalar(NSRightArrowFunctionKey)!)
        case kVK_UpArrow: return Character(UnicodeScalar(NSUpArrowFunctionKey)!)
        case kVK_DownArrow: return Character(UnicodeScalar(NSDownArrowFunctionKey)!)
        case kVK_F1: return Character(UnicodeScalar(NSF1FunctionKey)!)
        case kVK_F2: return Character(UnicodeScalar(NSF2FunctionKey)!)
        case kVK_F3: return Character(UnicodeScalar(NSF3FunctionKey)!)
        case kVK_F4: return Character(UnicodeScalar(NSF4FunctionKey)!)
        case kVK_F5: return Character(UnicodeScalar(NSF5FunctionKey)!)
        case kVK_F6: return Character(UnicodeScalar(NSF6FunctionKey)!)
        case kVK_F7: return Character(UnicodeScalar(NSF7FunctionKey)!)
        case kVK_F8: return Character(UnicodeScalar(NSF8FunctionKey)!)
        case kVK_F9: return Character(UnicodeScalar(NSF9FunctionKey)!)
        case kVK_F10: return Character(UnicodeScalar(NSF10FunctionKey)!)
        case kVK_F11: return Character(UnicodeScalar(NSF11FunctionKey)!)
        case kVK_F12: return Character(UnicodeScalar(NSF12FunctionKey)!)
        default: return nil
        }
    }

    /// keycode 0x00–0x0F 对应的字母（不是字母序，别用偏移量推算）。
    private static func ansiLetter(_ keyCode: UInt32) -> Character? {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "a"
        case kVK_ANSI_B: return "b"
        case kVK_ANSI_C: return "c"
        case kVK_ANSI_D: return "d"
        case kVK_ANSI_E: return "e"
        case kVK_ANSI_F: return "f"
        case kVK_ANSI_G: return "g"
        case kVK_ANSI_H: return "h"
        case kVK_ANSI_I: return "i"
        case kVK_ANSI_J: return "j"
        case kVK_ANSI_K: return "k"
        case kVK_ANSI_L: return "l"
        case kVK_ANSI_M: return "m"
        case kVK_ANSI_N: return "n"
        case kVK_ANSI_O: return "o"
        case kVK_ANSI_P: return "p"
        case kVK_ANSI_Q: return "q"
        case kVK_ANSI_R: return "r"
        case kVK_ANSI_S: return "s"
        case kVK_ANSI_T: return "t"
        case kVK_ANSI_U: return "u"
        case kVK_ANSI_V: return "v"
        case kVK_ANSI_W: return "w"
        case kVK_ANSI_X: return "x"
        case kVK_ANSI_Y: return "y"
        case kVK_ANSI_Z: return "z"
        default: return nil
        }
    }

    /// 从按键事件取组合。没有修饰键的普通字符不算热键（会把打字全吞掉）。
    init?(event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard modifiers != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    /// 硬件 keycode → 键名。与键盘布局无关，所以 Dvorak 上也显示同一个物理键。
    private static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        case kVK_Space: return "空格"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "键 \(keyCode)"
        }
    }
}

import Carbon.HIToolbox
import Foundation

/// 系统的「符号快捷键」（⌘⇧3 截图、⌘Tab、⌃↑ 调度中心…）。
///
/// 这些键由 WindowServer 先处理，第三方 App 的 Carbon 注册照样会返回成功，
/// 但事件永远送不到——表现为「热键设了却没反应」，而且没有任何错误可查。
public struct SystemSymbolicHotKey: Sendable, Equatable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let enabled: Bool

    public init(keyCode: UInt32, modifiers: UInt32, enabled: Bool) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.enabled = enabled
    }
}

public enum SystemHotkeys {
    /// Carbon 的四个修饰位。系统字典里还会带上 `0x20000` 之类的杂位，比较前必须掩掉。
    public static let modifierMask: UInt32 =
        UInt32(cmdKey | shiftKey | optionKey | controlKey)

    /// 读系统快捷键表。`CopySymbolicHotKeys` 返回的是 229 条记录（本机 macOS 15）。
    public static func load() -> [SystemSymbolicHotKey] {
        var raw: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&raw) == noErr,
              let array = raw?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            guard let code = entry["kHISymbolicHotKeyCode"] as? NSNumber,
                  let modifiers = entry["kHISymbolicHotKeyModifiers"] as? NSNumber else {
                return nil
            }
            let enabled = (entry["kHISymbolicHotKeyEnabled"] as? Bool) ?? false
            return SystemSymbolicHotKey(keyCode: code.uint32Value,
                                        modifiers: modifiers.uint32Value & modifierMask,
                                        enabled: enabled)
        }
    }
}

/// 注册之后的静态校验。
///
/// Carbon 没有「查我已注册了哪些键」的 API，所以「回读」只能做两件能查的事：
/// ① 自己这套组合里有没有重复；② 有没有和系统符号快捷键撞。
/// 剩下的「注册成功但收不到」（macOS 15 的老问题）由事件 tap 兜底，不在这里判。
public enum HotkeyAudit {
    /// 返回可直接展示/落日志的中文提示，空数组表示没发现问题。
    public static func warnings(actions: [(title: String, combo: KeyCombo)],
                                system: [SystemSymbolicHotKey] = SystemHotkeys.load()) -> [String] {
        var warnings: [String] = []

        for i in actions.indices {
            for j in actions.indices where j > i {
                guard actions[i].combo == actions[j].combo else { continue }
                warnings.append("「\(actions[i].title)」与「\(actions[j].title)」用了同一个组合 "
                                + actions[i].combo.display)
            }
        }

        for action in actions {
            let masked = action.combo.modifiers & SystemHotkeys.modifierMask
            let hit = system.contains {
                $0.enabled
                    && $0.keyCode == action.combo.keyCode
                    && ($0.modifiers & SystemHotkeys.modifierMask) == masked
            }
            if hit {
                warnings.append("「\(action.title)」\(action.combo.display) 与系统快捷键冲突，按下后可能没有反应")
            }
        }
        return warnings
    }
}

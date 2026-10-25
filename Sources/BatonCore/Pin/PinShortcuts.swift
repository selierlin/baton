import AppKit

/// 贴图窗口上的一次按键语义。
///
/// 名字和 Longshot 的 `pin*` 配置项一一对应，改之前先看一眼那边的键位表，
/// 别凭手感重新发明——贴图和截图共用一套键盘，重名的键含义必须是确定的。
enum PinKeyAction: Hashable {
    /// 空格：开关标注工具条（内置进入/退出标注）。
    case toggleEdit
    /// R：缩略图模式。
    case thumbnail
    /// `=` / `-`：缩放。
    case zoomIn
    case zoomOut
    /// ⌘`=` / ⌘`-`：不透明度（Longshot 把缩放的修饰键给了不透明度）。
    case opacityUp
    case opacityDown
    case copy
    case save
    case saveAndCopy
    /// Esc：编辑态退出编辑，只读态退出贴图，由调用方分情况。
    case escape
    /// 方向键：挪窗口。
    case nudge(dx: CGFloat, dy: CGFloat)
}

enum PinShortcuts {
    /// 方向键步长（点）。⇧ 走大步。
    static let nudgeStep: CGFloat = 1
    static let shiftNudgeStep: CGFloat = 10

    /// 一次按键 → 动作。认不出来的返回 nil，交回画布或响应链。
    ///
    /// 全程按 `keyCode` 判，不看字符：按下 ⇧ 会把 `=` 变成 `+`、⌥ 会改出特殊符号，
    /// 靠字符匹配在这些组合上都会漏。
    static func action(for event: NSEvent) -> PinKeyAction? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            switch event.keyCode {
            case 24: return .opacityUp        // ⌘=
            case 27: return .opacityDown      // ⌘-
            case 2: return flags.contains(.shift) ? .saveAndCopy : .save  // ⌘D / ⇧⌘D
            default: return nil
            }
        }

        // 带 Control / Option 的组合留给系统，不抢
        guard !flags.contains(.control), !flags.contains(.option) else { return nil }

        let step = flags.contains(.shift) ? shiftNudgeStep : nudgeStep
        switch event.keyCode {
        case 49: return .toggleEdit
        case 15: return .thumbnail
        case 24: return .zoomIn
        case 27: return .zoomOut
        case 36, 76: return .copy
        case 53: return .escape
        case 123: return .nudge(dx: -step, dy: 0)
        case 124: return .nudge(dx: step, dy: 0)
        case 125: return .nudge(dx: 0, dy: -step)
        case 126: return .nudge(dx: 0, dy: step)
        default: return nil
        }
    }
}

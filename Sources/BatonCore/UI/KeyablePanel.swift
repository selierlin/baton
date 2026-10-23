import AppKit

/// 无边界的可成为 key 的面板。
///
/// accessory（`LSUIElement`）App 的窗口默认拿不到键盘焦点，`canBecomeKey` 必须显式放开；
/// `canBecomeMain` 保持 false，否则会把菜单栏抢走。
public final class KeyablePanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

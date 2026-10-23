import AppKit

/// 面板底色。
///
/// 不用 vibrancy：`.behindWindow` 会让后面的窗口文字透出来，搜索或读译文时很难看清。
/// 纯色底 + 细分隔线，跟随系统深浅色。
public final class PanelBackgroundView: NSView {
    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

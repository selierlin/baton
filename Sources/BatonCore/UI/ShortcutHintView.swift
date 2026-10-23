import AppKit

/// 截图还没圈选时，左下角那一条快捷键提示。
///
/// 规格是量 Longshot 的截图界面得出的（2880×1800 的 2x 屏上）：
/// 框 442×534 px = 221×267 pt，左 10pt、底 20.5pt；里面 11 行 13pt 白字，
/// 行距 23pt，文字左内边距 16.5pt、上 12.5pt、下 11.5pt；底色是 70% 黑
/// （叠在不同内容上会看到 13~15 的差异，说明不是纯黑，是真的半透明），圆角 3pt。
///
/// 每行一个 label，而不是一个多行文本：多行文本要算折行宽度，宽度差 1pt
/// 就会把「↩」这种单字符挤到下一行，整块高度也跟着错。
/// 文案由调用方给：只列当前真的能按的键，不抄一行但不生效的假提示。
final class ShortcutHintView: NSView {
    struct Row {
        let action: String
        let keys: String

        init(_ action: String, _ keys: String) {
            self.action = action
            self.keys = keys
        }
    }

    private static let fontSize: CGFloat = 13
    private static let lineHeight: CGFloat = 23
    private static let insetLeft: CGFloat = 16.5
    private static let insetTop: CGFloat = 12.5
    private static let insetBottom: CGFloat = 11.5
    private static let corner: CGFloat = 3

    init(rows: [Row]) {
        super.init(frame: .zero)
        wantsLayer = true

        let font = NSFont.systemFont(ofSize: Self.fontSize)
        var labels: [NSTextField] = []
        var widest: CGFloat = 0

        for row in rows {
            let text = "\(row.action): \(row.keys)"
            widest = max(widest, (text as NSString).size(withAttributes: [.font: font]).width)

            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = .white
            label.usesSingleLineMode = true
            label.lineBreakMode = .byClipping
            label.alignment = .left
            labels.append(label)
            addSubview(label)
        }

        let width = (widest + Self.insetLeft * 2 + 2).rounded(.up)
        let height = Self.insetTop + Self.lineHeight * CGFloat(rows.count) + Self.insetBottom
        setFrameSize(NSSize(width: width, height: height))

        // 视图是左下原点：第 0 行贴在顶部，往下逐行排
        for (index, label) in labels.enumerated() {
            let y = height - Self.insetTop - Self.lineHeight * CGFloat(index + 1)
            label.frame = NSRect(x: Self.insetLeft, y: y,
                                 width: width - Self.insetLeft * 2,
                                 height: Self.lineHeight)
        }

        // 不设 autoresizingMask：覆盖层窗口每次按屏幕尺寸新建，尺寸不会中途变；
        // 加了弹性边距反而会在 addSubview 时被父视图「吸收」成高度，把底边距吞掉
        // （实测提示条会变成贴着屏幕底边、还高出 20pt）。
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: Self.corner, yRadius: Self.corner)
        // Longshot 量出来是叠在下层上、随底色轻微变化的值，70% 黑正好复现
        NSColor.black.withAlphaComponent(0.7).setFill()
        path.fill()
    }
}

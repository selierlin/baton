import AppKit

/// 设置页共用版式：20pt 边距、左边标题右边控件、灰色小标题分区。
///
/// 六页共用同一套行高、字号和间距，切页时才不会一页一个样。
/// 不用 `NSGridView`：网格要自己算列宽，而且标签右对齐后整块内容会偏到中间，
/// 在 560pt 宽的窗口里看着像没对齐。
@MainActor
enum SettingsLayout {
    static let pageWidth: CGFloat = 680
    static let margin: CGFloat = 20

    /// 把若干分组从上到下垂进页面。
    static func install(_ sections: [NSView], in page: NSView) {
        let content = NSStackView(views: sections)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 22
        content.translatesAutoresizingMaskIntoConstraints = false
        // NSStackView 的 `.width` 对齐并不拉伸子视图，宽度得自己约束
        for view in sections {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        page.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: margin),
            content.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -margin),
            content.topAnchor.constraint(equalTo: page.topAnchor, constant: 18),
            // 只是给页面一个「装得下内容」的最小高度：窗口高度按它算，不必再手写数字
            content.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -18),
        ])
    }

    /// 一组设置：小标题 + 若干行。组与组之间靠 22pt 间距分开，不画框。
    static func section(_ title: String, _ rows: [NSView]) -> NSStackView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setCustomSpacing(6, after: header)
        for line in rows {
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// 一行设置：左边标题（可带一行灰色说明），右边控件贴到最右。
    static func row(_ title: String, detail: String? = nil, control: NSView) -> SettingsRowView {
        SettingsRowView(title: title, detail: detail, control: control)
    }

    /// 撑满整行的单控件（复选框、诊断文本、按钮条）。
    static func plain(_ view: NSView) -> NSStackView {
        let line = NSStackView(views: [view])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.edgeInsets = NSEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        return line
    }

    /// 灰色说明文字。
    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        return label
    }
}

/// 「标题 + 说明 + 右侧控件」的一行。
@MainActor
final class SettingsRowView: NSStackView {
    private let nameLabel = NSTextField(labelWithString: "")

    init(title: String, detail: String?, control: NSView) {
        super.init(frame: .zero)

        nameLabel.stringValue = title
        nameLabel.font = .systemFont(ofSize: 13)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.addArrangedSubview(nameLabel)
        if let detail {
            text.addArrangedSubview(SettingsLayout.note(detail))
        }

        // 弹簧：把控件顶到右边。优先级压到最低，标题长了先挤弹簧。
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        orientation = .horizontal
        alignment = .centerY
        spacing = 12
        edgeInsets = NSEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        setViews([text, spacer, control], in: .leading)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

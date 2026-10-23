import AppKit
import Foundation

/// 翻译结果浮窗：原文在上一小块，译文占主区，两者都可选中复制。
///
/// 不复用 `ClipboardPanelController` 的列表结构——这里没有选择态，
/// 只有「加载中 / 有结果 / 失败」三种展示态。
@MainActor
public final class TranslatePanelController {
    private static let panelSize = NSSize(width: 480, height: 380)

    private let panel: KeyablePanel
    private let metaLabel = NSTextField(labelWithString: "")
    private let sourceView: NSTextView
    private let resultView: NSTextView
    private let spinner = NSProgressIndicator()
    private var plainResult = ""

    public init() {
        panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)

        let source = Self.makeTextView(font: .systemFont(ofSize: 12),
                                       color: .secondaryLabelColor)
        sourceView = source.view
        let result = Self.makeTextView(font: .systemFont(ofSize: 15),
                                       color: .labelColor)
        resultView = result.view

        buildUI(sourceScroll: source.scroll, resultScroll: result.scroll)
    }

    public var isVisible: Bool { panel.isVisible }

    // MARK: - 展示态

    public func showLoading(source: String, providerName: String) {
        metaLabel.stringValue = "\(providerName) · 翻译中…"
        sourceView.string = source
        resultView.string = ""
        resultView.textColor = .labelColor
        plainResult = ""
        spinner.startAnimation(nil)
        reveal()
    }

    public func show(result: TranslateResult, source: String, providerName: String) {
        metaLabel.stringValue = "\(providerName) · \(result.milliseconds) ms"
        sourceView.string = source
        resultView.string = result.text
        resultView.textColor = .labelColor
        plainResult = result.text
        spinner.stopAnimation(nil)
        reveal()
    }

    public func showFailure(message: String, source: String, providerName: String) {
        metaLabel.stringValue = "\(providerName) · 失败"
        sourceView.string = source
        resultView.string = message
        resultView.textColor = .systemRed
        plainResult = ""
        spinner.stopAnimation(nil)
        reveal()
    }

    /// 纯文本展示（如 OCR 结果），不涉及翻译状态。
    public func showText(title: String, body: String) {
        metaLabel.stringValue = title
        sourceView.string = ""
        resultView.string = body
        resultView.textColor = .labelColor
        plainResult = body
        spinner.stopAnimation(nil)
        reveal()
    }

    /// 诊断用：把面板与文本视图的实际尺寸摊开。
    public func debugFrames() -> String {
        let scroll = resultView.enclosingScrollView
        return "panel=\(panel.frame) content=\(panel.contentView?.frame ?? .zero) "
            + "text=\(resultView.frame) container=\(resultView.textContainer?.containerSize ?? .zero) "
            + "clip=\(scroll?.contentSize ?? .zero)"
    }

    public func hide() {
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }

    // MARK: - UI

    private func buildUI(sourceScroll: NSScrollView, resultScroll: NSScrollView) {
        panel.isFloatingPanel = true
        panel.level = .floating
        // 圆角靠背景视图自己画，窗口必须透明，否则会盖一层方形白底。
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // 跟剪贴板面板同一个坑：hidesOnDeactivate 会在激活被系统拒绝时立刻把窗关掉。
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = PanelBackgroundView()
        background.wantsLayer = true
        // 作为 contentView 时用 autoresizing 跟随窗口尺寸；设成 false 又没约束会把布局压坏。
        panel.contentView = background

        metaLabel.font = .systemFont(ofSize: 11, weight: .medium)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let copyButton = NSButton(title: "复制译文", target: self, action: #selector(copyResult))
        copyButton.bezelStyle = .inline
        copyButton.controlSize = .small

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closePanel))
        closeButton.bezelStyle = .inline
        closeButton.controlSize = .small

        let header = NSStackView(views: [metaLabel, spinner, NSView(), copyButton, closeButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        let sourceTitle = Self.makeCaption("原文")
        let resultTitle = Self.makeCaption("译文")

        for view in [header, sourceTitle, sourceScroll, resultTitle, resultScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }

        let inset: CGFloat = 16
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -inset),

            sourceTitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            sourceTitle.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset),

            sourceScroll.topAnchor.constraint(equalTo: sourceTitle.bottomAnchor, constant: 4),
            sourceScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset),
            sourceScroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -inset),
            sourceScroll.heightAnchor.constraint(equalToConstant: 64),

            resultTitle.topAnchor.constraint(equalTo: sourceScroll.bottomAnchor, constant: 14),
            resultTitle.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset),

            resultScroll.topAnchor.constraint(equalTo: resultTitle.bottomAnchor, constant: 4),
            resultScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset),
            resultScroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -inset),
            resultScroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -inset),
        ])
    }

    private static func makeCaption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private static func makeTextView(font: NSFont,
                                     color: NSColor) -> (scroll: NSScrollView, view: NSTextView) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 100))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = color
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // 不用 widthTracksTextView：它和「先建 textView 后定位 scrollView」的时序配合不好，
        // 实测会把容器撑到文本自身宽度（888pt）而不是可视宽度（448pt），长句直接被裁。
        // 改成显示时按 scrollView 的实际宽度显式同步，见 syncTextLayout()。
        textView.textContainer?.widthTracksTextView = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return (scroll, textView)
    }

    // MARK: - 与窗口交互

    private func reveal() {
        positionNearMouse()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // 约束要到窗口真正布局后才生效，这里同步一次文本容器宽度。
        panel.contentView?.layoutSubtreeIfNeeded()
        syncTextLayout()
    }

    private func syncTextLayout() {
        for textView in [sourceView, resultView] {
            guard let scroll = textView.enclosingScrollView else { continue }
            let width = scroll.contentSize.width
            guard width > 0 else { continue }
            textView.frame = NSRect(x: 0, y: 0,
                                    width: width,
                                    height: max(textView.frame.height, scroll.contentSize.height))
            textView.textContainer?.containerSize = NSSize(width: width,
                                                           height: CGFloat.greatestFiniteMagnitude)
        }
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 24)
        // 超出可见区域时贴近边缘，别把窗推到屏幕外
        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        if origin.y < visible.minY + 12 {
            origin.y = min(mouse.y + 24, visible.maxY - size.height - 12)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - 动作

    @objc private func copyResult() {
        let text = plainResult.isEmpty ? resultView.string : plainResult
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        metaLabel.stringValue = "已复制译文"
    }

    @objc private func closePanel() {
        hide()
    }
}

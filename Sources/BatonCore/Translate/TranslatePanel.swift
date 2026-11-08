import AppKit
import Foundation

/// 翻译结果浮窗。
///
/// 版式照 Bob 实测复刻（400pt 宽）：
/// 顶部一行工具栏（左「钉住」，右「朗读 / 复制 / 设置 / 关闭」），
/// 下面是原文卡片（含朗读、复制、「识别为 X」语言胶囊）、
/// 语言条（源语言 ⇄ 目标语言）、引擎卡片（图标 + 名称 + 加载点 + 折叠箭头，正文，朗读/复制）。
///
/// 颜色也照搬：面板 #F9F9F9、卡片 #EFEFEF，深色下分别为 #1F1F1F / #2B2B2B。
/// 数字都是拿 Bob 的窗口量出来的，别凭感觉调，调了就对不上。
@MainActor
public final class TranslatePanelController {
    /// Bob 的浮窗就是 400 宽；再宽会让单行译文过长，读起来累
    public static let width: CGFloat = 400
    private static let minHeight: CGFloat = 150
    /// 再长就滚动。Bob 也在这个量级封顶
    fileprivate static let maxHeight: CGFloat = 620

    private let panel: KeyablePanel
    private let card: TranslateCardView
    private var copyResetTask: Task<Void, Never>?
    /// 钉住后不再跟着鼠标重排位置
    private var pinned = false

    public var onPickSource: ((String?) -> Void)?
    public var onPickTarget: ((String) -> Void)?
    public var onSwap: (() -> Void)?
    public var onOpenSettings: (() -> Void)?

    public init() {
        card = TranslateCardView(frame: NSRect(x: 0, y: 0,
                                               width: Self.width,
                                               height: Self.minHeight))
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0,
                                                 width: Self.width,
                                                 height: Self.minHeight),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
        buildWindow()

        card.onCopyResult = { [weak self] in self?.copyResult() }
        card.onCopySource = { [weak self] in self?.copySource() }
        card.onClose = { [weak self] in self?.hide() }
        card.onSettings = { [weak self] in self?.onOpenSettings?() }
        card.onPickSource = { [weak self] code in self?.onPickSource?(code) }
        card.onPickTarget = { [weak self] code in self?.onPickTarget?(code) }
        card.onSwap = { [weak self] in self?.onSwap?() }
        card.onTogglePin = { [weak self] on in self?.pinned = on }
    }

    public var isVisible: Bool { panel.isVisible }

    // MARK: - 展示态

    public func showLoading(source: String,
                            languages: TranslateLanguagePair,
                            providerName: String,
                            providerID: String = "") {
        card.render(source: source,
                    languages: languages,
                    providerName: providerName,
                    providerID: providerID,
                    body: "",
                    bodyKind: .translation,
                    loading: true,
                    copyable: false)
        reveal()
    }

    public func show(result: TranslateResult,
                     source: String,
                     languages: TranslateLanguagePair,
                     providerName: String,
                     providerID: String = "") {
        card.render(source: source,
                    languages: languages,
                    providerName: providerName,
                    providerID: providerID,
                    body: result.text,
                    bodyKind: .translation,
                    loading: false,
                    copyable: true)
        reveal()
    }

    public func showFailure(message: String,
                            source: String,
                            languages: TranslateLanguagePair,
                            providerName: String,
                            providerID: String = "") {
        card.render(source: source,
                    languages: languages,
                    providerName: providerName,
                    providerID: providerID,
                    body: message,
                    bodyKind: .failure,
                    loading: false,
                    copyable: false)
        reveal()
    }

    /// 纯文本展示（没有图可看时的 OCR 兜底）：不翻译，整块文字放进结果卡片。
    public func showText(title: String, subtitle: String, body: String) {
        card.render(source: "",
                    languages: nil,
                    providerName: title,
                    providerID: "ocr",
                    body: body,
                    bodyKind: .plain,
                    loading: false,
                    copyable: true,
                    subtitle: subtitle)
        reveal()
    }

    /// 用户在下拉里换了语言：先只更新语言条，等新结果回来再整体重排。
    public func updateLanguages(_ languages: TranslateLanguagePair) {
        card.updateLanguages(languages)
        resizeOnly()
    }

    /// 诊断用：把面板与文本视图的实际尺寸摊开。
    public func debugFrames() -> String {
        return "panel=\(panel.frame) content=\(panel.contentView?.frame ?? .zero) "
            + "text=\(card.resultTextView.frame) bubble=\(card.resultCardFrame)"
    }

    public func hide() {
        card.stopLoading()
        panel.orderOut(nil)
    }

    // MARK: - 窗口

    private func buildWindow() {
        panel.isFloatingPanel = true
        panel.level = .floating
        // 圆角靠卡片自己画，窗口必须透明，否则会盖一层方形白底。
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        card.autoresizingMask = [.width, .height]
        panel.contentView = card
    }

    private func reveal() {
        resize()
        if !pinned { positionNearMouse() }
        // 首次出现淡入一下，像系统浮窗；已经显示时只换内容，不再闪
        let appearing = !panel.isVisible
        if appearing { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
        if appearing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
    }

    private func resizeOnly() {
        let height = currentHeight()
        var frame = panel.frame
        frame.origin.y += frame.size.height - height
        frame.size = NSSize(width: Self.width, height: height)
        panel.setFrame(frame, display: true)
        card.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
    }

    /// 卡片的高度由内容算出来，窗口跟着卡片走。
    private func resize() {
        let height = currentHeight()
        var frame = panel.frame
        frame.origin.y += frame.size.height - height
        frame.size = NSSize(width: Self.width, height: height)
        panel.setFrame(frame, display: false)
        card.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
    }

    private func currentHeight() -> CGFloat {
        min(max(card.requiredHeight(width: Self.width), Self.minHeight), Self.maxHeight)
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 18)
        // 超出可见区域时贴近边缘，别把窗推到屏幕外
        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        if origin.y < visible.minY + 12 {
            origin.y = min(mouse.y + 22, visible.maxY - size.height - 12)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - 动作

    private func copyResult() {
        guard let text = card.copyableResultText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        card.showCopied()
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.card.resetCopyIcon()
        }
    }

    private func copySource() {
        let text = card.currentSource
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        card.flashSourceCopy()
    }
}

// MARK: - 语言对

/// 语言条要的数据：`nil` 表示自动检测。
public struct TranslateLanguagePair: Sendable, Equatable {
    public var source: String?
    public var target: String

    public init(source: String?, target: String) {
        self.source = source
        self.target = target
    }

    public var sourceName: String {
        source.map(TranslateSettings.languageName(for:)) ?? "自动检测"
    }

    public var targetName: String {
        TranslateSettings.languageName(for: target)
    }
}

// MARK: - 卡片

/// 浮窗的整块内容。用固定坐标布局而不是 Auto Layout：
/// 高度要按文本量算，约束和「窗口跟着内容变高」搅在一起时很难对齐。
@MainActor
private final class TranslateCardView: NSView {
    enum BodyKind {
        case translation
        case failure
        case plain
    }

    // 版式常量：全部对着 Bob 的窗口量过
    private static let inset: CGFloat = 12
    private static let toolbarHeight: CGFloat = 40
    private static let blockGap: CGFloat = 8
    private static let bottomInset: CGFloat = 12
    private static let languageBarHeight: CGFloat = 30
    fileprivate static let maxSourceHeight: CGFloat = 236

    private let pinButton = IconToggle(symbol: "pin", activeSymbol: "pin.fill", tooltip: "钉住：新结果不再移动窗口")
    private let speakToolbarButton = IconButton(symbol: "speaker.wave.2", tooltip: "朗读原文", pointSize: 16)
    private let speakSourceButton = IconButton(symbol: "speaker.wave.2", tooltip: "朗读原文", pointSize: 15)
    private let copySourceButton = IconButton(symbol: "square.on.square", tooltip: "复制原文", pointSize: 15)
    private let speakResultButton = IconButton(symbol: "speaker.wave.2", tooltip: "朗读译文", pointSize: 15)
    private let copyButton = IconButton(symbol: "square.on.square", tooltip: "复制译文", pointSize: 16)
    private let settingsButton = IconButton(symbol: "slider.horizontal.3", tooltip: "翻译设置")
    private let closeButton = IconButton(symbol: "xmark", tooltip: "关闭（Esc）")

    private let sourceCard = BubbleCard()
    private let sourceScroll: NSScrollView
    private let sourceTextView: NSTextView
    private let languagePill = LanguagePill()

    private let languageBar = BubbleCard()
    private let sourceChip = MenuChip()
    private let targetChip = MenuChip()
    private let swapButton = IconButton(symbol: "arrow.left.arrow.right", tooltip: "交换语言")

    private let resultCard = ResultCard()

    var onCopyResult: (() -> Void)?
    var onCopySource: (() -> Void)?
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    var onPickSource: ((String?) -> Void)?
    var onPickTarget: ((String) -> Void)?
    var onSwap: (() -> Void)?
    var onTogglePin: ((Bool) -> Void)?

    var resultTextView: NSTextView { resultCard.bodyTextView }
    var resultCardFrame: NSRect { resultCard.frame }
    var currentSource: String { sourceText }
    var copyableResultText: String? { resultCopyable ? bodyText : nil }

    private var sourceText = ""
    private var bodyText = ""
    private var bodyKind: BodyKind = .translation
    private var loading = false
    private var resultCopyable = false
    private var hasLanguages = false
    private var languages = TranslateLanguagePair(source: nil, target: "zh-Hans")

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        let source = TranslateCardView.makeTextView(font: .source, selectable: true)
        sourceScroll = source.scroll
        sourceTextView = source.textView
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 外观

    override func updateLayer() {
        super.updateLayer()
        let dark = isDark
        layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1)
                                       : NSColor(white: 0.976, alpha: 1)).cgColor
        layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.08)
                                   : NSColor(white: 0, alpha: 0.06)).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        needsLayout = true
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func build() {
        wantsLayer = true
        layer?.masksToBounds = true

        pinButton.target = self
        pinButton.action = #selector(pinTapped)
        speakToolbarButton.target = self
        speakToolbarButton.action = #selector(speakSource)
        speakSourceButton.target = self
        speakSourceButton.action = #selector(speakSource)
        copySourceButton.target = self
        copySourceButton.action = #selector(copySourceTapped)
        speakResultButton.target = self
        speakResultButton.action = #selector(speakResult)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        swapButton.target = self
        swapButton.action = #selector(swapTapped)

        sourceCard.addSubview(sourceScroll)
        sourceCard.addSubview(speakSourceButton)
        sourceCard.addSubview(copySourceButton)
        sourceCard.addSubview(languagePill)
        languagePill.onClick = { [weak self] in self?.showSourceMenu() }

        languageBar.addSubview(sourceChip)
        languageBar.addSubview(swapButton)
        languageBar.addSubview(targetChip)
        sourceChip.onClick = { [weak self] in self?.showSourceMenu() }
        targetChip.onClick = { [weak self] in self?.showTargetMenu() }

        for view in [sourceCard, languageBar, resultCard,
                     pinButton, speakToolbarButton, copyButton, settingsButton, closeButton] {
            addSubview(view)
        }

        resultCard.onCollapseChange = { [weak self] in
            self?.needsLayout = true
            self?.superview?.needsLayout = true
        }
    }

    // MARK: 内容

    func render(source: String,
                languages: TranslateLanguagePair?,
                providerName: String,
                providerID: String,
                body: String,
                bodyKind: BodyKind,
                loading: Bool,
                copyable: Bool,
                subtitle: String? = nil) {
        sourceText = source
        bodyText = body
        self.bodyKind = bodyKind
        self.loading = loading
        resultCopyable = copyable
        hasLanguages = languages != nil
        if let languages { self.languages = languages }

        Self.apply(source, to: sourceTextView, font: .source,
                   color: .labelColor, lineSpacing: 5)
        resultCard.render(providerName: providerName,
                          providerID: providerID,
                          subtitle: subtitle,
                          body: body,
                          kind: bodyKind,
                          loading: loading,
                          copyable: copyable)

        sourceCard.isHidden = source.isEmpty
        languageBar.isHidden = !hasLanguages
        languagePill.isHidden = source.isEmpty || languages == nil
        languagePill.update(text: "识别为", language: self.languages.sourceName)
        sourceChip.title = self.languages.sourceName
        targetChip.title = self.languages.targetName

        resetCopyIcon()
        copySourceButton.setSymbol("square.on.square", tint: .secondaryLabelColor)
        speakSourceButton.isEnabled = !source.isEmpty
        speakResultButton.isHidden = body.isEmpty || loading
        // 工具栏上的复制/朗读始终在位上，加载中只是变灰——少一个图标会让整排错位
        speakToolbarButton.isEnabled = !source.isEmpty
        copyButton.isEnabled = copyable
        copyButton.alphaValue = copyable ? 1 : 0.35

        setLoading(loading)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func updateLanguages(_ languages: TranslateLanguagePair) {
        self.languages = languages
        sourceChip.title = languages.sourceName
        targetChip.title = languages.targetName
        languagePill.update(text: "识别为", language: languages.sourceName)
    }

    func setLoading(_ on: Bool) {
        loading = on
        resultCard.setLoading(on)
    }

    func stopLoading() {
        loading = false
        resultCard.setLoading(false)
    }

    func showCopied() {
        copyButton.setSymbol("checkmark", tint: .systemGreen)
    }

    func resetCopyIcon() {
        copyButton.setSymbol("square.on.square", tint: .secondaryLabelColor)
    }

    func flashSourceCopy() {
        copySourceButton.setSymbol("checkmark", tint: .systemGreen)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.copySourceButton.setSymbol("square.on.square", tint: .secondaryLabelColor)
        }
    }

    // MARK: 高度

    /// 卡片需要多高：工具栏 + 原文卡片（有原文时）+ 语言条 + 结果卡片 + 内边距。
    func requiredHeight(width: CGFloat) -> CGFloat {
        let contentWidth = width - Self.inset * 2
        var total = Self.toolbarHeight
        if !sourceCard.isHidden {
            total += sourceHeight(width: contentWidth) + Self.blockGap
        }
        if !languageBar.isHidden {
            total += Self.languageBarHeight + Self.blockGap
        }
        total += resultCard.preferredHeight(width: contentWidth)
        total += Self.bottomInset
        return total
    }

    private func sourceTextHeight(width: CGFloat) -> CGFloat {
        Self.height(sourceText, font: .source, width: width - 24, lineSpacing: 5)
    }

    private func sourceHeight(width: CGFloat) -> CGFloat {
        min(max(sourceTextHeight(width: width) + 50, 72), Self.maxSourceHeight)
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        let width = bounds.width
        let contentWidth = width - Self.inset * 2

        // 工具栏：左「钉住」，右四个图标（32 的间距，跟 Bob 一致）
        pinButton.frame = NSRect(x: 5, y: 3, width: 34, height: 34)
        let rightButtons: [NSButton] = [speakToolbarButton, copyButton, settingsButton, closeButton]
        var x = width - 5 - 34
        for button in rightButtons.reversed() {
            button.frame = NSRect(x: x, y: 3, width: 34, height: 34)
            x -= 32
        }

        var y = Self.toolbarHeight

        if !sourceCard.isHidden {
            let height = sourceHeight(width: contentWidth)
            sourceCard.frame = NSRect(x: Self.inset, y: y, width: contentWidth, height: height)
            let available = height - 50
            let textHeight = min(sourceTextHeight(width: contentWidth), available)
            sourceScroll.frame = NSRect(x: 12, y: 10, width: contentWidth - 24,
                                        height: max(textHeight, 18))
            sourceTextView.frame = NSRect(x: 0, y: 0, width: contentWidth - 24,
                                          height: max(textHeight, 18))
            sourceTextView.textContainer?.containerSize = NSSize(width: contentWidth - 24,
                                                                 height: .greatestFiniteMagnitude)

            let footerY = 10 + textHeight + 6
            speakSourceButton.frame = NSRect(x: 8, y: footerY + 2, width: 24, height: 24)
            copySourceButton.frame = NSRect(x: 34, y: footerY + 2, width: 24, height: 24)
            let pillWidth = languagePill.fittingWidth
            languagePill.frame = NSRect(x: 66, y: footerY + 3, width: pillWidth, height: 22)
            y += height + Self.blockGap
        }

        if !languageBar.isHidden {
            languageBar.frame = NSRect(x: Self.inset, y: y,
                                       width: contentWidth, height: Self.languageBarHeight)
            let half = (contentWidth - 44) / 2
            sourceChip.frame = NSRect(x: 4, y: 0, width: half, height: Self.languageBarHeight)
            swapButton.frame = NSRect(x: contentWidth / 2 - 15, y: 1, width: 30, height: 28)
            targetChip.frame = NSRect(x: contentWidth - 4 - half, y: 0,
                                      width: half, height: Self.languageBarHeight)
            y += Self.languageBarHeight + Self.blockGap
        }

        let resultHeight = max(bounds.height - y - Self.bottomInset, 32)
        resultCard.frame = NSRect(x: Self.inset, y: y, width: contentWidth, height: resultHeight)
        resultCard.needsLayout = true
        resultCard.layoutSubtreeIfNeeded()
    }

    // MARK: 菜单

    private func showSourceMenu() {
        let menu = NSMenu()
        let auto = NSMenuItem(title: "自动检测", action: #selector(pickSourceAuto), keyEquivalent: "")
        auto.target = self
        auto.state = languages.source == nil ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
        for language in TranslateSettings.languages {
            let item = NSMenuItem(title: language.name,
                                  action: #selector(pickSourceItem(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = language.code
            item.state = languages.source == language.code ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, from: sourceChip)
    }

    private func showTargetMenu() {
        let menu = NSMenu()
        for language in TranslateSettings.languages {
            let item = NSMenuItem(title: language.name,
                                  action: #selector(pickTargetItem(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = language.code
            item.state = languages.target == language.code ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, from: targetChip)
    }

    private func popUp(_ menu: NSMenu, from anchor: NSView) {
        let point = NSPoint(x: 0, y: anchor.bounds.height + 2)
        menu.popUp(positioning: nil, at: point, in: anchor)
    }

    @objc private func pickSourceAuto() { onPickSource?(nil) }

    @objc private func pickSourceItem(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        onPickSource?(code)
    }

    @objc private func pickTargetItem(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        onPickTarget?(code)
    }

    // MARK: 动作

    @objc private func pinTapped() {
        pinButton.isOn.toggle()
        onTogglePin?(pinButton.isOn)
    }

    @objc private func speakSource() {
        SpeechPlayer.shared.speak(sourceText)
    }

    @objc private func speakResult() {
        SpeechPlayer.shared.speak(bodyText)
    }

    @objc private func copySourceTapped() { onCopySource?() }
    @objc private func copyTapped() { onCopyResult?() }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func closeTapped() { onClose?() }

    @objc private func swapTapped() {
        languages = TranslateLanguagePair(source: languages.source == nil ? nil : languages.target,
                                          target: languages.source ?? languages.target)
        sourceChip.title = languages.sourceName
        targetChip.title = languages.targetName
        onSwap?()
    }

    // MARK: 文本

    fileprivate static func makeTextView(font: NSFont,
                                         selectable: Bool) -> (scroll: NSScrollView, textView: NSTextView) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        textView.isEditable = false
        textView.isSelectable = selectable
        textView.drawsBackground = false
        textView.font = font
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return (scroll, textView)
    }

    fileprivate static func apply(_ text: String,
                                  to view: NSTextView,
                                  font: NSFont,
                                  color: NSColor,
                                  lineSpacing: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ]))
    }

    /// 与 NSTextView 的渲染保持一致：无内边距、无行首缩进。
    fileprivate static func height(_ text: String,
                                   font: NSFont,
                                   width: CGFloat,
                                   lineSpacing: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: text,
            attributes: [.font: font, .paragraphStyle: style]
        ))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width,
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height) + 2
    }
}

// MARK: - 结果卡片

/// 引擎卡片：卡头（图标 + 名称 + 加载点 + 折叠箭头）、正文、底部朗读/复制。
@MainActor
private final class ResultCard: BubbleCard {
    private let iconView = ProviderIcon()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let dots = LoadingDots()
    private let chevron = NSImageView()
    private let headerButton = NSButton()
    private let speakButton = IconButton(symbol: "speaker.wave.2", tooltip: "朗读")
    private let copyButton = IconButton(symbol: "square.on.square", tooltip: "复制")

    private let scroll: NSScrollView
    let bodyTextView: NSTextView

    var onCollapseChange: (() -> Void)?

    private var collapsed = false
    private var loading = false
    private var copyable = false
    private var bodyHeight: CGFloat = 0
    private var kind: TranslateCardView.BodyKind = .translation

    private static let headerHeight: CGFloat = 32
    private static let footerHeight: CGFloat = 28

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        let text = TranslateCardView.makeTextView(font: .result, selectable: true)
        scroll = text.scroll
        bodyTextView = text.textView
        super.init(frame: frameRect)

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .tertiaryLabelColor

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "折叠")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        chevron.contentTintColor = .secondaryLabelColor

        headerButton.isBordered = false
        headerButton.title = ""
        headerButton.target = self
        headerButton.action = #selector(toggleCollapse)

        speakButton.target = self
        speakButton.action = #selector(speak)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)

        for view in [iconView, nameLabel, subtitleLabel, dots, chevron, headerButton,
                     scroll, speakButton, copyButton] {
            addSubview(view)
        }
        chevron.imageScaling = .scaleProportionallyDown
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(providerName: String,
                providerID: String,
                subtitle: String?,
                body: String,
                kind: TranslateCardView.BodyKind,
                loading: Bool,
                copyable: Bool) {
        nameLabel.stringValue = providerName
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        iconView.configure(id: providerID, name: providerName)
        self.kind = kind
        self.copyable = copyable
        self.collapsed = false
        TranslateCardView.apply(body, to: bodyTextView, font: .result,
                                color: kind == .failure ? .systemRed : .labelColor,
                                lineSpacing: kind == .failure ? 4 : 5)
        setLoading(loading)
        speakButton.isHidden = body.isEmpty || loading || !copyable
        copyButton.isHidden = body.isEmpty || loading || !copyable
    }

    func setLoading(_ on: Bool) {
        loading = on
        dots.isHidden = !on
        if on { dots.start() } else { dots.stop() }
        chevron.isHidden = on
        needsLayout = true
    }

    /// 折叠时只剩卡头；加载中也只显示卡头，跟 Bob 一致。
    private var showsBody: Bool {
        !collapsed && !loading && !bodyTextView.string.isEmpty
    }

    /// 底部工具条占的高度：没有朗读/复制按钮时不该留这块空白
    private var footerSpace: CGFloat {
        copyable ? Self.footerHeight + 6 : 0
    }

    /// 有工具条时贴到底，没有时多留一点，不然错误文案会顶到卡片边
    private var bottomPad: CGFloat {
        copyable ? 4 : 10
    }

    /// 正文行距（字高 + 行间距），用来把可视高度对齐到整行
    private var lineStride: CGFloat {
        let font: NSFont = .result
        return ceil(font.ascender - font.descender + font.leading) + 5
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        let textWidth = width - 28
        bodyHeight = TranslateCardView.height(bodyTextView.string,
                                              font: .result,
                                              width: textWidth,
                                              lineSpacing: kind == .failure ? 4 : 5)
        guard showsBody else { return Self.headerHeight + 4 }
        return Self.headerHeight + 6 + bodyHeight + footerSpace + bottomPad
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        iconView.frame = NSRect(x: 14, y: 7, width: 18, height: 18)
        let titleX: CGFloat = 40
        nameLabel.frame = NSRect(x: titleX, y: 8, width: width - titleX - 60, height: 17)
        if !subtitleLabel.isHidden {
            nameLabel.frame.size.height = 14
            nameLabel.frame.origin.y = 6
            subtitleLabel.frame = NSRect(x: titleX, y: 20, width: width - titleX - 60, height: 13)
        } else {
            subtitleLabel.frame = .zero
        }
        let nameWidth = ceil(nameLabel.intrinsicContentSize.width)
        dots.frame = NSRect(x: titleX + min(nameWidth, nameLabel.frame.width) + 8,
                            y: 14, width: 26, height: 6)
        chevron.frame = NSRect(x: width - 26, y: 12, width: 12, height: 10)
        headerButton.frame = NSRect(x: 0, y: 0, width: width, height: Self.headerHeight)

        guard showsBody else {
            speakButton.frame = .zero
            copyButton.frame = .zero
            scroll.frame = .zero
            return
        }
        let textWidth = width - 28
        // 正文可用高度 = 卡片高度 - 卡头 - 上下留白 - 底部工具条，和 preferredHeight 同一套口径，
        // 两边算法不一致就会永远差几像素，最后一行被切一半。
        let textTop = Self.headerHeight + 6
        let available = max(bounds.height - textTop - footerSpace - bottomPad, 32)
        // 底边切在整行上，别让半行字露在滚动区外面
        let stride = lineStride
        var visibleHeight = min(bodyHeight, available)
        if bodyHeight > visibleHeight {
            visibleHeight = max(floor(visibleHeight / stride) * stride, stride)
        }
        scroll.frame = NSRect(x: 14, y: textTop, width: textWidth, height: visibleHeight)
        bodyTextView.frame = NSRect(x: 0, y: 0, width: textWidth,
                                    height: max(bodyHeight, visibleHeight))
        bodyTextView.textContainer?.containerSize = NSSize(width: textWidth,
                                                           height: .greatestFiniteMagnitude)
        scroll.hasVerticalScroller = bodyHeight > visibleHeight + 1
        let footerY = bounds.height - Self.footerHeight - 4
        speakButton.frame = NSRect(x: 9, y: footerY + 2, width: 24, height: 24)
        copyButton.frame = NSRect(x: 35, y: footerY + 2, width: 24, height: 24)
    }

    @objc private func toggleCollapse() {
        guard !loading, !bodyTextView.string.isEmpty else { return }
        collapsed.toggle()
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.down",
                                accessibilityDescription: "折叠")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        onCollapseChange?()
    }

    @objc private func speak() { SpeechPlayer.shared.speak(bodyTextView.string) }

    @objc private func copyTapped() {
        guard copyable else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bodyTextView.string, forType: .string)
        copyButton.setSymbol("checkmark", tint: .systemGreen)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.copyButton.setSymbol("square.on.square", tint: .secondaryLabelColor)
        }
    }
}

// MARK: - 基础控件

/// 「识别为 英语」的小胶囊：点一下能改源语言。
@MainActor
private final class LanguagePill: BubbleCard {
    private let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11)
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        super.updateLayer()
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.10)
                                       : NSColor(white: 0, alpha: 0.06)).cgColor
        layer?.cornerRadius = 11
    }

    func update(text: String, language: String) {
        let attributed = NSMutableAttributedString(string: "\(text) ", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        attributed.append(NSAttributedString(string: language, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.controlAccentColor,
        ]))
        label.attributedStringValue = attributed
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        ceil(label.attributedStringValue.size().width) + 26
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 10, y: (bounds.height - 14) / 2,
                             width: bounds.width - 20, height: 14)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - 字体

@MainActor
extension NSFont {
    /// 原文与译文同号：Bob 两边都是 15pt，看起来才是一份文档
    static let source = NSFont.systemFont(ofSize: 15)
    static let result = NSFont.systemFont(ofSize: 15)
    static let sourceMeta = NSFont.systemFont(ofSize: 11)
}

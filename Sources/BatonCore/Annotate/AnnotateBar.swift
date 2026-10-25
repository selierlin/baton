import AppKit

/// 标注工具条。形态按 Longshot 的实机截图逐像素对齐：
///
/// - 容器高 35，圆角 2，底色 `#323232`，外圈 1pt `#555555`
/// - 始终是深色（Longshot 的截图工具条不跟随系统外观）
/// - 无左右内边距，按钮格 36×36 紧排，分隔条 12pt
/// - 图标 18pt，色值 `#DED4D4`；选中项垫 26×26 圆角底 `#505050`
/// - 左边缘与选区对齐，浮在选区下方 `SelectionChrome.toolbarGap` 处
///
/// 顺序照 `snipToolItemRawValues`：8 个工具组、分隔条，然后
/// 撤销 / 长截图 / 识别文字 / 更多 / 取消 / 贴图 / 保存 / 复制。
@MainActor
final class AnnotateBarView: NSView {
    /// 工具条之外的动作。
    enum ExternalAction: Hashable {
        case scroll
        case ocr
    }

    /// 「更多」菜单里的一次性动作（重做和选择走已有的回调）。
    enum MenuAction: Hashable {
        case qr
        case open
        case airDrop
        case saveAndCopy
    }

    var onTool: ((AnnotateTool) -> Void)?
    var onCommand: ((AnnotateCommand) -> Void)?
    var onExternal: ((ExternalAction) -> Void)?
    var onMenu: ((MenuAction) -> Void)?

    static let height: CGFloat = 35
    static let itemSize: CGFloat = 36
    static let separatorWidth: CGFloat = 12
    static let padding: CGFloat = 0
    static let iconSize: CGFloat = 18

    /// Longshot 的取色值，跟随系统外观：
    /// 浅色是 `#E6E6E6` 底 + `#3C3C3C` 图标，深色才是 `#323232` 底 + `#DED4D4` 图标。
    static let backgroundColor = BarPalette.background
    static let borderColor = BarPalette.border
    static let iconColor = LongshotGlyph.iconColor
    static let activeBackground = BarPalette.active
    static let hoverBackground = BarPalette.hover

    /// 每个槽位的一组工具。数组顺序 = 右键菜单顺序（照 Longshot 的
    /// `snipToolbarItemsRawValue`），默认显示项由 `defaultTool(for:)` 决定。
    static let groups: [[AnnotateTool]] = [
        [.rectangle, .ellipse],
        [.line, .flatArrow, .sinkArrow],
        [.mosaic, .mosaicEllipse, .mosaicPencil],
        [.marker, .markerEllipse, .markerPencil],
        [.ruler, .length, .area, .colorPick],
        [.pencil, .markerPen],
        [.text, .labelText],
        [.counter],
    ]

    /// 每组默认显示的工具。
    ///
    /// 照 Longshot 的 `snipToolbarItemsRawValue`：每组的格式是
    /// `显示项|选项1,选项2,...`，显示项不一定是第一个。箭头那组显示的是
    /// `sinkArrow` 而不是 `line`——照抄数组首位会默认落在「直线」上，
    /// 和 Longshot 看到的箭头图标对不上。
    static func defaultTool(for index: Int) -> AnnotateTool {
        let group = groups[index]
        if group.contains(.sinkArrow) { return .sinkArrow }
        return group[0]
    }

    static func glyph(for tool: AnnotateTool) -> LongshotGlyph {
        switch tool {
        case .rectangle: return .square
        case .ellipse: return .ellipse
        case .line: return .line
        case .flatArrow: return .flatArrow
        case .sinkArrow: return .sinkArrow
        case .mosaic: return .mosaicSquare
        case .mosaicEllipse: return .mosaicEllipse
        case .mosaicPencil: return .mosaicPencil
        case .marker: return .highlightSquare
        case .markerEllipse: return .highlightEllipse
        case .markerPencil: return .highlightPencil
        case .markerPen: return .markerPen
        case .ruler: return .ruler
        case .length: return .length
        case .area: return .area
        case .colorPick: return .colorCircle
        case .pencil: return .pencil
        case .text: return .textMark
        case .labelText: return .labelText
        case .counter: return .counter
        case .select: return .selector
        }
    }

    private let scroll = BarScrollView()
    private let content = NSView()
    private let variant: Variant
    private var allButtons: [BarItemButton] = []
    private var groupButtons: [BarItemButton] = []
    private var commandButtons: [AnnotateCommand: BarItemButton] = [:]
    private var externalButtons: [ExternalAction: BarItemButton] = [:]
    private(set) var lastVariants: [Int: AnnotateTool] = AnnotateBarView.loadVariants()
    private var currentTool: AnnotateTool = .rectangle
    private var canRedo = false

    /// 弹窗模式没有「把当前选区继续拿去长截图 / OCR」的上下文，这两个按钮置灰。
    var supportsCaptureActions = true {
        didSet { updateExternalAvailability() }
    }

    /// 两种场合的尾部动作不一样。
    ///
    /// 截图态是「取消 / 贴图 / 存储 / 复制」，贴图态照 Longshot 的
    /// `pasteToolbarItemsRawValue` 收在「撤销 / 重做 / 存储 / 复制 / 完成编辑」——
    /// 贴图里没有「再贴一次」「长截图」「OCR」这些上下文。
    enum Variant {
        case capture
        case pin
    }

    init(variant: Variant = .capture) {
        self.variant = variant
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // 不锁外观：Longshot 的条子跟着系统走，浅色系统下是白底黑图标

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        buildItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 外观

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 2, yRadius: 2)
        Self.backgroundColor.setFill()
        path.fill()
        Self.borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        let height = bounds.height
        guard height > 0 else { return }
        let width = max(contentWidth, scroll.contentSize.width)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)

        var x = Self.padding
        for view in orderedViews {
            view.frame = NSRect(x: x, y: 0, width: view.frame.width, height: height)
            x += view.frame.width
        }
    }

    private var orderedViews: [NSView] { content.subviews }

    private var contentWidth: CGFloat {
        content.subviews.reduce(Self.padding * 2) { $0 + $1.frame.width }
    }

    var preferredSize: NSSize {
        layoutSubtreeIfNeeded()
        return NSSize(width: ceil(contentWidth), height: Self.height)
    }

    // MARK: - 上次选择

    private static let variantsKey = "annotate.lastVariants"

    /// 每组上次选中的变体。跨会话保留，新一次截图打开工具条时就显示上次用的那个图标。
    private static func loadVariants() -> [Int: AnnotateTool] {
        guard let raw = UserDefaults.standard.dictionary(forKey: variantsKey) else { return [:] }
        var variants: [Int: AnnotateTool] = [:]
        for (key, value) in raw {
            guard let index = Int(key), let name = value as? String,
                  let tool = AnnotateTool(rawValue: name) else { continue }
            variants[index] = tool
        }
        return variants
    }

    private static func saveVariants(_ variants: [Int: AnnotateTool]) {
        let raw = variants.reduce(into: [String: String]()) { result, entry in
            result[String(entry.key)] = entry.value.rawValue
        }
        UserDefaults.standard.set(raw, forKey: variantsKey)
    }

    // MARK: - 刷新

    func refresh(tool: AnnotateTool, canUndo: Bool, canRedo: Bool) {
        self.currentTool = tool
        self.canRedo = canRedo

        for (index, group) in Self.groups.enumerated() {
            guard index < groupButtons.count else { continue }
            let button = groupButtons[index]
            let selected = group.contains(tool)
            if selected {
                lastVariants[index] = tool
            }
            let shown = selected ? tool : (lastVariants[index] ?? Self.defaultTool(for: index))
            button.glyph = Self.glyph(for: shown)
            button.isActive = selected
            button.toolTip = group.count > 1
                ? "\(shown.title)（点击切换，右键选择）"
                : shown.title
        }

        commandButtons[.undo]?.isEnabled = canUndo
        commandButtons[.redo]?.isEnabled = canRedo
        updateExternalAvailability()
        Self.saveVariants(lastVariants)
    }

    private func updateExternalAvailability() {
        for (action, button) in externalButtons {
            let enabled = supportsCaptureActions
            button.isEnabled = enabled
            guard enabled else {
                button.toolTip = "仅原地标注可用"
                continue
            }
            switch action {
            case .scroll: button.toolTip = "长截图 (⌥⌘L)"
            case .ocr: button.toolTip = "识别文字 (⇧⌘O)"
            }
        }
    }

    // MARK: - 构建

    private func buildItems() {
        for (index, group) in Self.groups.enumerated() {
            let shown = lastVariants[index] ?? Self.defaultTool(for: index)
            let button = BarItemButton(glyph: Self.glyph(for: shown))
            button.target = self
            button.action = #selector(pickGroup(_:))
            button.tag = index
            button.onAlternates = { [weak self] button in
                self?.showVariants(group, index: index, from: button)
            }
            groupButtons.append(button)
            add(button, width: Self.itemSize)
        }

        addSeparator()

        switch variant {
        case .capture:
            addCommand(.undo, glyph: .undo, tooltip: "撤销 (⌘Z)")
            addExternal(.scroll, glyph: .scrollcut, tooltip: "长截图 (⌥⌘L)")
            addExternal(.ocr, glyph: .ocr, tooltip: "识别文字 (⇧⌘O)")
            addMore()
            addCommand(.cancel, glyph: .cancel, tooltip: "取消 (Esc)", red: true)
            addCommand(.pin, glyph: .pin, tooltip: "贴图 (P)", command: .pin)
            addCommand(.save, glyph: .download, tooltip: "存储 (⌘S)", command: .save)
            addCommand(.copy, glyph: .copy, tooltip: "复制 (↩)", command: .copy)
        case .pin:
            addCommand(.undo, glyph: .undo, tooltip: "撤销 (⌘Z)")
            addCommand(.redo, glyph: .redo, tooltip: "重做 (⇧⌘Z)")
            addCommand(.save, glyph: .download, tooltip: "保存到本地 (⌘D)", command: .save)
            addCommand(.copy, glyph: .copy, tooltip: "复制 (↩)", command: .copy)
            addCommand(.cancel, glyph: .cancel, tooltip: "完成编辑 (Esc)", red: true)
        }
    }

    private func add(_ view: NSView, width: CGFloat) {
        var frame = view.frame
        frame.size = NSSize(width: width, height: Self.height)
        view.frame = frame
        content.addSubview(view)
        if let button = view as? BarItemButton { allButtons.append(button) }
    }

    private func addSeparator() {
        let separator = SeparatorLineView()
        add(separator, width: Self.separatorWidth)
    }

    private func addCommand(_ key: AnnotateCommand,
                            glyph: LongshotGlyph,
                            tooltip: String,
                            red: Bool = false,
                            command: AnnotateCommand? = nil) {
        let button = BarItemButton(glyph: glyph)
        button.target = self
        button.action = #selector(runCommand(_:))
        button.toolTip = tooltip
        button.isRed = red
        commandButtons[key] = button
        button.command = command ?? key
        add(button, width: Self.itemSize)
    }

    private func addExternal(_ action: ExternalAction, glyph: LongshotGlyph, tooltip: String) {
        let button = BarItemButton(glyph: glyph)
        button.target = self
        button.action = #selector(runExternal(_:))
        button.toolTip = tooltip
        button.external = action
        externalButtons[action] = button
        add(button, width: Self.itemSize)
    }

    private func addMore() {
        let button = BarItemButton(glyph: .more)
        button.target = self
        button.action = #selector(showMoreMenu(_:))
        button.toolTip = "更多"
        add(button, width: Self.itemSize)
    }

    // MARK: - 动作

    @objc private func pickGroup(_ sender: NSButton) {
        let index = sender.tag
        guard index < Self.groups.count else { return }
        let group = Self.groups[index]

        // Longshot 的「Press to switch」：点已激活的那一格会在子项之间轮换，
        // 想直接选某一项就走右键菜单。
        if group.count > 1, group.contains(currentTool),
           let current = group.firstIndex(of: currentTool) {
            let next = group[(current + 1) % group.count]
            lastVariants[index] = next
            onTool?(next)
            return
        }

        let tool = lastVariants[index] ?? Self.defaultTool(for: index)
        lastVariants[index] = tool
        onTool?(tool)
    }

    private func showVariants(_ group: [AnnotateTool], index: Int, from button: NSButton) {
        guard group.count > 1 else {
            onTool?(group[0])
            return
        }
        let menu = NSMenu()
        for tool in group {
            let item = NSMenuItem(title: tool.title, action: #selector(pickVariant(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = VariantPayload(group: index, tool: tool)
            item.state = (lastVariants[index] ?? Self.defaultTool(for: index)) == tool ? .on : .off
            item.image = Self.glyph(for: tool).image(size: 14)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 2),
                   in: button)
    }

    @objc private func pickVariant(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? VariantPayload else { return }
        lastVariants[payload.group] = payload.tool
        onTool?(payload.tool)
    }

    @objc private func runCommand(_ sender: BarItemButton) {
        onCommand?(sender.command ?? .undo)
    }

    @objc private func runExternal(_ sender: BarItemButton) {
        guard let action = sender.external, supportsCaptureActions else { return }
        onExternal?(action)
    }

    @objc private func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()

        let redo = NSMenuItem(title: "重做", action: #selector(menuRedo), keyEquivalent: "")
        redo.target = self
        redo.isEnabled = canRedo
        redo.image = LongshotGlyph.redo.image(size: 14)
        menu.addItem(redo)

        let select = NSMenuItem(title: "选择", action: #selector(menuSelect), keyEquivalent: "")
        select.target = self
        select.image = LongshotGlyph.selector.image(size: 14)
        menu.addItem(select)

        menu.addItem(.separator())
        // 键位写在标题里而不是 keyEquivalent：菜单只是展示，别真去抢键盘
        menu.addItem(menuItem("QR 解码  ⌥Q", symbol: "qrcode", action: #selector(menuQR)))
        menu.addItem(menuItem("打开  O", symbol: "arrow.up.forward.app", action: #selector(menuOpen)))
        menu.addItem(menuItem("隔空投送  A", symbol: "paperplane", action: #selector(menuAirDrop)))

        menu.addItem(.separator())
        menu.addItem(menuItem("保存并复制", symbol: "square.and.arrow.down.on.square",
                              action: #selector(menuSaveAndCopy)))

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 2),
                   in: sender)
    }

    private func menuItem(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        return item
    }

    @objc private func menuRedo() { onCommand?(.redo) }
    @objc private func menuSelect() { onTool?(.select) }
    @objc private func menuQR() { onMenu?(.qr) }
    @objc private func menuOpen() { onMenu?(.open) }
    @objc private func menuAirDrop() { onMenu?(.airDrop) }
    @objc private func menuSaveAndCopy() { onMenu?(.saveAndCopy) }
}

private struct VariantPayload {
    let group: Int
    let tool: AnnotateTool
}

// MARK: - 基础构件

/// 带悬停底与选中底的工具按钮。图标颜色始终是 Longshot 的浅灰，
/// 选中只改底色，不改图标色。
final class BarItemButton: NSButton {
    var glyph: LongshotGlyph = .square {
        didSet { refreshImage() }
    }
    var isActive = false {
        didSet { refreshImage() }
    }
    /// 属性条里的形状按钮选中时是蓝色，和主工具条的灰底不同
    var usesAccent = false {
        didSet { refreshImage() }
    }
    var isRed = false {
        didSet { refreshImage() }
    }
    var command: AnnotateCommand?
    var external: AnnotateBarView.ExternalAction?
    var representedTool: AnnotateTool?
    var onAlternates: ((BarItemButton) -> Void)?

    private var hovering = false
    private var tracking: NSTrackingArea?

    init(glyph: LongshotGlyph) {
        self.glyph = glyph
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        refusesFirstResponder = true
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryChange)
        refreshImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 贴图的工具条挂在不激活的面板上，第一下点击不该被「先激活窗口」吃掉。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func refreshImage() {
        let color: NSColor
        if !isEnabled {
            color = AnnotateBarView.iconColor.withAlphaComponent(0.3)
        } else if isRed {
            color = .systemRed
        } else if isActive && usesAccent {
            color = .white
        } else {
            color = AnnotateBarView.iconColor
        }
        image = glyph.image(size: AnnotateBarView.iconSize, color: color)
        needsDisplay = true
    }

    /// 图标是把颜色烘焙进位图的，切换浅色/深色外观时必须重画。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshImage()
    }

    override var isEnabled: Bool {
        didSet { refreshImage() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onAlternates else {
            super.rightMouseDown(with: event)
            return
        }
        onAlternates(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: (bounds.width - 26) / 2, y: (bounds.height - 26) / 2,
                         width: 26, height: 26)
        if isActive {
            if usesAccent {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            } else {
                AnnotateBarView.activeBackground.setFill()
                NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            }
        } else if hovering, isEnabled {
            AnnotateBarView.hoverBackground.setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

final class SeparatorLineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        BarPalette.separator.withAlphaComponent(0.35).setFill()
        let height = min(18, bounds.height - 8)
        NSRect(x: bounds.midX - 0.5, y: (bounds.height - height) / 2,
               width: 1, height: height).fill()
    }
}

/// 只吃横向滚动的滚动区：鼠标滚轮上下滚也能带着工具条走。
final class BarScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let clip = contentView
        let maxX = max(0, (documentView?.frame.width ?? 0) - clip.bounds.width)
        guard maxX > 0 else { return }
        var origin = clip.bounds.origin
        origin.x = min(max(0, origin.x - event.scrollingDeltaY), maxX)
        clip.setBoundsOrigin(origin)
        reflectScrolledClipView(clip)
    }
}

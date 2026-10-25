import AppKit

/// 工具属性条。
///
/// 结构照 Longshot 实机截图：`变体 | 分隔 | 工具专属控件 | 颜色`
/// 每个工具的控件不一样（形状有绘制样式/线型/圆角，马赛克有纹理/颗粒，
/// 序号有形状/大小/数字），不像旧版那样所有工具共用一根粗细滑杆。
@MainActor
final class AnnotatePropertyBarView: NSView {
    enum Change {
        case tool(AnnotateTool)
        case color(AnnotateColor)
        case lineWidth(CGFloat)
        case fontSize(CGFloat)
        case opacity(Double)
        case fillAlpha(Double)
        case cornerRadius(CGFloat)
        case mosaicBlock(CGFloat)
        case counterScale(CGFloat)
        case counterNumber(Int)
        case shapeDrawStyle(ShapeDrawStyle)
        case linePattern(LinePattern)
        case markerCap(MarkerCap)
        case mosaicPattern(MosaicPattern)
        case counterShape(CounterShape)
        case textMarkStyle(TextMarkStyle)
        case fontName(String)
    }

    struct State {
        var tool: AnnotateTool
        /// 逻辑点尺寸，不是图片像素
        var style: AnnotateStyle
        var number: Int
    }

    var onChange: ((Change) -> Void)?

    static let height: CGFloat = AnnotateBarView.height
    private static let leading: CGFloat = 8
    private static let trailing: CGFloat = 8
    private static let gap: CGFloat = 8

    private let content = NSView()
    private var sections: [Section] = []
    private var tool: AnnotateTool = .rectangle
    private var built = false

    private struct Section {
        var view: NSView
        var width: CGFloat
        var isSeparator: Bool = false
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        addSubview(content)
        build(for: .rectangle, state: State(tool: .rectangle, style: AnnotateStyle(), number: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// 条里的自绘控件只实现了 `mouseDown`，`mouseUp` 会顺着响应链冒到覆盖层，
    /// 覆盖层按「空选区」把它当成取消，于是点一下颜色整个截图就没了。
    /// 事件到属性条为止，不再往上走。
    override func mouseUp(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 5, yRadius: 5)
        AnnotateBarView.backgroundColor.setFill()
        path.fill()
        AnnotateBarView.borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        guard bounds.height > 0 else { return }
        content.frame = NSRect(x: 0, y: 0, width: max(contentWidth, bounds.width), height: bounds.height)
        var x = Self.leading
        for section in sections {
            section.view.frame = NSRect(x: x, y: 0, width: section.width, height: bounds.height)
            x += section.width + Self.gap
        }
    }

    private var contentWidth: CGFloat {
        var width = Self.leading + Self.trailing
        for (index, section) in sections.enumerated() {
            width += section.width
            if index < sections.count - 1 { width += Self.gap }
        }
        return width
    }

    var preferredSize: NSSize {
        layoutSubtreeIfNeeded()
        return NSSize(width: ceil(contentWidth), height: Self.height)
    }

    // MARK: - 配置

    func configure(_ state: State) {
        let toolChanged = !built || state.tool != tool
        tool = state.tool
        if toolChanged {
            build(for: state.tool, state: state)
            needsLayout = true
        }
        apply(state)
        if toolChanged {
            layoutSubtreeIfNeeded()
        }
        needsDisplay = true
    }

    private func apply(_ state: State) {
        for section in sections {
            switch section.view {
            case let segment as PropertySegmentControl:
                segment.apply(state)
            case let slider as PropertySlider:
                slider.apply(state)
            case let field as PropertyNumberField:
                field.value = state.number
            case let colors as PropertyColorStrip:
                colors.current = state.style.color
            case let popup as PropertyPopupButton:
                popup.apply(state)
            default:
                break
            }
        }
    }

    // MARK: - 构建

    private func build(for tool: AnnotateTool, state: State) {
        for section in sections { section.view.removeFromSuperview() }
        sections.removeAll()
        built = true

        let group = AnnotateBarView.groups.first { $0.contains(tool) } ?? [tool]

        // 变体：和主工具条的分组一致
        if group.count > 1 {
            let items = group.map { tool in
                PropertySegmentControl.Item(image: PropertyIcon.tool(tool).image(),
                                            selectedImage: PropertyIcon.tool(tool).image(color: BarPalette.accent),
                                            tooltip: tool.title)
            }
            let segment = PropertySegmentControl(items: items, itemWidth: 32)
            segment.selectionStyle = .tint
            segment.selectedIndex = group.firstIndex(of: tool) ?? 0
            segment.onSelect = { [weak self] index in
                guard index < group.count else { return }
                self?.onChange?(.tool(group[index]))
            }
            add(segment, width: CGFloat(group.count) * 32)
            addSeparator()
        }

        switch tool {
        case .select, .colorPick:
            break

        case .rectangle, .ellipse:
            addShapeStyleSegment(state)
            addLinePatternSegment(state)
            addSlider(min: 1, max: 20, value: state.style.lineWidth, metric: .lineWidth) { [weak self] value in
                self?.onChange?(.lineWidth(value))
            }
            addSlider(min: 0, max: 120, value: state.style.cornerRadius, metric: .cornerRadius,
                      tooltip: "圆角") { [weak self] value in
                self?.onChange?(.cornerRadius(value))
            }
            addColors()

        case .line, .flatArrow, .sinkArrow:
            addLinePatternSegment(state)
            addSlider(min: 1, max: 20, value: state.style.lineWidth, metric: .lineWidth,
                      tooltip: "粗细") { [weak self] value in
                self?.onChange?(.lineWidth(value))
            }
            // Longshot 的线条/箭头属性条是「粗细 + 透明度」两条滑杆
            addSlider(min: 0.1, max: 1, value: state.style.opacity, metric: .opacity,
                      tooltip: "透明度") { [weak self] value in
                self?.onChange?(.opacity(Double(value)))
            }
            addColors()

        case .mosaic, .mosaicEllipse, .mosaicPencil:
            let patterns = MosaicPattern.allCases
            addSegment(items: patterns.count,
                       images: patterns.map { PropertyIcon.mosaic($0).image(color: BarPalette.chipIcon) },
                       selected: patterns.firstIndex(of: state.style.mosaicPattern) ?? 0,
                       provider: { patterns.firstIndex(of: $0.style.mosaicPattern) ?? 0 }) { [weak self] index in
                self?.onChange?(.mosaicPattern(patterns[index]))
            }
            addSlider(min: 4, max: 60, value: state.style.mosaicBlock, metric: .mosaicBlock,
                      tooltip: "大小") { [weak self] value in
                self?.onChange?(.mosaicBlock(value))
            }
            addSlider(min: 1, max: 20, value: state.style.lineWidth, metric: .lineWidth,
                      tooltip: "粗细") { [weak self] value in
                self?.onChange?(.lineWidth(value))
            }
            addSlider(min: 0, max: 24, value: state.style.cornerRadius, metric: .cornerRadius,
                      tooltip: "圆角") { [weak self] value in
                self?.onChange?(.cornerRadius(value))
            }
            // 马赛克也要能换色，之前这条漏了，只能一直用当前色
            addColors()

        case .marker, .markerEllipse, .markerPencil:
            addSlider(min: 1, max: 40, value: state.style.lineWidth, metric: .lineWidth,
                      tooltip: "粗细") { [weak self] value in
                self?.onChange?(.lineWidth(value))
            }
            addSlider(min: 0.1, max: 1, value: state.style.opacity, metric: .opacity,
                      tooltip: "透明度") { [weak self] value in
                self?.onChange?(.opacity(Double(value)))
            }
            addSlider(min: 0, max: 60, value: state.style.cornerRadius, metric: .cornerRadius,
                      tooltip: "圆角") { [weak self] value in
                self?.onChange?(.cornerRadius(value))
            }
            addColors()

        case .pencil:
            addSlider(min: 1, max: 30, value: state.style.lineWidth, metric: .lineWidth,
                      tooltip: "粗细") { [weak self] value in
                self?.onChange?(.lineWidth(value))
            }
            addSlider(min: 0.1, max: 1, value: state.style.opacity, metric: .opacity,
                      tooltip: "透明度") { [weak self] value in
                self?.onChange?(.opacity(Double(value)))
            }
            addColors()

        case .markerPen:
            let caps = MarkerCap.allCases
            addSegment(items: caps.count,
                       images: caps.map { PropertyIcon.cap($0).image(color: BarPalette.chipIcon) },
                       selected: caps.firstIndex(of: state.style.markerCap) ?? 0,
                       provider: { caps.firstIndex(of: $0.style.markerCap) ?? 0 }) { [weak self] index in
                self?.onChange?(.markerCap(caps[index]))
            }
            addSlider(min: 1, max: 30, value: state.style.lineWidth, metric: .lineWidth,
                      tooltip: "粗细") { [weak self] value in
                self?.onChange?(.lineWidth(value))
            }
            addSlider(min: 0.1, max: 1, value: state.style.opacity, metric: .opacity,
                      tooltip: "透明度") { [weak self] value in
                self?.onChange?(.opacity(Double(value)))
            }
            addColors()

        case .counter:
            let shapes = CounterShape.allCases
            addSegment(items: shapes.count,
                       images: shapes.map { PropertyIcon.counter($0).image(color: BarPalette.chipIcon) },
                       selected: shapes.firstIndex(of: state.style.counterShape) ?? 0,
                       provider: { shapes.firstIndex(of: $0.style.counterShape) ?? 0 }) { [weak self] index in
                self?.onChange?(.counterShape(shapes[index]))
            }
            addSlider(min: 0.5, max: 2.5, value: state.style.counterScale, metric: .counterScale,
                      tooltip: "大小") { [weak self] value in
                self?.onChange?(.counterScale(value))
            }
            let field = PropertyNumberField(value: state.number)
            field.onChange = { [weak self] number in
                self?.onChange?(.counterNumber(number))
            }
            add(field, width: 52)
            addColors()

        case .text:
            let popup = PropertyPopupButton(title: Self.fontTitle(state.style.fontName),
                                            options: Self.fonts.map { Self.fontTitle($0) })
            popup.selectionProvider = { Self.fonts.firstIndex(of: $0.style.fontName) ?? 0 }
            popup.onSelect = { [weak self] index in
                guard index < Self.fonts.count else { return }
                self?.onChange?(.fontName(Self.fonts[index]))
            }
            add(popup, width: 98)
            addSlider(min: 10, max: 96, value: state.style.fontSize, metric: .fontSize,
                      tooltip: "字体大小") { [weak self] value in
                self?.onChange?(.fontSize(value))
            }
            let styles = TextMarkStyle.allCases
            let stylePopup = PropertyPopupButton(title: state.style.textMarkStyle.title,
                                                 options: styles.map { $0.title })
            stylePopup.selectionProvider = { styles.firstIndex(of: $0.style.textMarkStyle) ?? 0 }
            stylePopup.onSelect = { [weak self] index in
                guard index < styles.count else { return }
                self?.onChange?(.textMarkStyle(styles[index]))
            }
            add(stylePopup, width: 98)
            addColors()

        case .labelText:
            addSlider(min: 10, max: 72, value: state.style.fontSize, metric: .fontSize,
                      tooltip: "字体大小") { [weak self] value in
                self?.onChange?(.fontSize(value))
            }
            addColors()

        case .ruler, .length, .area:
            addSlider(min: 1, max: 16, value: state.style.lineWidth, metric: .lineWidth,
                      tooltip: "粗细") { [weak self] value in
                self?.onChange?(.lineWidth(value))
            }
            addSlider(min: 10, max: 48, value: state.style.fontSize, metric: .fontSize,
                      tooltip: "字体大小") { [weak self] value in
                self?.onChange?(.fontSize(value))
            }
            addColors()
        }
    }

    private func addShapeStyleSegment(_ state: State) {
        let styles = ShapeDrawStyle.allCases
        addSegment(items: styles.count,
                   images: styles.map { PropertyIcon.shape($0).image(color: BarPalette.chipIcon) },
                   selected: styles.firstIndex(of: state.style.shapeDrawStyle) ?? 1,
                   provider: { styles.firstIndex(of: $0.style.shapeDrawStyle) ?? 1 }) { [weak self] index in
            self?.onChange?(.shapeDrawStyle(styles[index]))
        }
    }

    private func addLinePatternSegment(_ state: State) {
        let patterns = LinePattern.allCases
        addSegment(items: patterns.count,
                   images: patterns.map { PropertyIcon.line($0).image(color: BarPalette.chipIcon) },
                   selected: patterns.firstIndex(of: state.style.linePattern) ?? 0,
                   provider: { patterns.firstIndex(of: $0.style.linePattern) ?? 0 }) { [weak self] index in
            self?.onChange?(.linePattern(patterns[index]))
        }
    }

    private func addSegment(items: Int, images: [NSImage], selected: Int,
                            provider: ((State) -> Int)? = nil,
                            onSelect: @escaping (Int) -> Void) {
        let segment = PropertySegmentControl(
            items: images.map { PropertySegmentControl.Item(image: $0, tooltip: nil) },
            itemWidth: 32
        )
        segment.selectedIndex = selected
        segment.selectionProvider = provider
        segment.onSelect = onSelect
        add(segment, width: CGFloat(items) * 32)
    }

    private func addSlider(min: CGFloat, max: CGFloat, value: CGFloat,
                           metric: PropertySlider.Metric = .lineWidth,
                           tooltip: String? = nil,
                           onChange: @escaping (CGFloat) -> Void) {
        let slider = PropertySlider()
        slider.minValue = min
        slider.maxValue = max
        slider.metric = metric
        slider.value = value
        slider.toolTip = tooltip
        slider.onChange = onChange
        add(slider, width: 80)
    }

    private func addColors() {
        let strip = PropertyColorStrip()
        strip.onPick = { [weak self] color in self?.onChange?(.color(color)) }
        add(strip, width: PropertyColorStrip.preferredWidth)
    }

    private func addSeparator() {
        let line = PropertySeparator()
        sections.append(Section(view: line, width: 1, isSeparator: true))
    }

    private func add(_ view: NSView, width: CGFloat) {
        content.addSubview(view)
        sections.append(Section(view: view, width: width))
    }

    // MARK: - 字体

    static let fonts = ["HelveticaNeue-Bold", "HelveticaNeue", "PingFangSC-Semibold", "Menlo-Bold"]

    private static func fontTitle(_ name: String) -> String {
        switch name {
        case "HelveticaNeue-Bold": return "Helvetica Bold"
        case "HelveticaNeue": return "Helvetica"
        case "PingFangSC-Semibold": return "苹方"
        case "Menlo-Bold": return "Menlo"
        default: return name
        }
    }
}

// MARK: - 分段控件

@MainActor
final class PropertySegmentControl: NSView {
    /// 选中态有两种画法：Longshot 的「变体切换」是把图标染成蓝色，
    /// 其它分段（绘制样式、线型）是给一个浅灰圆角底。
    enum SelectionStyle {
        case chip
        case tint
    }

    struct Item {
        var image: NSImage?
        var selectedImage: NSImage?
        var tooltip: String?
    }

    var selectionStyle: SelectionStyle = .chip
    var onSelect: ((Int) -> Void)?
    var selectionProvider: ((AnnotatePropertyBarView.State) -> Int)?
    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }

    private let items: [Item]
    private let itemWidth: CGFloat

    init(items: [Item], itemWidth: CGFloat) {
        self.items = items
        self.itemWidth = itemWidth
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Longshot 的分段是「一条浅槽 + 选中格子里一块更亮的块」，格子之间用
        // 1pt 刻度分开，选中格不加描边（描边会把它勒成独立按钮的感觉）。
        let slotHeight: CGFloat = 22
        let slot = NSRect(x: 0, y: (bounds.height - slotHeight) / 2,
                          width: bounds.width, height: slotHeight)
        if selectionStyle == .chip {
            BarPalette.controlRaised.setFill()
            NSBezierPath(roundedRect: slot, xRadius: 7, yRadius: 7).fill()
        }

        for (index, item) in items.enumerated() {
            let column = NSRect(x: CGFloat(index) * itemWidth, y: slot.minY,
                                width: itemWidth, height: slotHeight)
            let selected = index == selectedIndex
            if selected, selectionStyle == .chip {
                BarPalette.segmentedSelected.setFill()
                NSBezierPath(roundedRect: column, xRadius: 6, yRadius: 6).fill()
            } else if index > 0, selectionStyle == .chip, index - 1 != selectedIndex {
                // 刻度夹在两格之间；挨着选中格的那条会被选中块盖住，不画。
                BarPalette.segmentDivider.setFill()
                NSRect(x: column.minX - 0.5, y: column.midY - 6, width: 1, height: 12).fill()
            }
            let image = selected ? (item.selectedImage ?? item.image) : item.image
            if let image {
                let size = image.size
                let rect = NSRect(x: column.midX - size.width / 2,
                                  y: column.midY - size.height / 2,
                                  width: size.width, height: size.height)
                // 这里必须显式写 from 矩形并置 respectFlipped。属性条是 isFlipped 的，
                // 用 `from: .zero` 的老重载画出来的图标会上下翻 —— 箭头从「指右上」
                // 变成「指右下」，跟主工具条对不上。
                image.draw(in: rect, from: NSRect(origin: .zero, size: size),
                           operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = min(max(Int(point.x / itemWidth), 0), items.count - 1)
        guard index != selectedIndex else { return }
        selectedIndex = index
        onSelect?(index)
    }

    func apply(_ state: AnnotatePropertyBarView.State) {
        guard let index = selectionProvider?(state), index != selectedIndex else { return }
        selectedIndex = index
    }
}

// MARK: - 分隔线

/// 属性条里的竖分隔线：1pt 宽、18pt 高、居中，颜色跟图标一致。
@MainActor
final class PropertySeparator: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        BarPalette.separator.setFill()
        let height = min(18, bounds.height - 6)
        NSRect(x: bounds.midX - 0.5, y: (bounds.height - height) / 2,
               width: 1, height: height).fill()
    }
}

// MARK: - 滑杆

@MainActor
final class PropertySlider: NSView {
    enum Metric {
        case lineWidth, fontSize, opacity, fillAlpha, cornerRadius, mosaicBlock, counterScale
    }

    var metric: Metric = .lineWidth
    var minValue: CGFloat = 0
    var maxValue: CGFloat = 1
    var value: CGFloat = 1 {
        didSet { needsDisplay = true }
    }
    var showsFill = true
    var onChange: ((CGFloat) -> Void)?

    private var dragging = false

    override var isFlipped: Bool { true }

    func apply(_ state: AnnotatePropertyBarView.State) {
        guard !dragging else { return }
        let target: CGFloat
        switch metric {
        case .lineWidth: target = state.style.lineWidth
        case .fontSize: target = state.style.fontSize
        case .opacity: target = CGFloat(state.style.opacity)
        case .fillAlpha: target = CGFloat(state.style.fillAlpha)
        case .cornerRadius: target = state.style.cornerRadius
        case .mosaicBlock: target = state.style.mosaicBlock
        case .counterScale: target = state.style.counterScale
        }
        if abs(target - value) > 0.001 { value = target }
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 10
        let track = NSRect(x: inset, y: bounds.midY - 2, width: bounds.width - inset * 2, height: 4)
        BarPalette.control.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

        let ratio = max(0, min(1, (value - minValue) / (maxValue - minValue)))
        if showsFill, ratio > 0 {
            let filled = NSRect(x: track.minX, y: track.minY,
                                width: track.width * ratio, height: track.height)
            BarPalette.accent.setFill()
            NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
        }

        let knob = NSRect(x: track.minX + track.width * ratio - 9,
                          y: bounds.midY - 9, width: 18, height: 18)
        BarPalette.knob.setFill()
        let dot = NSBezierPath(ovalIn: knob)
        dot.fill()
        // Longshot 的钮是浮在槽上的，加一圈极淡的投影才不糊在底色里
        NSColor.black.withAlphaComponent(0.12).setStroke()
        dot.lineWidth = 1
        dot.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        update(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        update(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    private func update(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inset: CGFloat = 10
        let ratio = max(0, min(1, (point.x - inset) / max(bounds.width - inset * 2, 1)))
        value = minValue + ratio * (maxValue - minValue)
        onChange?(value)
    }
}

// MARK: - 数字输入

@MainActor
final class PropertyNumberField: NSView, NSTextFieldDelegate {
    var onChange: ((Int) -> Void)?
    var value: Int = 1 {
        didSet {
            guard field.currentEditor() == nil else { return }
            field.stringValue = "\(value)"
        }
    }

    private let field = NSTextField()

    init(value: Int) {
        super.init(frame: .zero)
        field.frame = .zero
        field.stringValue = "\(value)"
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = BarPalette.control
        field.textColor = BarPalette.label
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        field.alignment = .center
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        field.layer?.borderWidth = 1
        field.layer?.borderColor = AnnotateBarView.borderColor.cgColor
        field.target = self
        field.action = #selector(commit)
        field.delegate = self
        addSubview(field)
        self.value = value
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 2, y: (bounds.height - 22) / 2,
                             width: bounds.width - 4, height: 22)
    }

    @objc private func commit() {
        let number = max(1, min(999, field.integerValue))
        field.stringValue = "\(number)"
        value = number
        onChange?(number)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commit()
    }
}

// MARK: - 颜色条

@MainActor
final class PropertyColorStrip: NSView {
    /// 4 格 × 32pt，和 Longshot 的 `PPColorListSegmentedControl` 一样：
    /// 三个预置色 + 一格自定义色，装在同一个胶囊里，格子之间只有 1pt 刻度。
    static let preferredWidth: CGFloat = cellWidth * CGFloat(presets.count + 1)
    static let presets = AnnotateColor.palette

    private static let cellWidth: CGFloat = 32
    private static let dotSize: CGFloat = 12
    private static let slotHeight: CGFloat = 22
    /// 自定义色格的序号
    private static let customIndex = presets.count

    var onPick: ((AnnotateColor) -> Void)?
    var current: AnnotateColor = .red {
        didSet {
            // 手挑的非预置色要留在自定义格里；选回预置色时那格继续显示上次挑的
            if !Self.presets.contains(where: { Self.matches($0, current) }) {
                customColor = current
            }
            needsDisplay = true
        }
    }

    /// 自定义格里显示的颜色
    private var customColor: AnnotateColor = .blue
    private var popover: NSPopover?

    override var isFlipped: Bool { true }

    private var capsule: NSRect {
        NSRect(x: 0, y: (bounds.height - Self.slotHeight) / 2,
               width: bounds.width, height: Self.slotHeight)
    }

    private func cellRect(at index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * Self.cellWidth, y: capsule.minY,
               width: Self.cellWidth, height: Self.slotHeight)
    }

    private func dotRect(at index: Int) -> NSRect {
        let cell = cellRect(at: index)
        return NSRect(x: cell.midX - Self.dotSize / 2, y: cell.midY - Self.dotSize / 2,
                      width: Self.dotSize, height: Self.dotSize)
    }

    private var selectedIndex: Int {
        Self.presets.firstIndex(where: { Self.matches($0, current) }) ?? Self.customIndex
    }

    override func draw(_ dirtyRect: NSRect) {
        BarPalette.controlRaised.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2,
                     yRadius: capsule.height / 2).fill()

        // 选中的格子垫一块更亮的底（不描边，Longshot 的选中就是这个观感）
        let selected = selectedIndex
        BarPalette.segmentedSelected.setFill()
        NSBezierPath(roundedRect: cellRect(at: selected), xRadius: 6, yRadius: 6).fill()

        // 刻度：夹在两格之间，紧挨选中格的那条会被选中块盖住
        for index in 1...Self.customIndex where index != selected && index - 1 != selected {
            BarPalette.segmentDivider.setFill()
            NSRect(x: CGFloat(index) * Self.cellWidth - 0.5, y: capsule.midY - 6,
                   width: 1, height: 12).fill()
        }

        for (index, color) in Self.presets.enumerated() {
            fillDot(at: index, color: color)
        }

        // 自定义色：当前手挑的颜色 + 右下角小三角（Longshot 就这么标的）
        fillDot(at: Self.customIndex, color: customColor)
        let dot = dotRect(at: Self.customIndex)
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: dot.maxX - 4, y: dot.maxY - 4))
        triangle.line(to: NSPoint(x: dot.maxX + 2, y: dot.maxY - 4))
        triangle.line(to: NSPoint(x: dot.maxX + 2, y: dot.maxY + 2))
        triangle.close()
        NSColor.black.setFill()
        triangle.fill()
    }

    private func fillDot(at index: Int, color: AnnotateColor) {
        let path = NSBezierPath(ovalIn: dotRect(at: index))
        (NSColor(cgColor: color.cgColor) ?? .red).setFill()
        path.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, color) in Self.presets.enumerated() where cellRect(at: index).contains(point) {
            onPick?(color)
            return
        }
        showSwatches()
    }

    // MARK: - 更多预置色

    /// 箭头按钮弹的是预置色浮层，不是直接开色板。Longshot 的
    /// `PPColorListSegmentedControl` 里 `colors` 是全量预置色、`segmentedColors`
    /// 才是常驻的三个，点箭头就是把这批色摊开。
    private func showSwatches() {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        let content = ColorSwatchPopover(current: current)
        content.onPick = { [weak self] color in
            self?.popover?.close()
            self?.onPick?(color)
        }
        content.onCustom = { [weak self] in
            self?.popover?.close()
            self?.openColorPanel()
        }
        let controller = NSViewController()
        controller.view = content
        // popover 有自己的窗口，外观不会自动跟着主窗口走；动态色（BarPalette）
        // 是按当前 appearance 解析的，这里不显式给就会出现「深色下弹白卡片」。
        content.appearance = NSApp.effectiveAppearance
        let pop = NSPopover()
        pop.behavior = .transient
        pop.appearance = NSApp.effectiveAppearance
        pop.contentViewController = controller
        pop.contentSize = content.preferredSize
        pop.show(relativeTo: NSRect(x: bounds.width - 20, y: bounds.midY - 6, width: 1, height: 12),
                 of: self, preferredEdge: .maxY)
        popover = pop
    }

    // MARK: - 色板

    private func openColorPanel() {
        Self.registerSwatchList()
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        // 拖色轮时不要等松手才生效
        panel.isContinuous = true
        panel.color = NSColor(cgColor: current.cgColor) ?? .red
        // panel 的 target 是弱引用，这里不能塞 self：切工具会把颜色条整个
        // 重建，色板还开着的话 action 就发到已释放的视图上了。
        let bridge = ColorPanelBridge.shared
        bridge.owner = self
        panel.setTarget(bridge)
        panel.setAction(#selector(ColorPanelBridge.panelChanged(_:)))
        // 色板顶部挂一排预置色，任何模式下都能一键取色
        let strip = ColorSwatchRow(colors: AnnotateColor.swatchPalette, current: current)
        strip.onPick = { [weak panel] color in
            panel?.color = NSColor(cgColor: color.cgColor) ?? .red
        }
        panel.accessoryView = strip
        bridge.row = strip
        if !panel.isVisible { placePanel(panel) }
        panel.orderFront(nil)
    }

    /// 色板默认会落到屏幕左下角，离属性条老远。放到工具条正下方，
    /// 挑完色视线不用来回跑；下方放不开就翻到上方。
    private func placePanel(_ panel: NSColorPanel) {
        guard let window else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let size = panel.frame.size
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        var y = anchor.minY - size.height - 10
        if y < visible.minY { y = anchor.maxY + 10 }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 把预置色存成一份 `NSColorList`，色板切到「颜色列表」页就能看到整排
    /// Baton 预置色，而不是只有系统那几套。
    static func registerSwatchList() {
        let name = NSColorList.Name("Baton")
        if NSColorList(name: name).allKeys.isEmpty == false { return }
        let list = NSColorList(name: name)
        for (index, color) in AnnotateColor.swatchPalette.enumerated() {
            list.setColor(NSColor(cgColor: color.cgColor) ?? .red, forKey: "预设 \(index + 1)")
        }
        try? list.write(to: nil)
    }

    private static func matches(_ a: AnnotateColor, _ b: AnnotateColor) -> Bool {
        abs(a.red - b.red) < 0.01 && abs(a.green - b.green) < 0.01 && abs(a.blue - b.blue) < 0.01
    }

}

/// 常驻的色板回调中转。
///
/// `NSColorPanel` 的 target 是弱引用，而属性条每次切工具都会重建颜色条；
/// 直接把颜色条当 target，色板还开着时就会向已释放的对象发消息。
@MainActor
private final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    weak var owner: PropertyColorStrip?
    weak var row: ColorSwatchRow?

    @objc func panelChanged(_ sender: NSColorPanel) {
        guard let color = sender.color.usingColorSpace(.sRGB) else { return }
        let picked = AnnotateColor(red: Double(color.redComponent),
                                   green: Double(color.greenComponent),
                                   blue: Double(color.blueComponent))
        row?.current = picked
        owner?.onPick?(picked)
    }
}

// MARK: - 预置色浮层

/// 点「更多」后弹出来的色块网格，底部留一个「其他颜色…」进系统色板。
@MainActor
final class ColorSwatchPopover: NSView {
    private static let columns = 6
    private static let cell: CGFloat = 28
    private static let padding: CGFloat = 14
    private static let footer: CGFloat = 30

    var onPick: ((AnnotateColor) -> Void)?
    var onCustom: (() -> Void)?

    private let colors = AnnotateColor.swatchPalette
    private let current: AnnotateColor
    private var customRect: NSRect = .zero

    init(current: AnnotateColor) {
        self.current = current
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    var preferredSize: NSSize {
        let rows = ceil(Double(colors.count) / Double(Self.columns))
        let width = Self.padding * 2 + Self.cell * CGFloat(Self.columns)
        let height = Self.padding * 2 + Self.cell * CGFloat(rows) + Self.footer
        return NSSize(width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        BarPalette.background.setFill()
        path.fill()
        BarPalette.border.setStroke()
        path.lineWidth = 1
        path.stroke()

        for (index, color) in colors.enumerated() {
            let column = index % Self.columns
            let row = index / Self.columns
            let cell = NSRect(x: Self.padding + CGFloat(column) * Self.cell,
                              y: Self.padding + CGFloat(row) * Self.cell,
                              width: Self.cell, height: Self.cell)
            ColorSwatch.draw(color, in: cell.insetBy(dx: 6, dy: 6),
                             selected: Self.matches(color, current))
        }

        // 「其他颜色…」
        let y = Self.padding + Self.cell * CGFloat(ceil(Double(colors.count) / Double(Self.columns)))
        customRect = NSRect(x: Self.padding, y: y + 4,
                            width: bounds.width - Self.padding * 2, height: Self.footer - 8)
        ColorSwatch.drawRing(in: NSRect(x: customRect.minX, y: customRect.midY - 8,
                                        width: 16, height: 16))
        let label = "其他颜色…" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: BarPalette.label
        ]
        label.draw(at: NSPoint(x: customRect.minX + 24, y: customRect.midY - 8), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if customRect.contains(point) {
            onCustom?()
            return
        }
        for (index, color) in colors.enumerated() {
            let column = index % Self.columns
            let row = index / Self.columns
            let cell = NSRect(x: Self.padding + CGFloat(column) * Self.cell,
                              y: Self.padding + CGFloat(row) * Self.cell,
                              width: Self.cell, height: Self.cell)
            if cell.contains(point) {
                onPick?(color)
                return
            }
        }
    }

    private static func matches(_ a: AnnotateColor, _ b: AnnotateColor) -> Bool {
        abs(a.red - b.red) < 0.01 && abs(a.green - b.green) < 0.01 && abs(a.blue - b.blue) < 0.01
    }
}

/// 色板顶部的预置色网格。
///
/// 系统色板的宽度是它自己定的（色轮模式约 200pt），横排塞 12 个点只能显示
/// 前 4 个，剩下的被裁掉。所以按固定列数排成网格，尺寸迁就色板宽度。
@MainActor
final class ColorSwatchRow: NSView {
    private static let columns = 6
    private static let diameter: CGFloat = 18
    private static let spacing: CGFloat = 12
    private static let padding: CGFloat = 8

    static var preferredSize: NSSize {
        let width = padding * 2 + CGFloat(columns) * diameter + CGFloat(columns - 1) * spacing
        let rows = ceil(Double(12) / Double(columns))
        let height = padding * 2 + CGFloat(rows) * diameter + CGFloat(rows - 1) * 6
        return NSSize(width: width, height: height)
    }

    var onPick: ((AnnotateColor) -> Void)?

    private let colors: [AnnotateColor]
    /// 跟着色板当前色走，选中环才知道画在哪。
    var current: AnnotateColor {
        didSet { needsDisplay = true }
    }

    init(colors: [AnnotateColor], current: AnnotateColor) {
        self.colors = colors
        self.current = current
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// 每行固定的格子数，宽度对齐后整块居中。
    private var cellSize: NSSize {
        NSSize(width: Self.diameter + Self.spacing, height: Self.diameter + 6)
    }

    private func cellRect(at index: Int) -> NSRect {
        let columns = Self.columns
        let column = index % columns
        let row = index / columns
        let grid = cellSize
        let totalWidth = CGFloat(columns) * grid.width - Self.spacing
        let startX = (bounds.width - totalWidth) / 2
        return NSRect(x: startX + CGFloat(column) * grid.width,
                      y: Self.padding + CGFloat(row) * grid.height,
                      width: Self.diameter, height: Self.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, color) in colors.enumerated() {
            ColorSwatch.draw(color, in: cellRect(at: index),
                             selected: Self.matches(color, current))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, color) in colors.enumerated() {
            // 点击区按整格算，圆点太小不好点
            if cellRect(at: index).insetBy(dx: -Self.spacing / 2, dy: -3).contains(point) {
                onPick?(color)
                return
            }
        }
    }

    private static func matches(_ a: AnnotateColor, _ b: AnnotateColor) -> Bool {
        abs(a.red - b.red) < 0.01 && abs(a.green - b.green) < 0.01 && abs(a.blue - b.blue) < 0.01
    }
}

/// 圆点与彩虹环的公共画法。
@MainActor
enum ColorSwatch {
    static func draw(_ color: AnnotateColor, in rect: NSRect, selected: Bool) {
        let dot = NSBezierPath(ovalIn: rect)
        (NSColor(cgColor: color.cgColor) ?? .red).setFill()
        dot.fill()
        NSColor.black.withAlphaComponent(0.22).setStroke()
        dot.lineWidth = 1
        dot.stroke()
        if selected {
            // 先描一圈底色做「留白」，再在外侧描高对比色；
            // 只描底色的话，深色下圆点边缘看不出选中状态。
            BarPalette.background.setStroke()
            let gap = NSBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5))
            gap.lineWidth = 2
            gap.stroke()
            BarPalette.label.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -4, dy: -4))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    /// 色相环，用来表示「进系统色板」。macOS 的 CGContext 没有圆锥渐变，
    /// 按 36 段扇形拼，肉眼看不出接缝。
    static func drawRing(in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let outer = rect.width / 2
        let inner = outer * 0.55
        let segments = 36
        for index in 0..<segments {
            let start = CGFloat(index) / CGFloat(segments) * 2 * .pi
            let end = CGFloat(index + 1) / CGFloat(segments) * 2 * .pi
            let path = NSBezierPath()
            path.move(to: NSPoint(x: center.x + cos(start) * inner, y: center.y + sin(start) * inner))
            path.line(to: NSPoint(x: center.x + cos(start) * outer, y: center.y + sin(start) * outer))
            path.appendArc(withCenter: center, radius: outer,
                           startAngle: start * 180 / .pi, endAngle: end * 180 / .pi)
            path.line(to: NSPoint(x: center.x + cos(end) * inner, y: center.y + sin(end) * inner))
            path.appendArc(withCenter: center, radius: inner,
                           startAngle: end * 180 / .pi, endAngle: start * 180 / .pi)
            path.close()
            NSColor(hue: CGFloat(index) / CGFloat(segments), saturation: 0.85,
                    brightness: 0.95, alpha: 1).setFill()
            path.fill()
        }
    }
}

// MARK: - 下拉

@MainActor
final class PropertyPopupButton: NSView {
    var onSelect: ((Int) -> Void)?
    var selectionProvider: ((AnnotatePropertyBarView.State) -> Int)?
    var currentIndex = 0 {
        didSet { needsDisplay = true }
    }

    private let options: [String]

    init(title: String, options: [String]) {
        self.options = options
        self.currentIndex = options.firstIndex(of: title) ?? 0
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(_ state: AnnotatePropertyBarView.State) {
        if let index = selectionProvider?(state), index != currentIndex {
            currentIndex = index
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0, dy: 4)
        BarPalette.control.setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        path.fill()
        AnnotateBarView.borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let title = currentIndex < options.count ? options[currentIndex] : ""
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: BarPalette.label,
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: box.minX + 7,
                                             y: box.midY - textSize.height / 2),
                                 withAttributes: attributes)

        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: box.maxX - 12, y: box.midY - 2))
        chevron.line(to: NSPoint(x: box.maxX - 8, y: box.midY + 2))
        chevron.line(to: NSPoint(x: box.maxX - 4, y: box.midY - 2))
        chevron.lineWidth = 1.4
        chevron.lineCapStyle = .round
        AnnotateBarView.iconColor.setStroke()
        chevron.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (index, title) in options.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == currentIndex ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        currentIndex = sender.tag
        onSelect?(sender.tag)
    }
}

// MARK: - 属性条图标

@MainActor
enum PropertyIcon {
    case tool(AnnotateTool)
    case shape(ShapeDrawStyle)
    case line(LinePattern)
    case cap(MarkerCap)
    case mosaic(MosaicPattern)
    case counter(CounterShape)

    func image(size: CGFloat = 18, color: NSColor? = nil) -> NSImage {
        let ink = color ?? AnnotateBarView.iconColor
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let scale = size / 18
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            ink.setStroke()
            ink.setFill()
            self.draw(color: ink)
            return true
        }
    }

    private func draw(color: NSColor) {
        switch self {
        case .tool(let tool):
            AnnotateBarView.glyph(for: tool).image(size: 18, color: color).draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))

        case .shape(let style):
            let rect = NSRect(x: 3, y: 3, width: 12, height: 12)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2.4, yRadius: 2.4)
            switch style {
            case .outline:
                path.lineWidth = 1.5
                path.stroke()
            case .filled:
                path.fill()
            case .hatched:
                path.lineWidth = 1.3
                path.stroke()
                let hatch = NSBezierPath()
                for offset in stride(from: CGFloat(-2), through: 12, by: 4) {
                    hatch.move(to: NSPoint(x: rect.minX + offset, y: rect.maxY))
                    hatch.line(to: NSPoint(x: rect.minX + offset + 8, y: rect.minY))
                }
                hatch.lineWidth = 1
                hatch.stroke()
            }

        case .line(let pattern):
            // Longshot：实线画一条横线，虚线画三个点
            switch pattern {
            case .solid:
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 3.5, y: 9))
                path.line(to: NSPoint(x: 14.5, y: 9))
                path.lineWidth = 1.8
                path.lineCapStyle = .round
                path.stroke()
            case .dashed:
                for x in stride(from: CGFloat(4.5), through: 13.5, by: 4.5) {
                    NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: 7.9, width: 2.2, height: 2.2)).fill()
                }
            }

        case .cap(let cap):
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 4, y: 6))
            path.line(to: NSPoint(x: 14, y: 12))
            path.lineWidth = 4.2
            path.lineCapStyle = cap == .round ? .round : .square
            path.stroke()

        case .mosaic(let pattern):
            let rect = NSRect(x: 3.2, y: 3.2, width: 11.6, height: 11.6)
            switch pattern {
            case .square:
                for row in 0..<2 {
                    for column in 0..<2 {
                        let cell = NSRect(x: rect.minX + CGFloat(column) * 6.1,
                                          y: rect.minY + CGFloat(row) * 6.1,
                                          width: 5.2, height: 5.2)
                        NSBezierPath(roundedRect: cell, xRadius: 1, yRadius: 1).fill()
                    }
                }
            case .hexagon:
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 9, y: 3.2))
                path.line(to: NSPoint(x: 14.6, y: 6.4))
                path.line(to: NSPoint(x: 14.6, y: 11.8))
                path.line(to: NSPoint(x: 9, y: 15))
                path.line(to: NSPoint(x: 3.4, y: 11.8))
                path.line(to: NSPoint(x: 3.4, y: 6.4))
                path.close()
                path.fill()
            case .crystal:
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 9, y: 3.2))
                path.line(to: NSPoint(x: 14.8, y: 9))
                path.line(to: NSPoint(x: 9, y: 14.8))
                path.line(to: NSPoint(x: 3.2, y: 9))
                path.close()
                path.fill()
            case .blur:
                for (radius, alpha) in [(CGFloat(5.4), CGFloat(0.25)),
                                        (3.8, 0.45), (2.2, 0.75)] {
                    let dot = NSRect(x: 9 - radius, y: 9 - radius,
                                     width: radius * 2, height: radius * 2)
                    color.withAlphaComponent(alpha).setFill()
                    NSBezierPath(ovalIn: dot).fill()
                }
            }

        case .counter(let shape):
            let path = NSBezierPath()
            switch shape {
            case .circle:
                path.appendOval(in: NSRect(x: 3, y: 3, width: 12, height: 12))
            case .balloon:
                path.move(to: NSPoint(x: 9, y: 15))
                path.curve(to: NSPoint(x: 15, y: 9.6),
                           controlPoint1: NSPoint(x: 9, y: 15),
                           controlPoint2: NSPoint(x: 15, y: 12.6))
                path.curve(to: NSPoint(x: 9, y: 3),
                           controlPoint1: NSPoint(x: 15, y: 6.4),
                           controlPoint2: NSPoint(x: 12.4, y: 3))
                path.curve(to: NSPoint(x: 3, y: 9.6),
                           controlPoint1: NSPoint(x: 5.6, y: 3),
                           controlPoint2: NSPoint(x: 3, y: 6.4))
                path.curve(to: NSPoint(x: 9, y: 15),
                           controlPoint1: NSPoint(x: 3, y: 12.6),
                           controlPoint2: NSPoint(x: 9, y: 15))
            case .blob:
                path.move(to: NSPoint(x: 9, y: 3))
                path.curve(to: NSPoint(x: 15, y: 10.4),
                           controlPoint1: NSPoint(x: 12.6, y: 3),
                           controlPoint2: NSPoint(x: 15, y: 6.6))
                path.curve(to: NSPoint(x: 9, y: 15),
                           controlPoint1: NSPoint(x: 15, y: 13),
                           controlPoint2: NSPoint(x: 11.4, y: 14.8))
                path.curve(to: NSPoint(x: 3, y: 10.4),
                           controlPoint1: NSPoint(x: 6.6, y: 14.8),
                           controlPoint2: NSPoint(x: 3, y: 13))
                path.curve(to: NSPoint(x: 9, y: 3),
                           controlPoint1: NSPoint(x: 3, y: 6.6),
                           controlPoint2: NSPoint(x: 5.4, y: 3))
            }
            path.lineWidth = 1.5
            path.stroke()
            // 中心挖一个小点，表示「里面有数字」
            color.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: NSRect(x: 7.6, y: 7.6, width: 2.8, height: 2.8)).fill()
        }
    }
}

// MARK: - 改动落地

extension AnnotatePropertyBarView.Change {
    /// 把属性条的一次改动合进样式，尺寸类按 `scale`（图片像素 / 点）换算。
    ///
    /// 返回 false 表示这条改动不是「改样式」，调用方要自己处理：
    /// 切工具要换画布工具，改序号要落到图元上。
    /// 原地标注、弹窗标注、贴图标注三处共用，别各写一份漂出去。
    func merge(into style: inout AnnotateStyle, scale: CGFloat) -> Bool {
        switch self {
        case .tool, .counterNumber:
            return false
        case .color(let color): style.color = color
        case .lineWidth(let points): style.lineWidth = points * scale
        case .fontSize(let points): style.fontSize = points * scale
        case .opacity(let value): style.opacity = value
        case .fillAlpha(let value): style.fillAlpha = value
        case .cornerRadius(let points): style.cornerRadius = points * scale
        case .mosaicBlock(let points): style.mosaicBlock = points * scale
        case .counterScale(let value): style.counterScale = value
        case .shapeDrawStyle(let value): style.shapeDrawStyle = value
        case .linePattern(let value): style.linePattern = value
        case .markerCap(let value): style.markerCap = value
        case .mosaicPattern(let value): style.mosaicPattern = value
        case .counterShape(let value): style.counterShape = value
        case .textMarkStyle(let value): style.textMarkStyle = value
        case .fontName(let value): style.fontName = value
        }
        return true
    }
}

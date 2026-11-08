import AppKit

/// Bob 风格控件的公共件：底色、卡片、图标按钮、加载点。
///
/// 翻译浮窗和 OCR 窗口是同一套视觉语言，控件放一处，
/// 以后调色只改这里——照着两个窗口各抄一份，改一次就要改两遍，早晚不一致。
enum BobTheme {
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 窗口底：Bob 量出来是 #F9F9F9
    static func panelColor(_ appearance: NSAppearance) -> NSColor {
        isDark(appearance) ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.976, alpha: 1)
    }

    /// 卡片底：#EFEFEF
    static func cardColor(_ appearance: NSAppearance) -> NSColor {
        isDark(appearance) ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.937, alpha: 1)
    }

    static func borderColor(_ appearance: NSAppearance) -> NSColor {
        isDark(appearance) ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.06)
    }

    static let cardRadius: CGFloat = 10
    static let panelRadius: CGFloat = 14
}

/// 圆角底卡片。
@MainActor
class BubbleCard: NSView {
    /// 卡片里的坐标一律按「上到下」算：翻译浮窗、OCR 窗都是这个方向，
    /// 少一次翻转换算，少一类排版偏上的 bug。
    override var isFlipped: Bool { true }

    var radius: CGFloat = BobTheme.cardRadius {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = BobTheme.cardColor(effectiveAppearance).cgColor
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 无边框 SF Symbol 按钮，悬停时给一块淡底。
@MainActor
class IconButton: NSButton {
    private var hovered = false

    init(symbol: String, tooltip: String, pointSize: CGFloat = 14) {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        toolTip = tooltip
        self.pointSize = pointSize
        setSymbol(symbol, tint: .secondaryLabelColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var pointSize: CGFloat = 14

    func setSymbol(_ name: String, tint: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(config)
        contentTintColor = tint
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered, isEnabled {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3),
                         xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// 可切换的图标按钮（图钉）：开启后图标变实心。
@MainActor
final class IconToggle: IconButton {
    private let symbol: String
    private let activeSymbol: String

    var isOn = false {
        didSet { refresh() }
    }

    init(symbol: String, activeSymbol: String, tooltip: String) {
        self.symbol = symbol
        self.activeSymbol = activeSymbol
        super.init(symbol: symbol, tooltip: tooltip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        setSymbol(isOn ? activeSymbol : symbol,
                  tint: isOn ? .controlAccentColor : .secondaryLabelColor)
    }
}

/// 三个跳动的点，替代转圈：Bob 的卡头加载态就是这个。
@MainActor
final class LoadingDots: NSView {
    private var dots: [NSView] = []
    private var timer: Timer?
    private var phase = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for _ in 0..<3 {
            let dot = NSView()
            dot.wantsLayer = true
            // 暖黄，跟 Bob 的加载点一个色；灰色太容易被当成禁用
            dot.layer?.backgroundColor = NSColor(srgbRed: 0.97, green: 0.73, blue: 0.18,
                                                 alpha: 1).cgColor
            dot.layer?.cornerRadius = 2.5
            dot.alphaValue = 0.25
            addSubview(dot)
            dots.append(dot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        for (index, dot) in dots.enumerated() {
            dot.frame = NSRect(x: CGFloat(index) * 9, y: (bounds.height - 5) / 2, width: 5, height: 5)
        }
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 0.22, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.phase = (self.phase + 1) % 3
                for (index, dot) in self.dots.enumerated() {
                    dot.alphaValue = index == self.phase ? 0.9 : 0.25
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        dots.forEach { $0.alphaValue = 0.25 }
    }
}

/// 引擎图标：品牌色圆角方块 + 名称首字，比灰色占位看起来像「服务」。
@MainActor
final class ProviderIcon: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let palette: [String: NSColor] = [
        "deepseek": NSColor(srgbRed: 0.30, green: 0.42, blue: 0.99, alpha: 1),
        "baidu": NSColor(srgbRed: 0.16, green: 0.20, blue: 0.88, alpha: 1),
        "openai": NSColor(srgbRed: 0.06, green: 0.64, blue: 0.50, alpha: 1),
        "zhipu": NSColor(srgbRed: 0.12, green: 0.44, blue: 1.00, alpha: 1),
        "kimi": NSColor(srgbRed: 0.35, green: 0.35, blue: 0.38, alpha: 1),
        "ocr": NSColor(srgbRed: 0.96, green: 0.55, blue: 0.20, alpha: 1),
    ]

    func configure(id: String, name: String) {
        let key = id.lowercased()
        var color = NSColor.systemGray
        for (prefix, value) in Self.palette where key.contains(prefix) {
            color = value
            break
        }
        layer?.backgroundColor = color.cgColor
        label.stringValue = String(name.prefix(1))
        label.toolTip = name
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 13) / 2,
                             width: bounds.width, height: 13)
    }
}

/// 语言条上的文字按钮：文字 + 小三角，点击弹菜单。
@MainActor
final class MenuChip: NSView {
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    var onClick: (() -> Void)?

    var title: String = "" {
        didSet {
            label.stringValue = title
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.alignment = .center
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        chevron.contentTintColor = .labelColor
        chevron.imageScaling = .scaleProportionallyDown
        addSubview(label)
        addSubview(chevron)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let textWidth = ceil(label.intrinsicContentSize.width)
        let total = textWidth + 5 + 9
        let startX = (bounds.width - total) / 2
        label.frame = NSRect(x: startX, y: (bounds.height - 17) / 2, width: textWidth, height: 17)
        chevron.frame = NSRect(x: startX + textWidth + 5, y: (bounds.height - 8) / 2,
                               width: 9, height: 8)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

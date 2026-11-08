import AppKit
import CoreGraphics
import Foundation

/// OCR 结果窗口。
///
/// 照 Bob 的「剪贴板 OCR / 截图 OCR」窗口复刻：左边原图 + 识别框，右边可编辑文本，
/// 底部一排图标（复制 / 翻译 / 导出 / 语言），左下角三档视图切换（图文 / 文本 / 纯文本）。
///
/// 尺寸 788×440 是量 Bob 出来的；左边图、右边文，才看得出「这段字是从图上哪来的」，
/// 只给一坨文本的话，用户没法核对识别得对不对。
@MainActor
public final class OCRPanelController {
    static let size = NSSize(width: 788, height: 440)

    private let panel: KeyablePanel
    private let content: OCRContentView

    /// 参数是（识别文本, 目标语言）。目标语言来自右下角胶囊，用户可以改。
    public var onTranslate: ((String, String) -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onCapture: (() -> Void)?
    public var onRecognizeImage: ((CGImage) -> Void)?

    public init() {
        content = OCRContentView(frame: NSRect(origin: .zero, size: Self.size))
        panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content

        content.onTranslate = { [weak self] text, target in self?.onTranslate?(text, target) }
        content.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        content.onClose = { [weak self] in self?.hide() }
        content.onCapture = { [weak self] in self?.onCapture?() }
        content.onRecognizeImage = { [weak self] image in self?.onRecognizeImage?(image) }
    }

    public var isVisible: Bool { panel.isVisible }

    /// `codes` 是图里识别出的二维码，非空时右侧会多出一条「识别到二维码」区域（Bob 同款）。
    public func show(image: CGImage, lines: [OCRLine], text: String, engine: String,
                     copiedHint: String?, codes: [QRCode] = []) {
        content.render(image: image, lines: lines, codes: codes, text: text, engine: engine)
        // 窗口比浮窗大，先摆到鼠标所在屏的中间偏上，别一半在屏幕外
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let x = visible.midX - Self.size.width / 2
            let y = visible.maxY - Self.size.height - 120
            panel.setFrameOrigin(CGPoint(x: max(x, visible.minX + 12), y: max(y, visible.minY + 12)))
        }
        let appearing = !panel.isVisible
        if appearing { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        if appearing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
        if let copiedHint {
            content.showToast(copiedHint)
        }
    }

    public func hide() {
        panel.orderOut(nil)
    }
}

// MARK: - 内容视图

@MainActor
private final class OCRContentView: NSView {
    enum ViewMode: Int {
        case split
        case text
        case plain
    }

    private static let inset: CGFloat = 12
    private static let toolbarHeight: CGFloat = 40
    private static let bottomInset: CGFloat = 15
    private static let gap: CGFloat = 8
    private static let bottomBarHeight: CGFloat = 34

    private let pinButton = IconToggle(symbol: "pin", activeSymbol: "pin.fill",
                                       tooltip: "钉住窗口")
    private let engineButton = PillButton()
    private let captureButton = IconButton(symbol: "scissors", tooltip: "重新截图识别", pointSize: 15)
    private let openButton = IconButton(symbol: "folder", tooltip: "打开图片识别", pointSize: 15)
    private let clipboardButton = IconButton(symbol: "doc.on.clipboard", tooltip: "识别剪贴板图片", pointSize: 15)
    private let settingsButton = IconButton(symbol: "slider.horizontal.3", tooltip: "OCR 设置", pointSize: 15)

    private let imageCard = BubbleCard()
    private let canvas = ImageCanvas()
    private let modeSwitch = ModeSwitch()

    private let textCard = BubbleCard()
    private let textScroll: NSScrollView
    private let textView: NSTextView

    /// 二维码区：分隔线 + 「识别到二维码」小标签 + 可编辑的码内容。
    /// 有码才出现，没有码时这块整片藏起来，文本区直接用满高度。
    private let codeDivider = NSView()
    private let codeChip = CodeChip()
    private let codeScroll: NSScrollView
    private let codeTextView: NSTextView

    private let copyButton = IconButton(symbol: "square.on.square", tooltip: "复制文本", pointSize: 15)
    private let translateButton = IconButton(symbol: "character.book.closed", tooltip: "翻译这段文字", pointSize: 15)
    private let exportButton = IconButton(symbol: "square.and.arrow.up", tooltip: "导出为文本文件", pointSize: 15)
    private let languageChip = PillButton()
    /// 右下角胶囊选的目标语言，只影响「翻译这段文字」这一下
    private var targetLanguage = "zh-Hans"

    private let toast = ToastView()

    var onTranslate: ((String, String) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCapture: (() -> Void)?
    var onRecognizeImage: ((CGImage) -> Void)?
    var onClose: (() -> Void)?

    private var mode: ViewMode = .split
    private var rawText = ""
    private var mergedText = ""
    private var lines: [OCRLine] = []
    private var codes: [QRCode] = []

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        let created = Self.makeTextView()
        textScroll = created.scroll
        textView = created.textView
        let code = Self.makeTextView()
        codeScroll = code.scroll
        codeTextView = code.textView
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = BobTheme.panelColor(effectiveAppearance).cgColor
        layer?.borderColor = BobTheme.borderColor(effectiveAppearance).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = BobTheme.panelRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        codeDivider.layer?.backgroundColor = BobTheme.borderColor(effectiveAppearance).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func build() {
        wantsLayer = true
        layer?.masksToBounds = true

        pinButton.target = self
        pinButton.action = #selector(togglePin)
        engineButton.target = self
        engineButton.action = #selector(openSettings)
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        copyButton.target = self
        copyButton.action = #selector(copyText)
        translateButton.target = self
        translateButton.action = #selector(translate)
        exportButton.target = self
        exportButton.action = #selector(exportText)
        captureButton.target = self
        captureButton.action = #selector(recapture)
        openButton.target = self
        openButton.action = #selector(openImage)
        clipboardButton.target = self
        clipboardButton.action = #selector(recognizeClipboard)
        languageChip.target = self
        languageChip.action = #selector(pickLanguage)

        modeSwitch.onChange = { [weak self] mode in self?.apply(mode: mode) }

        imageCard.addSubview(canvas)
        textCard.addSubview(textScroll)
        textCard.addSubview(copyButton)
        textCard.addSubview(translateButton)
        textCard.addSubview(exportButton)
        textCard.addSubview(languageChip)

        codeDivider.wantsLayer = true
        codeDivider.isHidden = true
        codeChip.isHidden = true
        codeScroll.isHidden = true
        textCard.addSubview(codeDivider)
        textCard.addSubview(codeChip)
        textCard.addSubview(codeScroll)

        for view in [pinButton, engineButton, captureButton, openButton, clipboardButton,
                     settingsButton, imageCard, textCard, modeSwitch, toast] {
            addSubview(view)
        }
    }

    // MARK: 内容

    func render(image: CGImage, lines: [OCRLine], codes: [QRCode], text: String, engine: String) {
        self.lines = lines
        self.codes = codes
        rawText = text
        mergedText = Self.mergeParagraphs(lines.isEmpty ? [text] : lines.map(\.text))
        // 用 NSBitmapImageRep 自己包一层：`NSImage(cgImage:size:)` 会按屏幕 scale 再放大一档，
        // 画布拿到的 pixelsWide 变成两倍，识别框就只能画在左上角一小块里。
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        let preview = NSImage(size: rep.size)
        preview.addRepresentation(rep)
        canvas.image = preview
        canvas.lines = lines
        canvas.codes = codes
        engineButton.title = engine
        codeTextView.string = Self.codeListing(codes)
        updateCodeSection()
        apply(mode: mode)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// 多张码之间空一行：Bob 也是这么排的，挤在一起会看成一条内容。
    private static func codeListing(_ codes: [QRCode]) -> String {
        codes.map(\.payload).joined(separator: "\n\n")
    }

    private func updateCodeSection() {
        let hasCodes = !codes.isEmpty
        codeDivider.isHidden = !hasCodes
        codeChip.isHidden = !hasCodes
        codeScroll.isHidden = !hasCodes
        // 有二维码时「复制」是一组三选项（码 / 文本 / 全部），右键或长按出菜单
        if hasCodes {
            let menu = NSMenu()
            menu.addItem(menuItem("复制二维码的内容", #selector(copyCodes)))
            menu.addItem(menuItem("复制文本框的内容", #selector(copyTextBox)))
            menu.addItem(menuItem("复制所有", #selector(copyEverything)))
            copyButton.menu = menu
            copyButton.toolTip = "复制所有（右键可只复制二维码或文本）"
        } else {
            copyButton.menu = nil
            copyButton.toolTip = "复制文本"
        }
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func apply(mode: ViewMode) {
        self.mode = mode
        modeSwitch.select(mode)
        canvas.showsBoxes = mode == .split
        // 原图始终留在左边（Bob 也这样），三档只改识别框和文本的排法
        textView.string = mode == .plain ? mergedText : rawText
        textView.font = NSFont.systemFont(ofSize: 17)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 6, height: 8)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// 纯文本模式：把逐行结果合成段落——中文直接接上，英文补一个空格。
    private static func mergeParagraphs(_ lines: [String]) -> String {
        var out = ""
        for line in lines where !line.isEmpty {
            if out.isEmpty {
                out = line
            } else if let last = out.unicodeScalars.last, last.value < 0x2E80 {
                out += " " + line
            } else {
                out += line
            }
        }
        return out
    }

    func showToast(_ text: String) {
        toast.show(text)
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        let width = bounds.width

        pinButton.frame = NSRect(x: 5, y: 3, width: 34, height: 34)
        var x = width - 5 - 34
        for button in [settingsButton, clipboardButton, openButton, captureButton] {
            button.frame = NSRect(x: x, y: 3, width: 34, height: 34)
            x -= 32
        }
        engineButton.frame = NSRect(x: x - 102, y: 11, width: 102, height: 22)

        let cardTop = Self.toolbarHeight
        let cardHeight = bounds.height - cardTop - Self.bottomInset
        let leftWidth = (bounds.width - Self.inset * 2 - Self.gap) / 2

        imageCard.frame = NSRect(x: Self.inset, y: cardTop, width: leftWidth, height: cardHeight)
        canvas.frame = NSRect(x: 10, y: 10, width: leftWidth - 20, height: cardHeight - 20)
        modeSwitch.frame = NSRect(x: imageCard.frame.midX - 84, y: cardTop + cardHeight - 38,
                                  width: 168, height: 28)

        let rightX = Self.inset + leftWidth + Self.gap
        textCard.frame = NSRect(x: rightX, y: cardTop,
                                width: bounds.width - Self.inset - rightX, height: cardHeight)
        let cardWidth = textCard.bounds.width
        let barTop = cardHeight - Self.bottomBarHeight
        var textBottom = barTop

        if !codes.isEmpty {
            // 二维码区 = 上留白 + 小标签 + 8 + 码内容 + 下留白；
            // 最多吃 45%，文本区不能被挤到看不见。
            let pad: CGFloat = 10
            let contentWidth = cardWidth - 16
            let chipHeight = CodeChip.height
            let wanted = pad + chipHeight + 8 + Self.textHeight(codeTextView.string,
                                                                width: contentWidth) + pad
            let section = min(max(wanted, 110), max(barTop * 0.45, 110))
            let sectionTop = barTop - section
            codeDivider.frame = NSRect(x: 0, y: sectionTop - 1, width: cardWidth, height: 1)
            codeChip.frame = NSRect(x: 8, y: sectionTop + pad,
                                    width: codeChip.fittingWidth, height: chipHeight)
            let listTop = codeChip.frame.maxY + 8
            codeScroll.frame = NSRect(x: 8, y: listTop, width: contentWidth,
                                      height: max(barTop - 8 - listTop, 22))
            codeTextView.frame = NSRect(x: 0, y: 0, width: codeScroll.bounds.width,
                                        height: max(Self.textHeight(codeTextView.string,
                                                                    width: contentWidth),
                                                    codeScroll.bounds.height))
            codeTextView.textContainer?.containerSize = NSSize(width: codeScroll.bounds.width,
                                                               height: .greatestFiniteMagnitude)
            textBottom = sectionTop - 6
        }

        textScroll.frame = NSRect(x: 8, y: 6, width: cardWidth - 16,
                                  height: max(textBottom - 6, 30))
        textView.frame = NSRect(x: 0, y: 0, width: textScroll.bounds.width,
                                height: textScroll.bounds.height)
        textView.textContainer?.containerSize = NSSize(width: textScroll.bounds.width,
                                                       height: .greatestFiniteMagnitude)

        let barY = cardHeight - Self.bottomBarHeight + 4
        copyButton.frame = NSRect(x: 8, y: barY, width: 28, height: 28)
        translateButton.frame = NSRect(x: 36, y: barY, width: 28, height: 28)
        exportButton.frame = NSRect(x: 64, y: barY, width: 28, height: 28)
        languageChip.title = TranslateSettings.languageName(for: targetLanguage)
        let chipWidth = max(ceil(languageChip.attributedTitle.size().width) + 16, 78)
        languageChip.frame = NSRect(x: 96, y: barY + 3, width: chipWidth, height: 22)

        toast.frame = NSRect(x: bounds.midX - 110, y: 8, width: 220, height: 30)
    }

    // MARK: 动作

    /// Esc 关窗：Windows 用户的肌肉记忆，Bob 也吃这个键
    override func cancelOperation(_ sender: Any?) { onClose?() }

    @objc private func togglePin() {
        pinButton.isOn.toggle()
        window?.level = pinButton.isOn ? .floating : .normal
    }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func copyText() {
        // 有二维码时点一下就是「复制所有」，跟 Bob 一致；只要一部分走右键菜单
        if codes.isEmpty {
            copy(textView.string, label: "文本")
        } else {
            copyEverything()
        }
    }

    @objc private func copyCodes() { copy(codeListing, label: "二维码内容") }

    @objc private func copyTextBox() { copy(textView.string, label: "文本") }

    @objc private func copyEverything() { copy(combinedText, label: "全部内容") }

    /// 码内容以文本框里的为准：那块是可编辑的，改了还按原始结果复制就成了睁眼说瞎话。
    private var codeListing: String {
        let edited = codeTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return edited.isEmpty ? Self.codeListing(codes) : edited
    }

    /// 文本 + 二维码内容，中间空一行：落进剪贴板的东西要一眼分得出是两段。
    private var combinedText: String {
        var parts: [String] = []
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append(text) }
        let listing = codeListing
        if !listing.isEmpty { parts.append(listing) }
        return parts.joined(separator: "\n\n")
    }

    private func copy(_ text: String, label: String) {
        guard !text.isEmpty else {
            showToast("没有可复制的内容")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyButton.setSymbol("checkmark", tint: .systemGreen)
        showToast("已复制\(label) \(text.count) 个字符")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.copyButton.setSymbol("square.on.square", tint: .secondaryLabelColor)
        }
    }

    @objc private func translate() {
        let text = textView.string
        guard !text.isEmpty else { return }
        onTranslate?(text, targetLanguage)
    }

    @objc private func pickLanguage() {
        let menu = NSMenu()
        for language in TranslateSettings.languages {
            let item = NSMenuItem(title: language.name,
                                  action: #selector(pickLanguageItem(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = language.code
            item.state = targetLanguage == language.code ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: languageChip.bounds.height + 2),
                   in: languageChip)
    }

    @objc private func pickLanguageItem(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        targetLanguage = code
        languageChip.title = TranslateSettings.languageName(for: code)
        needsLayout = true
    }

    @objc private func recapture() { onCapture?() }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        onRecognizeImage?(cgImage)
    }

    @objc private func recognizeClipboard() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self],
                                                            options: nil)?.first as? NSImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            showToast("剪贴板里没有图片")
            return
        }
        onRecognizeImage?(cgImage)
    }

    @objc private func exportText() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OCR.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? textView.string.write(to: url, atomically: true, encoding: .utf8)
        showToast("已导出到 \(url.lastPathComponent)")
    }

    /// 纯文本按 17pt 排下来要多高。文本框左右各有 6pt 内缩，宽度要先扣掉。
    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 17),
        ])
        return ceil(attributed.boundingRect(with: NSSize(width: max(width - 12, 40),
                                                         height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading])
            .height) + 16
    }

    private static func makeTextView() -> (scroll: NSScrollView, textView: NSTextView) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 300))
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 17)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.allowsUndo = true
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 17),
            .foregroundColor: NSColor.labelColor,
        ]

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return (scroll, textView)
    }
}

// MARK: - 图片画布

/// 原图 + 蓝色识别框。框用 OCR 返回的像素坐标，按「等比适配」换算到视图里。
@MainActor
private final class ImageCanvas: NSView {
    // 这几个属性是「窗口已经显示着、内容整块换掉」的唯一入口，
    // 不标脏的话画布会一直留着上一次（或空白）的位图。
    var image: NSImage? { didSet { needsDisplay = true } }
    var lines: [OCRLine] = [] { didSet { needsDisplay = true } }
    var codes: [QRCode] = [] { didSet { needsDisplay = true } }
    var showsBoxes = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let pixels = image.representations.first.map {
            NSSize(width: CGFloat($0.pixelsWide), height: CGFloat($0.pixelsHigh))
        } ?? image.size
        guard pixels.width > 0, pixels.height > 0 else { return }

        let scale = min(bounds.width / pixels.width, bounds.height / pixels.height)
        let width = pixels.width * scale
        let height = pixels.height * scale
        // 贴顶不居中：短条选区（一行两句）居中的话像一张飘在空卡里的碎纸
        let rect = NSRect(x: (bounds.width - width) / 2,
                          y: 0,
                          width: width, height: height)

        // 图片本身垫一层白：截图多是浅底的，放在灰卡上不垫白会像缺了一块
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)

        guard showsBoxes, !lines.isEmpty || !codes.isEmpty else { return }
        let fill = NSColor(srgbRed: 0.16, green: 0.48, blue: 1, alpha: 0.14)
        let stroke = NSColor(srgbRed: 0.16, green: 0.48, blue: 1, alpha: 0.55)
        for line in lines where !line.points.isEmpty {
            let path = NSBezierPath()
            for (index, point) in line.points.enumerated() {
                let converted = NSPoint(x: rect.minX + point.x * scale,
                                        y: rect.minY + point.y * scale)
                if index == 0 { path.move(to: converted) } else { path.line(to: converted) }
            }
            path.close()
            // 缩小后相邻两行的框会贴在一起变成一条，内缩 1pt 留出细缝
            let boxed = path.bounds.insetBy(dx: 1, dy: 1)
            let shape = NSBezierPath(roundedRect: boxed, xRadius: 2, yRadius: 2)
            fill.setFill()
            shape.fill()
            stroke.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }

        // 二维码用橙色、只描边不填色：填色会盖住码本身，而码得能扫（Bob 也这么画）
        let codeStroke = NSColor(srgbRed: 0.94, green: 0.54, blue: 0.20, alpha: 1)
        for code in codes where !code.points.isEmpty {
            let path = NSBezierPath()
            for (index, point) in code.points.enumerated() {
                let converted = NSPoint(x: rect.minX + point.x * scale,
                                        y: rect.minY + point.y * scale)
                if index == 0 { path.move(to: converted) } else { path.line(to: converted) }
            }
            path.close()
            codeStroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - 控件

/// 左上角的引擎胶囊：白底细边，看起来像 Bob 的「百度 OCR ⌄」。
@MainActor
private final class PillButton: NSButton {
    var titleText: String = "OCR" {
        didSet { refresh() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var title: String {
        get { titleText }
        set { titleText = newValue }
    }

    private func refresh() {
        let dark = BobTheme.isDark(effectiveAppearance)
        let base = NSColor.labelColor.withAlphaComponent(0.82)
        let text = NSMutableAttributedString(string: "\(titleText)  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: base,
        ])
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)) {
            let attachment = NSTextAttachment()
            attachment.image = chevron
            text.append(NSAttributedString(attachment: attachment))
        }
        attributedTitle = text
        layer?.backgroundColor = (dark ? NSColor(white: 0.22, alpha: 1) : NSColor.white).cgColor
        layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.12)
                                   : NSColor(white: 0, alpha: 0.08)).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        wantsLayer = true
    }

    override func layout() {
        super.layout()
        refresh()
    }
}

/// 三档视图切换：灰色胶囊 + 白色滑块，跟 Bob 左下角那个一样。
@MainActor
private final class ModeSwitch: NSView {
    private let background = NSView()
    private let indicator = NSView()
    private let buttons: [NSButton] = [
        ("rectangle.split.2x1", "图文对照：原图 + 识别框"),
        ("rectangle.dashed", "原文：不画识别框"),
        ("text.alignleft", "段落：把逐行结果合并成段落"),
    ].map { symbol, tip in
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.toolTip = tip
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        button.contentTintColor = .labelColor
        return button
    }

    var onChange: ((OCRContentView.ViewMode) -> Void)?
    private var selected: OCRContentView.ViewMode = .split

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 11
        indicator.layer?.shadowColor = NSColor.black.cgColor
        indicator.layer?.shadowOpacity = 0.12
        indicator.layer?.shadowRadius = 2
        indicator.layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(background)
        addSubview(indicator)
        for (index, button) in buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(tapped(_:))
            addSubview(button)
        }
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// 深色下白色滑块会把图标吃掉，换成一块浅一档的灰。
    private func applyColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        background.layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.10)
                                                   : NSColor(white: 0, alpha: 0.06)).cgColor
        indicator.layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.20)
                                                 : NSColor.white).cgColor
        indicator.layer?.shadowOpacity = dark ? 0 : 0.12
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ mode: OCRContentView.ViewMode) {
        selected = mode
        needsLayout = true
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        let cell = (bounds.width - 4) / 3
        indicator.frame = NSRect(x: 2 + cell * CGFloat(selected.rawValue), y: 2,
                                 width: cell, height: bounds.height - 4)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 2 + cell * CGFloat(index), y: 2,
                                  width: cell, height: bounds.height - 4)
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        guard let mode = OCRContentView.ViewMode(rawValue: sender.tag) else { return }
        selected = mode
        needsLayout = true
        onChange?(mode)
    }
}

/// 「识别到二维码」小标签：浅灰底 + 小码图标，位置和字号都照 Bob 量。
@MainActor
private final class CodeChip: NSView {
    static let height: CGFloat = 20

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "识别到二维码")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        icon.image = NSImage(systemSymbolName: "qrcode", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        addSubview(label)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        let dark = BobTheme.isDark(effectiveAppearance)
        layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.10)
                                       : NSColor(white: 0, alpha: 0.05)).cgColor
    }

    var fittingWidth: CGFloat {
        ceil(label.intrinsicContentSize.width) + 6 + 12 + 5 + 8
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 6, y: (bounds.height - 12) / 2, width: 12, height: 12)
        label.frame = NSRect(x: 6 + 12 + 5, y: (bounds.height - 16) / 2,
                             width: ceil(label.intrinsicContentSize.width), height: 16)
    }
}

/// 绿色胶囊提示，Bob 复制成功后会从顶部中间浮一个出来。
@MainActor
private final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private var hideTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.30, green: 0.78, blue: 0.35, alpha: 1).cgColor
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                              accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        check.contentTintColor = .white
        addSubview(check)
        addSubview(label)
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String) {
        label.stringValue = text
        needsLayout = true
        hideTask?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self?.animator().alphaValue = 0
            }
        }
    }

    override func layout() {
        super.layout()
        let textWidth = ceil(label.intrinsicContentSize.width)
        let total = 16 + 5 + textWidth
        let startX = (bounds.width - total) / 2
        check.frame = NSRect(x: startX, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: startX + 19, y: (bounds.height - 17) / 2,
                             width: textWidth, height: 17)
    }
}

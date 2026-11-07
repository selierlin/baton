import AppKit

/// 一页设置。页面内部都是从顶往下排一列，所以 `height` 只影响窗口高度，多出的空间留在底部。
private struct SettingsPage {
    let identifier: NSToolbarItem.Identifier
    let title: String
    let symbol: String
    let view: NSView
    var height: CGFloat
}

/// 偏好设置窗口。页签：通用、输入法、测量、网页输入法、翻译、OCR、热键、历史（测量可选）。
///
/// 顶部用 `NSToolbar`（`.preference` 样式）切页，而不是 `NSTabView` 的方框标签——
/// 后者是 10.10 时代的外观，在一堆原生设置窗口旁边看着像另一个年代的东西。
/// 窗口高度跟着当前页走，切页时保持顶边不动。
@MainActor
public final class PreferencesWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    public var onChange: (() -> Void)?
    /// 窗口关闭时回调，调用方据此把激活策略退回 accessory。
    public var onClose: (() -> Void)?

    private let loginItem: LoginItem
    private weak var inputSource: InputSourceService?
    private weak var smoothScroll: ScrollSmoother?
    private weak var clipboard: ClipboardStore?
    private let rulerSettings: RulerSettingsStore?
    private let captureSettings: CaptureSettingsStore?
    private let recordingSettings: RecordingSettingsStore?

    private static let pageWidth: CGFloat = 560
    /// 「网站」这个名字看起来像站点管理，看不出是在配输入法
    static let siteRulesTitle = "网页输入法"

    private var window: NSWindow?
    private var pageHost: NSView?
    private var pages: [SettingsPage] = []
    private var currentPage = 0
    private var generalPage: GeneralSettingsPage?
    private var inputSourcePage: InputSourceSettingsPage?
    private var siteRulesPage: SiteRulesSettingsPage?
    private var translatePage: TranslateSettingsPage?
    private var ocrPage: OCRSettingsPage?
    private var hotkeyPage: HotkeySettingsPage?
    private var historyPage: HistorySettingsPage?
    private var rulerPage: RulerSettingsPage?

    public init(loginItem: LoginItem,
                inputSource: InputSourceService?,
                smoothScroll: ScrollSmoother?,
                clipboard: ClipboardStore? = nil,
                rulerSettings: RulerSettingsStore? = nil,
                captureSettings: CaptureSettingsStore? = nil,
                recordingSettings: RecordingSettingsStore? = nil) {
        self.loginItem = loginItem
        self.inputSource = inputSource
        self.smoothScroll = smoothScroll
        self.clipboard = clipboard
        self.rulerSettings = rulerSettings
        self.captureSettings = captureSettings
        self.recordingSettings = recordingSettings
        super.init()
    }

    public func show(tab index: Int = 0) {
        let window = self.window ?? buildWindow()
        self.window = window
        reload()
        selectPage(index, animated: false)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reload() {
        generalPage?.reload(loginEnabled: loginItem.status.enabled,
                            smoothEnabled: smoothScroll?.isEnabled ?? false)
        inputSourcePage?.reload()
        siteRulesPage?.reload()
        translatePage?.reload()
        ocrPage?.reload()
        hotkeyPage?.reload()
        historyPage?.reload()
        rulerPage?.reload()
    }

    // MARK: - 搭建

    private func buildWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.pageWidth, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Baton 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        // 工具条紧贴标题栏、图标在上文字在下，和系统设置一个样子
        window.toolbarStyle = .preference

        let general = GeneralSettingsPage()
        general.onLoginToggle = { [weak self] enabled in
            self?.applyLogin(enabled)
        }
        general.onSmoothScrollToggle = { [weak self] enabled in
            self?.smoothScroll?.setEnabled(enabled)
            self?.onChange?()
        }
        general.smoothSettings = { [weak self] in
            self?.smoothScroll?.settings ?? SmoothScrollSettings()
        }
        general.onSmoothTuning = { [weak self] distance, duration in
            self?.smoothScroll?.apply { settings in
                settings.pointsPerLine = distance
                settings.duration = duration
            }
        }
        general.onForceMouseChange = { [weak self] enabled in
            self?.smoothScroll?.apply { $0.forceMouse = enabled }
            self?.onChange?()
        }
        general.smoothDiagnostics = { [weak self] in
            self?.smoothScroll?.lastDecision
        }
        general.delaySeconds = { [weak self] in
            self?.captureSettings?.settings.timedSeconds ?? 5
        }
        general.onDelayChange = { [weak self] seconds in
            self?.captureSettings?.setTimedSeconds(seconds)
        }
        general.capturesAudio = { [weak self] in
            self?.recordingSettings?.capturesAudio ?? true
        }
        general.onAudioToggle = { [weak self] enabled in
            self?.recordingSettings?.setCapturesAudio(enabled)
        }
        general.capturesMicrophone = { [weak self] in
            self?.recordingSettings?.capturesMicrophone ?? false
        }
        general.onMicrophoneToggle = { [weak self] enabled in
            self?.recordingSettings?.setCapturesMicrophone(enabled)
            // 一打开就弹授权框，别等用户按下录制才发现没权限
            if enabled { Task { _ = await MicrophoneCapture.requestAccess() } }
        }
        generalPage = general

        let inputPage = InputSourceSettingsPage(service: inputSource)
        inputPage.onChange = { [weak self] in self?.onChange?() }
        inputPage.onOpenSiteRules = { [weak self] in self?.selectPage(titled: Self.siteRulesTitle) }
        inputSourcePage = inputPage

        let sitePage = SiteRulesSettingsPage(service: inputSource)
        sitePage.onChange = { [weak self] in self?.onChange?() }
        siteRulesPage = sitePage

        let translate = TranslateSettingsPage()
        translate.onSave = { [weak self] in self?.onChange?() }
        translatePage = translate

        let ocr = OCRSettingsPage()
        ocr.onSave = { [weak self] in self?.onChange?() }
        ocrPage = ocr

        let hotkey = HotkeySettingsPage()
        hotkey.onChange = { [weak self] in self?.onChange?() }
        hotkeyPage = hotkey

        let history = HistorySettingsPage(store: clipboard)
        history.onChange = { [weak self] in self?.onChange?() }
        historyPage = history

        // 高度按各页内容给：页面内部是从顶往下排，多出来的空间落在底部，所以给宽一点也不会错位
        var entries: [(title: String, symbol: String, view: NSView, height: CGFloat)] = [
            ("通用", "gearshape", general, 560),
            ("输入法", "keyboard", inputPage, 660),
            (Self.siteRulesTitle, "network", sitePage, 470),
            ("翻译", "character.book.closed", translate, 470),
            ("OCR", "text.viewfinder", ocr, 360),
            ("热键", "command", hotkey, 640),
            ("历史", "clock.arrow.circlepath", history, 420),
        ]
        if let rulerSettings {
            let ruler = RulerSettingsPage(store: rulerSettings)
            ruler.onChange = { [weak self] in self?.onChange?() }
            rulerPage = ruler
            // 插在「网页输入法」之后而不是「输入法」之后：这两页是一件事的两个层次，
            // 中间夹一个「测量」会让它们看着像不相干的两个功能
            entries.insert(("测量", "ruler", ruler, 400), at: 3)
        }

        pages = entries.map { entry in
            SettingsPage(identifier: NSToolbarItem.Identifier("page.\(entry.title)"),
                         title: entry.title,
                         symbol: entry.symbol,
                         view: entry.view,
                         height: measuredHeight(of: entry.view, fallback: entry.height))
        }

        let host = NSView()
        window.contentView = host
        pageHost = host

        let toolbar = NSToolbar(identifier: "BatonSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        selectPage(0, animated: false)
        return window
    }

    // MARK: - 切页

    /// 量一页自然需要多高：临时塞进一个 560 宽的容器里排一遍，取 `fittingSize`。
    /// 量不出来（页面里是滚动视图，高度靠外部决定）就退回调用方给的经验值。
    private func measuredHeight(of page: NSView, fallback: CGFloat) -> CGFloat {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Self.pageWidth, height: fallback))
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            page.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        let measured = page.fittingSize.height
        page.removeFromSuperview()
        guard measured > 160 else { return fallback }
        // 780 而不是 700：输入法页偶尔会多出一块「失效的输入法」提示，
        // 上限压太低会把正常行的说明文字挤没
        return min(measured.rounded(.up), 780)
    }

    /// 按标题切页。页签顺序会因为「测量」这类可选页而变，用下标跳容易指错。
    private func selectPage(titled title: String) {
        guard let index = pages.firstIndex(where: { $0.title == title }) else { return }
        selectPage(index)
    }

    private func selectPage(_ index: Int, animated: Bool = true) {        guard !pages.isEmpty, let host = pageHost else { return }
        let safe = min(max(index, 0), pages.count - 1)
        currentPage = safe
        let page = pages[safe]

        host.subviews.forEach { $0.removeFromSuperview() }
        page.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page.view)
        NSLayoutConstraint.activate([
            page.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            page.view.topAnchor.constraint(equalTo: host.topAnchor),
            page.view.heightAnchor.constraint(equalToConstant: page.height),
        ])

        window?.toolbar?.selectedItemIdentifier = page.identifier
        resizeWindow(to: page.height, animated: animated)
    }

    /// 换页时改高度但不挪顶边：窗口往下长/缩，标题栏位置不动，眼睛不用重新找。
    private func resizeWindow(to contentHeight: CGFloat, animated: Bool) {
        guard let window else { return }
        let current = window.frame
        let contentWidth = window.contentRect(forFrameRect: current).width
        let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0,
                                                             width: contentWidth,
                                                             height: contentHeight))
        guard abs(current.height - target.height) > 0.5 else { return }
        var frame = current
        frame.origin.y += current.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }

    // MARK: - NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        pages.map(\.identifier)
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        pages.map(\.identifier)
    }

    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        pages.map(\.identifier)
    }

    public func toolbar(_ toolbar: NSToolbar,
                        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = pages.first(where: { $0.identifier == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = page.title
        item.paletteLabel = page.title
        item.toolTip = page.title
        item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
        item.target = self
        item.action = #selector(toolbarPageClicked(_:))
        return item
    }

    @objc private func toolbarPageClicked(_ sender: NSToolbarItem) {
        guard let index = pages.firstIndex(where: { $0.identifier == sender.itemIdentifier }) else { return }
        selectPage(index)
    }

    private func applyLogin(_ enabled: Bool) {
        do {
            _ = try loginItem.setEnabled(enabled)
        } catch {
            ModalAlert.notify(title: "无法修改登录项", message: error.localizedDescription,
                              name: "login.set", above: window)
        }
        generalPage?.reload(loginEnabled: loginItem.status.enabled,
                            smoothEnabled: smoothScroll?.isEnabled ?? false)
        onChange?()
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        generalPage?.reload(loginEnabled: loginItem.status.enabled,
                            smoothEnabled: smoothScroll?.isEnabled ?? false)
        onClose?()
    }
}

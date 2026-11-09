import AppKit

/// 一页设置。页面内部都是从顶往下排一列，所以 `height` 只影响窗口高度，多出的空间留在底部。
private struct SettingsPage {
    let identifier: NSToolbarItem.Identifier
    let title: String
    let symbol: String
    let view: NSView
    var height: CGFloat
    /// 悬停提示：页签为了排得开只能取短名，全称放这里
    var tip: String?
}

/// 偏好设置窗口。页签：通用、滚动、截图、录制、输入法、网页输入法、测量、翻译、OCR、热键、历史（测量可选）。
///
/// 一页只对应一个功能模块：「通用」只留登录项和权限，滚动/截图/录制各占一页。
/// 以前这些全堆在「通用」里，改个截图倒计时得先猜它归在哪一类。
///
/// 顶部用 `NSToolbar`（`.preference` 样式）切页，而不是 `NSTabView` 的方框标签——
/// 后者是 10.10 时代的外观，在一堆原生设置窗口旁边看着像另一个年代的东西。
/// 窗口高度跟着当前页走，切页时保持顶边不动。
@MainActor
public final class PreferencesWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    public var onChange: (() -> Void)?
    /// 窗口关闭时回调，调用方据此把激活策略退回 accessory。
    public var onClose: (() -> Void)?
    /// 通用页的「导出配置…」：面板和落盘都由 AppShell 做
    public var onExportConfig: (() -> Void)?
    /// 通用页的「导入配置…」
    public var onImportConfig: (() -> Void)?

    private let loginItem: LoginItem
    private weak var inputSource: InputSourceService?
    private weak var smoothScroll: ScrollSmoother?
    private weak var clipboard: ClipboardStore?
    private let rulerSettings: RulerSettingsStore?
    private let captureSettings: CaptureSettingsStore?
    private let recordingSettings: RecordingSettingsStore?

    /// 11 个页签在 560 宽下会被折进「»」溢出菜单，加宽到 680 才排得开
    private static let pageWidth: CGFloat = 680
    /// 页签名为了排得开只能取短名，悬停时把话说全。
    private static let tips: [String: String] = [
        scrollTitle: "鼠标滚轮的平滑滚动，触控板保持系统手感",
        clipboardTitle: "剪贴板历史：⇧⌘V 打开，这里管条数与容量",
    ]

    /// 「网站」这个名字看起来像站点管理，看不出是在配输入法
    static let siteRulesTitle = "网页输入法"
    static let inputSourceTitle = "输入法"
    /// 「滚动」单看会被读成滚动截图；带上「平滑」才明确指的是鼠标滚轮的手感
    static let scrollTitle = "平滑滚动"
    /// 「历史」没有主语，看不出是剪贴板；「剪贴板历史」五个字又和「网页输入法」一样宽，
    /// 页签上取「剪贴板」，全称放进悬停提示
    static let clipboardTitle = "剪贴板"

    private var window: NSWindow?
    private var pageHost: NSView?
    private var pages: [SettingsPage] = []
    private var currentPage = 0
    private var generalPage: GeneralSettingsPage?
    private var scrollPage: ScrollSettingsPage?
    private var capturePage: CaptureSettingsPage?
    private var recordingPage: RecordingSettingsPage?
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

    /// 按标题开页：页签下标会随页面增减而变，从外面跳页用标题才不会指错。
    public func show(titled title: String) {
        let window = self.window ?? buildWindow()
        self.window = window
        reload()
        selectPage(titled: title)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 导入配置后各页控件的值都变了，从外面触发一次重读。
    public func refresh() { reload() }

    /// 弹确认框时挂在这上面，别让提示框跑到上一个 App 的窗口上去。
    public var hostWindow: NSWindow? { window }

    private func reload() {
        generalPage?.reload(loginEnabled: loginItem.status.enabled)
        scrollPage?.reload(enabled: smoothScroll?.isEnabled ?? false)
        capturePage?.reload()
        recordingPage?.reload()
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
        // 文件面板与确认框在 AppShell 里弹：窗口层只管「用户点了这个按钮」
        general.onExportConfig = { [weak self] in self?.onExportConfig?() }
        general.onImportConfig = { [weak self] in self?.onImportConfig?() }
        generalPage = general

        let scroll = ScrollSettingsPage()
        scroll.onToggle = { [weak self] enabled in
            self?.smoothScroll?.setEnabled(enabled)
            self?.onChange?()
        }
        scroll.settings = { [weak self] in
            self?.smoothScroll?.settings ?? SmoothScrollSettings()
        }
        scroll.onTuning = { [weak self] distance, duration in
            self?.smoothScroll?.apply { settings in
                settings.pointsPerLine = distance
                settings.duration = duration
            }
        }
        scroll.onForceMouseChange = { [weak self] enabled in
            self?.smoothScroll?.apply { $0.forceMouse = enabled }
            self?.onChange?()
        }
        scroll.diagnostics = { [weak self] in
            self?.smoothScroll?.lastDecision
        }
        scrollPage = scroll

        let capture = CaptureSettingsPage()
        capture.delaySeconds = { [weak self] in
            self?.captureSettings?.settings.timedSeconds ?? 5
        }
        capture.onDelayChange = { [weak self] seconds in
            self?.captureSettings?.setTimedSeconds(seconds)
        }
        capturePage = capture

        let recording = RecordingSettingsPage()
        recording.capturesAudio = { [weak self] in
            self?.recordingSettings?.capturesAudio ?? true
        }
        recording.onAudioToggle = { [weak self] enabled in
            self?.recordingSettings?.setCapturesAudio(enabled)
        }
        recording.capturesMicrophone = { [weak self] in
            self?.recordingSettings?.capturesMicrophone ?? false
        }
        recording.onMicrophoneToggle = { [weak self] enabled in
            self?.recordingSettings?.setCapturesMicrophone(enabled)
            // 一打开就弹授权框，别等用户按下录制才发现没权限
            if enabled { Task { _ = await MicrophoneCapture.requestAccess() } }
        }
        recordingPage = recording

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
            ("通用", "gearshape", general, 300),
            (Self.scrollTitle, "scroll", scroll, 260),
            ("截图", "camera.viewfinder", capture, 260),
            ("录制", "record.circle", recording, 220),
            (Self.inputSourceTitle, "keyboard", inputPage, 660),
            (Self.siteRulesTitle, "network", sitePage, 470),
            ("翻译", "character.book.closed", translate, 470),
            ("OCR", "text.viewfinder", ocr, 360),
            ("热键", "command", hotkey, 640),
            (Self.clipboardTitle, "clock.arrow.circlepath", history, 420),
        ]
        if let rulerSettings {
            let ruler = RulerSettingsPage(store: rulerSettings)
            ruler.onChange = { [weak self] in self?.onChange?() }
            rulerPage = ruler
            // 紧跟「截图」：量尺寸和框选是连着用的两个动作。
            // 用标题找位置而不是写死下标，前面加页时不用再回来改数字
            let after = entries.firstIndex { $0.title == "截图" } ?? entries.count - 1
            entries.insert(("测量", "ruler", ruler, 400), at: after + 1)
        }

        pages = entries.map { entry in
            SettingsPage(identifier: NSToolbarItem.Identifier("page.\(entry.title)"),
                         title: entry.title,
                         symbol: entry.symbol,
                         view: entry.view,
                         height: measuredHeight(of: entry.view, fallback: entry.height),
                         tip: Self.tips[entry.title])
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
        // 量不出来（页面里是滚动视图，高度靠外部决定）就退回调用方给的经验值
        let natural = measured > 160 ? measured : fallback
        // 下限 260：截图页只有一行，按实测给会把窗口缩成一条，切页时上下乱跳
        // 上限 780：输入法页偶尔会多出一块「失效的输入法」提示，压太低会挤掉说明文字
        return min(max(natural.rounded(.up), 260), 780)
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
        item.toolTip = page.tip ?? page.title
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
        generalPage?.reload(loginEnabled: loginItem.status.enabled)
        onChange?()
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        generalPage?.reload(loginEnabled: loginItem.status.enabled)
        onClose?()
    }
}

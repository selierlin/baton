import AppKit

/// 一页设置。页面内部都是从顶往下排一列，所以 `height` 只影响窗口高度，多出的空间留在底部。
private struct SettingsPage {
    let identifier: NSToolbarItem.Identifier
    let title: String
    let symbol: String
    let view: NSView
    var height: CGFloat
}

/// 偏好设置窗口。六页：通用、测量、翻译、OCR、热键、历史。
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

    private var window: NSWindow?
    private var pageHost: NSView?
    private var pages: [SettingsPage] = []
    private var currentPage = 0
    private var generalPage: GeneralSettingsPage?
    private var inputSourcePage: InputSourceSettingsPage?
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
        inputSourcePage = inputPage

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
            ("翻译", "character.book.closed", translate, 470),
            ("OCR", "text.viewfinder", ocr, 360),
            ("热键", "command", hotkey, 640),
            ("历史", "clock.arrow.circlepath", history, 420),
        ]
        if let rulerSettings {
            let ruler = RulerSettingsPage(store: rulerSettings)
            ruler.onChange = { [weak self] in self?.onChange?() }
            rulerPage = ruler
            entries.insert(("测量", "ruler", ruler, 400), at: 2)
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
        return min(measured.rounded(.up), 700)
    }

    private func selectPage(_ index: Int, animated: Bool = true) {
        guard !pages.isEmpty, let host = pageHost else { return }
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

// MARK: - 通用

@MainActor
private final class GeneralSettingsPage: NSView {
    var onLoginToggle: ((Bool) -> Void)?
    var onSmoothScrollToggle: ((Bool) -> Void)?
    /// 拖动滑杆时回写「每行多少点 / 平滑时长」
    var onSmoothTuning: ((Double, Double) -> Void)?
    /// 「我的鼠标没被识别」兜底开关
    var onForceMouseChange: ((Bool) -> Void)?
    /// 读当前值，用于页面刷新
    var smoothSettings: (() -> SmoothScrollSettings)?
    /// 最近一次滚动事件的处理结论，用于现场诊断
    var smoothDiagnostics: (() -> String?)?
    /// 延迟截图的默认秒数（1–60）
    var delaySeconds: (() -> Int)?
    var onDelayChange: ((Int) -> Void)?
    /// 录制时是否带系统声音
    var capturesAudio: (() -> Bool)?
    var onAudioToggle: ((Bool) -> Void)?
    /// 录制时是否带麦克风旁白
    var capturesMicrophone: (() -> Bool)?
    var onMicrophoneToggle: ((Bool) -> Void)?

    private let delayPopup = NSPopUpButton()
    private let loginSwitch = NSSwitch()
    private let smoothSwitch = NSSwitch()
    private let audioSwitch = NSSwitch()
    private let microphoneSwitch = NSSwitch()
    private let forceMouseCheck = NSButton(checkboxWithTitle: "我的鼠标没被识别（强制平滑）", target: nil, action: nil)
    private let distanceSlider = NSSlider()
    private let durationSlider = NSSlider()
    private let distanceValue = NSTextField(labelWithString: "")
    private let durationValue = NSTextField(labelWithString: "")
    private let diagnosticLabel = NSTextField(labelWithString: "（滚一下滚轮，这里会显示判定结果）")
    private var diagnosticTimer: Timer?
    private var permissionLabels: [PermissionKind: NSTextField] = [:]
    private var permissionButtons: [PermissionKind: NSButton] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        // 延迟截图的秒数：常用档位列出来就行，没必要让用户拖一根 1–60 的滑杆
        delayPopup.addItems(withTitles: ["3 秒", "5 秒", "10 秒", "15 秒"])
        delayPopup.target = self
        delayPopup.action = #selector(delayChanged)
        delayPopup.font = .systemFont(ofSize: 12)
        delayPopup.translatesAutoresizingMaskIntoConstraints = false
        delayPopup.widthAnchor.constraint(equalToConstant: 90).isActive = true

        for control in [loginSwitch, smoothSwitch, audioSwitch, microphoneSwitch] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 38).isActive = true
        }

        // 两颗滑杆：距离决定一格滚多远，时长决定尾巴多长
        for slider in [distanceSlider, durationSlider] {
            slider.controlSize = .small
            slider.isContinuous = true
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
            slider.target = self
            slider.action = #selector(smoothTuned)
        }
        distanceSlider.minValue = 20
        distanceSlider.maxValue = 80
        durationSlider.minValue = 0.10
        durationSlider.maxValue = 0.60
        for label in [distanceValue, durationValue] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }

        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged)
        smoothSwitch.target = self
        smoothSwitch.action = #selector(smoothChanged)
        audioSwitch.target = self
        audioSwitch.action = #selector(audioChanged)
        microphoneSwitch.target = self
        microphoneSwitch.action = #selector(microphoneChanged)

        forceMouseCheck.target = self
        forceMouseCheck.action = #selector(forceMouseChanged)
        forceMouseCheck.font = .systemFont(ofSize: 11)
        forceMouseCheck.translatesAutoresizingMaskIntoConstraints = false

        // 「滚一下看看」的现场诊断：不带这个，用户只能说「没效果」，没法定位是哪一环断的
        diagnosticLabel.font = .systemFont(ofSize: 11)
        diagnosticLabel.textColor = .secondaryLabelColor
        diagnosticLabel.lineBreakMode = .byTruncatingTail
        diagnosticLabel.translatesAutoresizingMaskIntoConstraints = false

        // 权限：状态 + 去授权
        var permissionRows: [NSView] = []
        for kind in PermissionKind.allCases {
            let status = NSTextField(labelWithString: "—")
            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor
            status.alignment = .right
            status.maximumNumberOfLines = 1
            status.lineBreakMode = .byClipping
            status.translatesAutoresizingMaskIntoConstraints = false
            status.widthAnchor.constraint(equalToConstant: 56).isActive = true
            permissionLabels[kind] = status

            let button = NSButton(title: "去授权", target: self, action: #selector(requestPermission(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = PermissionKind.allCases.firstIndex(of: kind) ?? 0

            let trailing = NSStackView(views: [status, button])
            trailing.orientation = .horizontal
            trailing.spacing = 10
            trailing.alignment = .centerY
            permissionButtons[kind] = button
            permissionRows.append(SettingsLayout.row(kind.title, control: trailing))
        }

        // 分组：常驻开关 / 滚动细节 / 截图 / 录制 / 权限。
        // 原来二十多个控件平铺成一列，找一项得从头扫到尾；分组之后每块只回答一个问题。
        SettingsLayout.install([
            SettingsLayout.section("常规", [
                SettingsLayout.row("登录时启动", control: loginSwitch),
            ]),
            SettingsLayout.section("滚动", [
                SettingsLayout.row("平滑滚动", detail: "只接管滚轮，触控板保持系统手感",
                                   control: smoothSwitch),
                SettingsLayout.row("每行滚动", control: row(distanceSlider, distanceValue)),
                SettingsLayout.row("平滑时长", control: row(durationSlider, durationValue)),
                SettingsLayout.plain(forceMouseCheck),
                SettingsLayout.plain(diagnosticLabel),
            ]),
            SettingsLayout.section("截图", [
                SettingsLayout.row("延迟截图", detail: "按下热键后先等这么久，再出现框选",
                                   control: delayPopup),
            ]),
            SettingsLayout.section("录制", [
                SettingsLayout.row("录制系统声音", detail: "录下 App 播放的声音（不含麦克风）",
                                   control: audioSwitch),
                SettingsLayout.row("录制麦克风旁白", detail: "第一次打开会请求麦克风权限",
                                   control: microphoneSwitch),
            ]),
            SettingsLayout.section("权限", permissionRows),
        ], in: self)
    }

    func reload(loginEnabled: Bool, smoothEnabled: Bool) {
        loginSwitch.state = loginEnabled ? .on : .off
        smoothSwitch.state = smoothEnabled ? .on : .off
        if let settings = smoothSettings?() {
            distanceSlider.doubleValue = settings.pointsPerLine
            durationSlider.doubleValue = settings.duration
            forceMouseCheck.state = settings.forceMouse ? .on : .off
        }
        selectDelay(delaySeconds?() ?? 5)
        audioSwitch.state = (capturesAudio?() ?? true) ? .on : .off
        microphoneSwitch.state = (capturesMicrophone?() ?? false) ? .on : .off
        updateTuning()
        refreshDiagnostics()
        for (kind, label) in permissionLabels {
            let granted = PermissionCenter.status(kind) == .granted
            label.stringValue = granted ? "已授权" : "未授权"
            label.textColor = granted ? .secondaryLabelColor : .systemOrange
            permissionButtons[kind]?.isHidden = granted
        }
    }

    /// 页面在窗口里时才轮询诊断文本，窗口一关就停，不留后台定时器。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
        guard window != nil else { return }
        diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDiagnostics() }
        }
    }

    private func refreshDiagnostics() {
        let text = smoothDiagnostics?() ?? nil
        diagnosticLabel.stringValue = text ?? "（滚一下滚轮，这里会显示判定结果）"
        diagnosticLabel.textColor = (text?.hasPrefix("已接管") ?? false) ? .secondaryLabelColor : .systemOrange
    }

    @objc private func smoothTuned() {
        updateTuning()
        onSmoothTuning?(distanceSlider.doubleValue, durationSlider.doubleValue)
    }

    private func updateTuning() {
        distanceValue.stringValue = String(format: "%.0f 点/行", distanceSlider.doubleValue)
        durationValue.stringValue = String(format: "%.2f 秒", durationSlider.doubleValue)
        let enabled = smoothSwitch.state == .on
        distanceSlider.isEnabled = enabled
        durationSlider.isEnabled = enabled
        forceMouseCheck.isEnabled = enabled
    }

    private static let delayChoices = [3, 5, 10, 15]

    private func selectDelay(_ seconds: Int) {
        if let index = Self.delayChoices.firstIndex(of: seconds) {
            delayPopup.selectItem(at: index)
        } else {
            delayPopup.selectItem(at: 1)
        }
    }

    @objc private func delayChanged() {
        let index = delayPopup.indexOfSelectedItem
        guard index >= 0, index < Self.delayChoices.count else { return }
        onDelayChange?(Self.delayChoices[index])
    }

    @objc private func audioChanged() {
        ActionLog.action("setting.audio", "on=\(audioSwitch.state == .on)")
        onAudioToggle?(audioSwitch.state == .on)
    }

    @objc private func microphoneChanged() {
        ActionLog.action("setting.microphone", "on=\(microphoneSwitch.state == .on)")
        onMicrophoneToggle?(microphoneSwitch.state == .on)
    }

    @objc private func loginChanged() { onLoginToggle?(loginSwitch.state == .on) }
    @objc private func smoothChanged() {
        updateTuning()
        onSmoothScrollToggle?(smoothSwitch.state == .on)
    }

    @objc private func forceMouseChanged() {
        onForceMouseChange?(forceMouseCheck.state == .on)
    }

    @objc private func requestPermission(_ sender: NSButton) {
        let kinds = PermissionKind.allCases
        guard sender.tag >= 0, sender.tag < kinds.count else { return }
        PermissionCenter.request(kinds[sender.tag])
        reload(loginEnabled: loginSwitch.state == .on,
               smoothEnabled: smoothSwitch.state == .on)
    }
}

// MARK: - 翻译

@MainActor
private final class TranslateSettingsPage: NSView {
    var onSave: (() -> Void)?

    private let providerPopup = NSPopUpButton()
    private let modelField = NSTextField()
    private let baseURLField = NSTextField()
    private let keyField = NSSecureTextField()
    /// 百度翻译没有接口地址，这一行的标题会变成 App ID
    private var endpointRow: SettingsRowView?
    private let targetPopup = NSPopUpButton()
    private let sourcePopup = NSPopUpButton()
    private let silentSwitch = NSSwitch()
    private let statusLabel = NSTextField(labelWithString: "")

    private let store = try? TranslateSettingsStore()
    private var settings: TranslateSettings = .default

    /// 百度翻译不用 baseURL，接口地址那一栏改成 App ID。
    private var selectedKind: ProviderConfig.Kind {
        let id = providerPopup.selectedItem?.representedObject as? String
        return settings.providers.first { $0.id == id }?.kind ?? .openAICompatible
    }

    /// 目标语言：BCP-47 + 中文名。源语言多一个「自动」。
    private static let languages: [(String, String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁体中文"),
        ("en", "英语"),
        ("ja", "日语"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        targetPopup.addItems(withTitles: Self.languages.map(\.1))
        sourcePopup.addItem(withTitle: "自动检测")
        sourcePopup.addItems(withTitles: Self.languages.map(\.1))

        for field in [modelField, baseURLField, keyField] {
            field.font = .systemFont(ofSize: 12)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        for popup in [providerPopup, targetPopup, sourcePopup] {
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        silentSwitch.translatesAutoresizingMaskIntoConstraints = false
        silentSwitch.widthAnchor.constraint(equalToConstant: 38).isActive = true
        keyField.placeholderString = "留空则不修改已保存的密钥"

        let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let footer = NSStackView(views: [save, statusLabel])
        footer.orientation = .horizontal
        footer.spacing = 12

        let endpoint = SettingsLayout.row("接口地址", control: baseURLField)
        endpointRow = endpoint
        let model = SettingsLayout.row("模型", control: modelField)
        SettingsLayout.install([
            SettingsLayout.section("服务商", [
                SettingsLayout.row("服务商", control: providerPopup),
                endpoint,
                model,
                SettingsLayout.row("API Key", detail: "留空则不修改已保存的密钥", control: keyField),
            ]),
            SettingsLayout.section("语言", [
                SettingsLayout.row("目标语言", control: targetPopup),
                SettingsLayout.row("源语言", control: sourcePopup),
                SettingsLayout.row("静默模式", detail: "翻完不弹原文，只把结果放进剪贴板",
                                   control: silentSwitch),
            ]),
            SettingsLayout.plain(footer),
        ], in: self)
    }

    func reload() {
        settings = store?.load() ?? .default
        providerPopup.removeAllItems()

        // 预设在前，用户自建的（id 不在预设里）追加在后面
        var entries: [(String, String)] = ProviderPreset.all.map { ($0.id, $0.displayName) }
        for provider in settings.providers where !entries.contains(where: { $0.0 == provider.id }) {
            entries.append((provider.id, provider.displayName))
        }
        for (id, name) in entries {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.representedObject = id
            providerPopup.menu?.addItem(item)
        }

        let activeID = settings.activeID
        if let index = entries.firstIndex(where: { $0.0 == activeID }) {
            providerPopup.selectItem(at: index)
        } else {
            providerPopup.selectItem(at: 0)
        }

        fillFields(for: providerPopup.selectedItem?.representedObject as? String)
        targetPopup.selectItem(at: Self.languages.firstIndex { $0.0 == settings.targetLanguage } ?? 0)
        if let source = settings.sourceLanguage,
           let index = Self.languages.firstIndex(where: { $0.0 == source }) {
            sourcePopup.selectItem(at: index + 1)
        } else {
            sourcePopup.selectItem(at: 0)
        }
        silentSwitch.state = settings.silentMode ? .on : .off
        statusLabel.stringValue = ""
    }

    private func fillFields(for id: String?) {
        guard let id else { return }
        if let existing = settings.providers.first(where: { $0.id == id }) {
            let isBaidu = existing.kind == .baiduTranslate
            endpointRow?.title = isBaidu ? "App ID" : "接口地址"
            // 百度翻译没有模型参数：置灰保留，比整行消失更不容易让人以为漏了配置
            modelField.placeholderString = isBaidu ? "百度翻译不用填" : ""
            modelField.isEnabled = !isBaidu
            modelField.stringValue = existing.model
            baseURLField.stringValue = isBaidu
                ? (existing.appID ?? "")
                : (existing.baseURL?.absoluteString ?? "")
            keyField.stringValue = ""
            // 不主动读 Keychain：查询会弹钥匙串授权框，而这里只需要一个提示
            keyField.placeholderString = "留空则不修改"
            return
        }
        guard let preset = ProviderPreset.all.first(where: { $0.id == id }) else { return }
        endpointRow?.title = "接口地址"
        modelField.placeholderString = ""
        modelField.isEnabled = true
        modelField.stringValue = preset.model
        baseURLField.stringValue = preset.baseURL
        keyField.stringValue = ""
        keyField.placeholderString = "留空则不修改"
    }

    @objc private func providerChanged() {
        fillFields(for: providerPopup.selectedItem?.representedObject as? String)
    }

    @objc private func saveTapped() {
        guard let id = providerPopup.selectedItem?.representedObject as? String else { return }
        let name = providerPopup.titleOfSelectedItem ?? id
        let isBaidu = selectedKind == .baiduTranslate
        let rawEndpoint = baseURLField.stringValue.trimmingCharacters(in: .whitespaces)

        let config: ProviderConfig
        if isBaidu {
            guard !rawEndpoint.isEmpty else {
                statusLabel.stringValue = "请先填 App ID"
                return
            }
            config = ProviderConfig(id: id,
                                    displayName: name,
                                    kind: .baiduTranslate,
                                    model: "",
                                    apiKeyRef: "provider.\(id)",
                                    appID: rawEndpoint)
        } else {
            guard let host = URL(string: rawEndpoint) else {
                statusLabel.stringValue = "接口地址不是合法 URL"
                return
            }
            config = ProviderConfig(id: id,
                                    displayName: name,
                                    baseURL: host,
                                    model: modelField.stringValue,
                                    apiKeyRef: "provider.\(id)")
        }

        var providers = settings.providers.filter { $0.id != id }
        providers.append(config)
        settings.providers = providers
        settings.activeID = id
        settings.targetLanguage = Self.languages[targetPopup.indexOfSelectedItem].0
        settings.sourceLanguage = sourcePopup.indexOfSelectedItem > 0
            ? Self.languages[sourcePopup.indexOfSelectedItem - 1].0
            : nil
        settings.silentMode = silentSwitch.state == .on

        do {
            try store?.save(settings)
            let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                try KeychainStore.save(key, account: config.apiKeyRef)
                keyField.stringValue = ""
            }
            statusLabel.stringValue = "已保存"
            onSave?()
            reload()
            statusLabel.stringValue = "已保存"
        } catch {
            statusLabel.stringValue = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - OCR

@MainActor
private final class OCRSettingsPage: NSView {
    var onSave: (() -> Void)?

    private let enginePopup = NSPopUpButton()
    private let akField = NSTextField()
    private let skField = NSSecureTextField()
    private let variantPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")

    private let store = try? OCRSettingsStore()
    private var settings: OCRSettings = .default

    private static let engines: [(String, String)] = [
        ("vision", "本机 Vision（免费、离线）"),
        ("baidu", "百度 OCR（需要密钥）"),
    ]
    private static let variants: [(String, String)] = [
        ("general", "通用（速度快）"),
        ("accurate_basic", "高精度（无坐标）"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)

        akField.font = .systemFont(ofSize: 12)
        skField.font = .systemFont(ofSize: 12)
        for field in [akField, skField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        for popup in [enginePopup, variantPopup] {
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        skField.placeholderString = "留空则不修改已保存的密钥"
        variantPopup.addItems(withTitles: Self.variants.map(\.1))

        let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let grid = [
            SettingsLayout.row("识别引擎", detail: "本机 Vision 免费离线，够日常用",
                               control: enginePopup),
            SettingsLayout.row("App ID", control: akField),
            SettingsLayout.row("密钥", control: skField),
            SettingsLayout.row("接口变体", detail: "高精度模式不返回文字坐标",
                               control: variantPopup),
        ]

        let footer = NSStackView(views: [save, statusLabel])
        footer.orientation = .horizontal
        footer.spacing = 12

        SettingsLayout.install([
            SettingsLayout.section("识别服务", grid),
            SettingsLayout.plain(footer),
        ], in: self)
    }

    func reload() {
        settings = store?.load() ?? .default
        enginePopup.removeAllItems()
        for (id, title) in Self.engines {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = id
            enginePopup.menu?.addItem(item)
        }

        let activeID = settings.activeID
        enginePopup.selectItem(at: Self.engines.firstIndex { $0.0 == activeID } ?? 0)
        variantPopup.selectItem(at: Self.variants.firstIndex {
            $0.0 == (settings.active?.variant ?? "general")
        } ?? 0)

        akField.stringValue = ""
        akField.placeholderString = "留空则不修改"
        skField.stringValue = ""
        statusLabel.stringValue = ""
        updateEnabled()
    }

    private func updateEnabled() {
        let isBaidu = (enginePopup.selectedItem?.representedObject as? String) == "baidu"
        akField.isEnabled = isBaidu
        skField.isEnabled = isBaidu
        variantPopup.isEnabled = isBaidu
    }

    @objc private func engineChanged() { updateEnabled() }

    @objc private func saveTapped() {
        let id = (enginePopup.selectedItem?.representedObject as? String) ?? "vision"

        if id == "vision" {
            settings = OCRSettings(providers: [.vision], activeID: "vision")
        } else {
            let ak = akField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let sk = skField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                if !ak.isEmpty {
                    try KeychainStore.save(ak, account: BaiduOCRCredentials.accessKeyAccount)
                }
                if !sk.isEmpty {
                    try KeychainStore.save(sk, account: BaiduOCRCredentials.secretKeyAccount)
                }
            } catch {
                statusLabel.stringValue = "密钥写入失败：\(error.localizedDescription)"
                return
            }
            var baidu = OCRProviderConfig.baidu
            baidu.variant = Self.variants[variantPopup.indexOfSelectedItem].0
            settings = OCRSettings(providers: [.vision, baidu], activeID: "baidu")
        }

        do {
            try store?.save(settings)
            statusLabel.stringValue = "已保存"
            onSave?()
        } catch {
            statusLabel.stringValue = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 小工具

private func row(_ views: NSView...) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.spacing = 8
    return stack
}

private extension PermissionKind {
    var title: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .screenRecording: return "屏幕录制"
        case .listenEvent: return "输入监控"
        }
    }
}

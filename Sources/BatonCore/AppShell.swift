import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ImageIO
import UniformTypeIdentifiers
import os

/// P1 的 App 外壳：菜单栏、激活策略、登录项、overlay 残留检查。
/// P2 起接入事件总线与剪贴板历史。
@MainActor
public final class AppShell: NSObject {
    public let loginItem = LoginItem()
    public let activation = ActivationPolicyController.shared
    public let hub = EventHub()
    public private(set) var residue: OverlayRecovery.Residue?
    public private(set) var started = false
    /// 最近一次热键注册后的静态校验结果（重复 / 撞系统快捷键）
    public private(set) var hotkeyWarnings: [String] = []
    public private(set) var clipboard: ClipboardService?
    public private(set) var inputSource: InputSourceService?
    public private(set) var smoothScroll: ScrollSmoother?
    public private(set) var translator: TranslateCoordinator?
    public private(set) var annotator: AnnotateWindowController?
    public private(set) var inPlaceAnnotator: InPlaceAnnotator?
    public private(set) var preferences: PreferencesWindowController?
    private var ruler: RulerController?
    private let recorder = RecorderController()

    private let log = Logger(subsystem: "com.selier.baton", category: "shell")
    private let captureSettings = CaptureSettingsStore()
    private lazy var captureSession = CaptureSession(settings: captureSettings)
    /// 最近一次截图的成品：回溯时不重新抓屏，直接把那张图重新打开进标注。
    private var lastShot: (image: CGImage, scale: CGFloat)?
    /// 延迟截图的倒计时面板（同时只允许一个）
    private var countdown: CountdownHUD?
    private let hotkeys = HotkeyRegistry()
    private let hotkeyStore = try? HotkeySettingsStore()
    private var pinController = PinController()
    private let rulerSettings = RulerSettingsStore()
    private let recordingSettings = RecordingSettingsStore()
    private var pinStore: PinStore?
    private var statusItem: NSStatusItem?
    private var loginMenuItem: NSMenuItem?
    private var inputSourceMenuItem: NSMenuItem?
    private var smoothScrollMenuItem: NSMenuItem?
    private var stopRecordingMenuItem: NSMenuItem?
    /// 有全局热键的菜单项：改完热键要把右侧那一列跟着刷新
    private var hotkeyMenuItems: [HotkeyAction: NSMenuItem] = [:]
    /// 设置窗打开期间是否已经占着 regular 激活策略（防止重复计数）
    private var preferencesHoldingRegular = false
    private var annotatorHoldingRegular = false

    public override init() {
        super.init()
    }

    public func start() {
        guard !started else { return }
        started = true

        NSApp.setActivationPolicy(.accessory)

        ActionLog.app("launch", "screen=\(CGPreflightScreenCaptureAccess()) ax=\(AXIsProcessTrusted())")
        HangWatchdog.shared.start()

        // 上次异常退出留下的全屏窗会让用户无法操作，必须先报出来
        residue = OverlayRecovery.checkResidue()
        if let residue {
            log.error("检测到 overlay 残留：pid=\(residue.pid) alive=\(residue.alive)")
            ActionLog.fail("overlay.residue", "pid=\(residue.pid) alive=\(residue.alive)")
        }

        // 事件监听要最先起来：登录项查询会走 SMAppService，首次启动可能阻塞数秒，
        // 排在它后面会漏掉启动瞬间的复制。
        startSmoothScroll()
        hub.scrollInterceptor = makeScrollInterceptor()
        hub.start()
        startClipboard()
        startInputSource()
        translator = TranslateCoordinator()
        annotator = AnnotateWindowController(pinController: pinController)
        annotator?.onFinish = { [weak self] _ in
            guard let self, self.annotatorHoldingRegular else { return }
            self.annotatorHoldingRegular = false
            self.activation.leaveRegular()
        }

        // 原地标注：框选结束后覆盖层不撤，画布直接长在选区上
        let inPlace = InPlaceAnnotator(pinController: pinController)
        inPlace.onFinish = { [weak self] outcome in
            self?.log.info("原地标注结束：\(String(describing: outcome), privacy: .public)")
            ActionLog.result("annotate.finish", "\(outcome)")
        }
        // 工具条上的「长截图 / OCR」：从当前选区直接接着跑，不用重新框
        inPlace.onExternal = { [weak self] request in
            guard let self else { return }
            switch request {
            case .ocr(let image, let silent):
                Task { await self.translator?.recognize(image: image, silent: silent) }
            case .scroll(let result):
                Task { await self.runScroll(from: result) }
            }
        }
        inPlaceAnnotator = inPlace

        buildStatusItem()
        startHotkeys()
        wireRecorder()
        observeMenuActions()

        // 登录项状态查询放最后，且不阻塞启动
        Task { [weak self] in
            guard let self else { return }
            refreshLoginMenuItem()
            log.info("Baton 已启动；登录项状态 \(self.loginItem.status.detail, privacy: .public)")
            ActionLog.app("ready", "pins=\(pinController.count) clipboard=\(clipboard != nil)")
        }

        print("[Baton] started; menu bar item installed")
    }

    private func startClipboard() {
        do {
            let database = try BatonDatabase()
            let store = ClipboardStore(database: database)
            let service = ClipboardService(store: store, hub: hub)
            service.start()
            clipboard = service

            // 贴图与剪贴板共用同一条连接：贴图要往 item 表写图，恢复时再读回来
            let pins = PinStore(clipboard: store)
            pinStore = pins
            pinController = PinController(store: pins)
            pinController.restore()
            log.info("剪贴板历史已启用，恢复贴图 \(self.pinController.count) 张")
        } catch {
            log.error("剪贴板历史启动失败：\(String(describing: error), privacy: .public)")
        }
    }

    private func startInputSource() {
        do {
            let service = try InputSourceService(hub: hub)
            service.start()
            inputSource = service
        } catch {
            log.error("输入法记忆启动失败：\(String(describing: error), privacy: .public)")
        }
    }

    private func startSmoothScroll() {
        smoothScroll = ScrollSmoother(store: try? SmoothScrollStore())
    }

    /// 录制状态要反映到菜单栏（红点图标 + 「停止录制」可用性）。
    private func wireRecorder() {
        recorder.onStateChange = { [weak self] recording in
            self?.setRecordingIndicator(recording)
        }
        recorder.onFinish = { [weak self] url in
            self?.log.info("录制已保存：\(url.lastPathComponent, privacy: .public)")
        }
        recorder.onFailure = { [weak self] text in
            self?.presentAlert(title: "录制中断", message: text)
        }
    }

    private func setRecordingIndicator(_ recording: Bool) {
        stopRecordingMenuItem?.isEnabled = recording
        guard let button = statusItem?.button else { return }
        if recording {
            button.image = NSImage(systemSymbolName: "record.circle.fill",
                                   accessibilityDescription: "正在录制")
            button.contentTintColor = .systemRed
        } else {
            let image = NSImage(systemSymbolName: "command", accessibilityDescription: "Baton")
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = nil
        }
    }

    /// 关闭平滑时返回 nil，让 tap 保持 `listenOnly`——拦截型 tap 挂在输入链路上，
    /// 用不上就别占着。
    private func makeScrollInterceptor() -> (@MainActor (ScrollSample) -> Bool)? {
        guard let smoothScroll, smoothScroll.isEnabled else { return nil }
        return { [weak smoothScroll] sample in
            smoothScroll?.consume(sample) ?? false
        }
    }

    private func startHotkeys() {
        do {
            try hotkeys.install()
        } catch {
            log.error("热键处理器安装失败：\(String(describing: error), privacy: .public)")
            return
        }
        registerHotkeys()
    }

    /// 全部全局热键都从配置表来：改完热键要重注册，所以先注销再按当前配置装一遍。
    private func registerHotkeys() {
        hotkeys.unregisterAll()
        let settings = hotkeyStore?.load() ?? .default
        for action in HotkeyAction.allCases {
            let combo = settings.combo(for: action)
            do {
                try hotkeys.register(combo) { [weak self] in
                    self?.perform(action)
                }
            } catch HotkeyError.conflict {
                log.error("热键 \(action.rawValue, privacy: .public) 被别的 App 占用：\(combo.display, privacy: .public)")
                if ProcessInfo.processInfo.environment["BATON_HOTKEY_DEBUG"] != nil {
                    print("[hotkey] conflict \(action.rawValue) \(combo.display)")
                }
            } catch {
                log.error("热键 \(action.rawValue, privacy: .public) 注册失败：\(String(describing: error), privacy: .public)")
                if ProcessInfo.processInfo.environment["BATON_HOTKEY_DEBUG"] != nil {
                    print("[hotkey] failed \(action.rawValue) \(combo.display) \(error)")
                }
            }
        }
        refreshHotkeyMenuItems()

        // 注册成功 ≠ 能收到：自己重复、撞系统符号快捷键都查一遍
        let warnings = HotkeyAudit.warnings(
            actions: HotkeyAction.allCases.map { ($0.title, settings.combo(for: $0)) }
        )
        hotkeyWarnings = warnings
        for warning in warnings {
            log.error("热键校验：\(warning, privacy: .public)")
        }
    }

    private func perform(_ action: HotkeyAction) {
        ActionLog.action("hotkey", "action=\(action.rawValue) title=\(action.title)")
        switch action {
        case .annotate: captureAnnotate()
        case .pin: capturePin()
        case .scroll: captureScroll()
        case .ruler: showRuler()
        case .ocr: captureOCR()
        case .translateCapture: captureTranslate()
        case .translateSelection: translateSelection()
        case .clipboard: showClipboard()
        case .fullScreen: captureFullScreen()
        case .lastArea: captureLastArea()
        case .lastAreaSave: captureLastAreaAndSave()
        case .timed: captureTimed()
        case .lastShot: restoreLastShot()
        case .activeWindow: captureActiveWindow()
        case .togglePins: toggleAllPins()
        case .recordArea: recordArea()
        case .recordScreen: recordScreen()
        case .recordWindow: recordWindow()
        case .recordApp: recordApp()
        }
    }

    public func stop() {
        smoothScroll?.finishGesture()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        started = false
    }

    // MARK: - 菜单栏

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "command", accessibilityDescription: "Baton")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Baton"
        }

        let menu = NSMenu()

        // 最常用的两个动作直接摆在外面：菜单栏 App 的价值就是少点一层。
        // 其余按功能收进子菜单 —— 30 项平铺在一列里，找东西只能靠扫读，等于没有分组。
        menu.addItem(makeItem("区域截图", action: #selector(captureArea),
                              symbol: "rectangle.dashed"))
        menu.addItem(hotkeyItem(.scroll, "长截图", #selector(captureScroll),
                                symbol: "arrow.down.to.line"))
        menu.addItem(.separator())

        menu.addItem(submenu("截图", symbol: "camera.viewfinder", items: [
            hotkeyItem(.fullScreen, "全屏截图", #selector(captureFullScreen),
                       symbol: "rectangle.inset.filled"),
            makeItem("窗口截图", action: #selector(captureWindow), symbol: "macwindow"),
            hotkeyItem(.activeWindow, "截取活动窗口", #selector(captureActiveWindow),
                       symbol: "macwindow.on.rectangle"),
            makeItem("元素截图", action: #selector(captureElement), symbol: "cursorarrow.rays"),
            .separator(),
            hotkeyItem(.timed, "延迟截图", #selector(captureTimed), symbol: "timer"),
            .separator(),
            hotkeyItem(.lastArea, "截取上一次区域", #selector(captureLastArea),
                       symbol: "rectangle.dashed.badge.record"),
            hotkeyItem(.lastAreaSave, "上一次区域并保存", #selector(captureLastAreaAndSave),
                       symbol: "square.and.arrow.down"),
            hotkeyItem(.lastShot, "回溯上一次截图", #selector(restoreLastShot),
                       symbol: "clock.arrow.circlepath"),
            .separator(),
            hotkeyItem(.annotate, "区域标注", #selector(captureAnnotate),
                       symbol: "pencil.tip.crop.circle"),
        ]))

        menu.addItem(submenu("录制", symbol: "record.circle", items: [
            hotkeyItem(.recordArea, "区域录制", #selector(recordArea),
                       symbol: "rectangle.dashed.badge.record"),
            hotkeyItem(.recordScreen, "全屏录制", #selector(recordScreen),
                       symbol: "rectangle.inset.filled"),
            hotkeyItem(.recordWindow, "窗口录制", #selector(recordWindow), symbol: "macwindow"),
            hotkeyItem(.recordApp, "应用录制", #selector(recordApp), symbol: "app.badge"),
            .separator(),
            stopRecordingItem(),
        ]))

        menu.addItem(submenu("贴图", symbol: "pin", items: [
            hotkeyItem(.pin, "截图贴图", #selector(capturePin), symbol: "pin"),
            makeItem("从文件贴图…", action: #selector(pinFromFile), key: "o", symbol: "doc"),
            hotkeyItem(.togglePins, "隐藏/显示所有贴图", #selector(toggleAllPins),
                       symbol: "eye.slash"),
            makeItem("关闭所有贴图", action: #selector(closeAllPins), symbol: "xmark.circle"),
        ]))

        menu.addItem(submenu("工具", symbol: "wrench.and.screwdriver", items: [
            hotkeyItem(.ruler, "屏幕尺子", #selector(showRuler), symbol: "ruler"),
            hotkeyItem(.translateSelection, "划词翻译", #selector(translateSelection),
                       symbol: "character.book.closed"),
            hotkeyItem(.translateCapture, "截图翻译", #selector(captureTranslate),
                       symbol: "character.bubble"),
            hotkeyItem(.ocr, "截图 OCR", #selector(captureOCR), symbol: "text.viewfinder"),
            hotkeyItem(.clipboard, "剪贴板历史", #selector(showClipboard),
                       symbol: "list.clipboard"),
        ]))

        // 开关类放在「高级」里：低频、又不想每次去设置页里翻
        var advanced: [NSMenuItem] = []

        let login = makeItem("登录时启动", action: #selector(toggleLoginItem),
                             symbol: "power")
        loginMenuItem = login
        advanced.append(login)

        let inputSourceItem = makeItem("按 App 记住输入法", action: #selector(toggleInputSource),
                                       symbol: "keyboard")
        inputSourceItem.state = (inputSource?.isEnabled ?? false) ? .on : .off
        inputSourceMenuItem = inputSourceItem
        advanced.append(inputSourceItem)
        advanced.append(makeItem("输入法设置…", action: #selector(showInputSourceSettings),
                                 symbol: "character.cursor.ibeam"))

        let smoothItem = makeItem("平滑滚动（滚轮）", action: #selector(toggleSmoothScroll),
                                  symbol: "scroll")
        smoothItem.state = (smoothScroll?.isEnabled ?? false) ? .on : .off
        smoothItem.toolTip = hub.scrollInterceptionUnavailableReason
        smoothScrollMenuItem = smoothItem
        advanced.append(smoothItem)

        advanced.append(.separator())
        advanced.append(makeItem("打开登录项设置…", action: #selector(openLoginSettings),
                                 symbol: "gearshape.2"))
        // 排查问题时先看日志：一眼能看到用户点了什么、卡在哪一步
        advanced.append(makeItem("打开日志文件夹", action: #selector(openLogFolder),
                                 symbol: "doc.text.magnifyingglass"))

        menu.addItem(submenu("高级", symbol: "slider.horizontal.3", items: advanced))

        menu.addItem(.separator())
        menu.addItem(makeItem("设置…", action: #selector(showPreferencesFromMenu),
                              key: ",", symbol: "gearshape"))
        menu.addItem(makeItem("退出 Baton", action: #selector(quit), key: "q",
                              symbol: "door.left.hand.open"))

        item.menu = menu
        statusItem = item
    }

    /// 菜单点击统一在这里记一条，不用在每个 `@objc` 里各写一行。
    /// 通知里带的就是被点的 `NSMenuItem`，标题 + selector 足够定位到具体功能。
    private func observeMenuActions() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(menuWillSendAction(_:)),
                                               name: NSMenu.willSendActionNotification,
                                               object: nil)
    }

    @objc private func menuWillSendAction(_ note: Notification) {
        // 不同系统版本的 userInfo 键名不一致，先按常见键取，再退化成「随便哪个 NSMenuItem」
        let item = note.userInfo?["NSMenuItem"] as? NSMenuItem
            ?? note.userInfo?.values.compactMap { $0 as? NSMenuItem }.first
        guard let item else {
            let keys = note.userInfo?.keys.map { "\($0)" }.joined(separator: ",") ?? "-"
            ActionLog.action("menu", "payload=none keys=\(keys)")
            return
        }
        let selector = item.action.map(NSStringFromSelector) ?? "-"
        ActionLog.action("menu", "item=\(item.title) selector=\(selector)")
    }

    /// 「停止录制」要留句柄：录制期间才可点
    private func stopRecordingItem() -> NSMenuItem {
        let item = makeItem("停止录制", action: #selector(stopRecording),
                            symbol: "stop.circle.fill")
        item.isEnabled = false
        stopRecordingMenuItem = item
        return item
    }

    /// 收进子菜单的分组。父项自己带图标，展开后每项也有图标，扫读时不用逐个读字。
    private func submenu(_ title: String, symbol: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = symbolImage(symbol)
        let inside = NSMenu(title: title)
        for item in items { inside.addItem(item) }
        parent.submenu = inside
        return parent
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func makeItem(_ title: String, action: Selector, key: String = "",
                          symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = symbolImage(symbol) }
        return item
    }

    /// 菜单项右侧显示当前热键。`keyEquivalent` 只用于显示——真正触发走 Carbon 全局热键，
    /// 所以这里不存在「点了菜单项反而触发两次」的问题。
    private func hotkeyItem(_ action: HotkeyAction, _ title: String, _ selector: Selector,
                            symbol: String? = nil) -> NSMenuItem {
        let item = makeItem(title, action: selector, symbol: symbol)
        hotkeyMenuItems[action] = item
        return item
    }

    private func refreshHotkeyMenuItems() {
        let settings = hotkeyStore?.load() ?? .default
        for (action, item) in hotkeyMenuItems {
            let combo = settings.combo(for: action)
            if let key = combo.menuKeyEquivalent {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = combo.menuModifierMask
                item.toolTip = combo.display
            } else {
                // 认不出字符的键（比如未知 keycode）：宁可空着，也别显示错
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                item.toolTip = combo.display
            }
        }
    }

    private func refreshLoginMenuItem() {
        let status = loginItem.status
        loginMenuItem?.state = status.enabled ? .on : .off
        loginMenuItem?.toolTip = status.detail
    }

    @objc private func toggleLoginItem() {
        let target = !loginItem.status.enabled
        do {
            let status = try loginItem.setEnabled(target)
            log.info("登录项切换为 \(status.detail, privacy: .public)")
        } catch {
            log.error("登录项切换失败：\(String(describing: error), privacy: .public)")
            presentAlert(title: "无法修改登录项",
                         message: "\(error.localizedDescription)\n\n若状态为 requiresApproval，请在系统设置中手动批准。")
        }
        refreshLoginMenuItem()
    }

    @objc private func toggleInputSource() {
        guard let inputSource else { return }
        inputSource.setEnabled(!inputSource.isEnabled)
        inputSourceMenuItem?.state = inputSource.isEnabled ? .on : .off
    }

    /// 页序：通用 0、输入法 1、测量 2（有的话）。
    @objc private func showInputSourceSettings() {
        openPreferences(tab: 1)
    }

    @objc private func toggleSmoothScroll() {
        guard let smoothScroll else { return }
        let target = !smoothScroll.isEnabled
        smoothScroll.setEnabled(target)
        hub.setScrollInterceptor(makeScrollInterceptor())
        smoothScrollMenuItem?.state = target ? .on : .off

        guard target, !hub.scrollTapIntercepts else { return }
        let reason = hub.scrollInterceptionUnavailableReason ?? "无法接管滚动事件"
        smoothScrollMenuItem?.toolTip = reason
        PermissionCenter.request(.accessibility)
        presentAlert(title: "平滑滚动需要「辅助功能」权限",
                     message: "\(reason)\n\n已打开系统授权入口；授权后请在本菜单重新勾选。")
    }

    @objc private func openLoginSettings() {
        loginItem.openSystemSettings()
    }

    @objc private func showPreferencesFromMenu() { openPreferences() }

    public func openPreferences(tab: Int = 0) {
        ActionLog.action("prefs.open", "tab=\(tab)")
        let prefs: PreferencesWindowController
        if let existing = preferences {
            prefs = existing
        } else {
            let created = PreferencesWindowController(loginItem: loginItem,
                                                      inputSource: inputSource,
                                                      smoothScroll: smoothScroll,
                                                      clipboard: clipboard?.store,
                                                      rulerSettings: rulerSettings,
                                                      captureSettings: captureSettings,
                                                      recordingSettings: recordingSettings)
            created.onChange = { [weak self] in
                guard let self else { return }
                self.hub.setScrollInterceptor(self.makeScrollInterceptor())
                self.translator?.reloadSettings()
                self.registerHotkeys()
                self.refreshToggleStates()
            }
            created.onClose = { [weak self] in
                guard let self else { return }
                self.preferencesHoldingRegular = false
                self.activation.leaveRegular()
            }
            preferences = created
            prefs = created
        }

        if !preferencesHoldingRegular {
            activation.enterRegular()
            preferencesHoldingRegular = true
        }
        prefs.show(tab: tab)
    }

    /// 设置里改了开关后，菜单栏的勾选要跟着走。
    private func refreshToggleStates() {
        inputSourceMenuItem?.state = (inputSource?.isEnabled ?? false) ? .on : .off
        smoothScrollMenuItem?.state = (smoothScroll?.isEnabled ?? false) ? .on : .off
        refreshLoginMenuItem()
    }

    // MARK: - 截图

    // 区域截图和区域标注走同一条原地流程：框完先给工具条，
    // 复制/保存/贴图由用户点按钮决定，不再「一松手就进剪贴板」。
    @objc private func captureArea() { capture(intent: .area, action: .edit) }
    @objc private func captureFullScreen() {
        // displayID 传 nil：取鼠标所在屏，多屏时不用先问「哪一块」
        capture(intent: .fullScreen(displayID: nil), action: .edit)
    }
    @objc private func captureLastArea() { capture(intent: .lastArea, action: .edit) }
    @objc private func captureLastAreaAndSave() { capture(intent: .lastArea, action: .save(format: .png)) }

    /// 延迟截图：先倒数，再走普通区域框选。
    ///
    /// 倒计时必须在 AppShell 层做——CaptureSession 里 sleep 时既没法显示面板，
    /// 也没法取消，用户只能干等还看不出还有几秒。
    @objc private func captureTimed() {
        guard countdown == nil, inPlaceAnnotator?.isActive != true, ruler == nil else { return }
        let hud = CountdownHUD(seconds: captureSettings.settings.timedSeconds)
        countdown = hud
        hud.onFinish = { [weak self] in
            self?.countdown = nil
            self?.capture(intent: .area, action: .edit)
        }
        hud.onCancel = { [weak self] in
            self?.countdown = nil
            self?.log.debug("延迟截图取消")
        }
        hud.start()
    }

    /// 回溯：把最近一张截图重新打开进标注，不用重新抓屏。
    @objc private func restoreLastShot() {
        guard let lastShot else {
            presentAlert(title: "没有可回溯的截图", message: "先截一张图，再来回溯。")
            return
        }
        presentAnnotation(image: lastShot.image, scale: lastShot.scale)
    }
    @objc private func captureWindow() { capture(intent: .window, action: .edit) }

    /// 截取活动窗口：直接抓前台 App 最靠前的那个窗口，不铺覆盖层。
    ///
    /// 前台 App 必须在 `NSApp.activate()` 之前取——那一步可能把前台换成 Baton 自己，
    /// 之后再问「谁是前台」就只剩下菜单栏这一位了。
    @objc private func captureActiveWindow() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard let window = WindowPicker.activeWindow(frontmostPID: front, excludingPID: getpid()) else {
            presentAlert(title: "没有可截取的窗口",
                         message: "前台 App 没有可见窗口，或者前台就是 Baton 自己。")
            return
        }
        log.debug("活动窗口：\(window.displayLabel, privacy: .public) id=\(window.windowID)")
        capture(intent: .windowID(window.windowID), action: .edit)
    }

    @objc private func captureElement() { capture(intent: .element) }
    @objc private func captureTranslate() { capture(intent: .area, action: .translate) }
    @objc private func captureOCR() { capture(intent: .area, action: .ocr(silent: false)) }
    @objc private func captureAnnotate() { capture(intent: .area, action: .edit) }
    @objc private func capturePin() { capture(intent: .area, action: .pin) }

    /// 从磁盘挑一张图贴出来。Finder 直接拖到已有贴图上也是这条路。
    @objc private func pinFromFile() {
        ActionLog.action("pin.file.panel", "")
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // 和模态提示同理：不先激活，面板可能开在别人窗口后面
        ActivationPolicyController.shared.enterRegular()
        defer { ActivationPolicyController.shared.leaveRegular() }
        NSApp.activate()
        let response = panel.runModal()
        ActionLog.result("pin.file.panel", "response=\(response == .OK ? "ok" : "cancel") files=\(panel.urls.count)")
        guard response == .OK else { return }
        var pinned = 0
        for url in panel.urls where pinController.pinFile(url) { pinned += 1 }
        if pinned < panel.urls.count {
            presentAlert(title: "有图片没贴上", message: "\(panel.urls.count - pinned) 个文件读不出来，可能不是位图格式。")
        }
    }

    /// 一键把屏幕上所有贴图藏起来（再按一次全部回来）。不删库，重启也还在。
    @objc private func toggleAllPins() {
        guard pinController.count > 0 else {
            presentAlert(title: "没有贴图", message: "先贴一张，再来隐藏。")
            return
        }
        pinController.toggleHidden()
        log.debug("贴图隐藏：\(self.pinController.isHidden) 共 \(self.pinController.count) 张")
    }

    @objc private func closeAllPins() {
        let count = pinController.count
        ActionLog.action("pin.closeAll", "count=\(count)")
        guard count > 0 else {
            ActionLog.result("pin.closeAll", "skipped=empty")
            return
        }
        // 原来这里直接 `alert.runModal()`：Baton 是 accessory 应用，
        // 对话框会被前台 App 盖住，而模态循环又吃掉了状态栏菜单 —— 用户看到的就是「卡死」。
        Task { [weak self] in
            guard let self else { return }
            let confirmed = await ModalAlert.confirm(title: "关闭所有贴图？",
                                                     message: "共 \(count) 张，关掉后不会再恢复。",
                                                     confirm: "关闭全部",
                                                     name: "pin.closeAll")
            guard confirmed else {
                ActionLog.result("pin.closeAll", "cancelled=1")
                return
            }
            self.pinController.closeAll()
            ActionLog.result("pin.closeAll", "closed=\(count)")
        }
    }
    @objc private func captureScroll() { capture(intent: .area, action: .scroll(direction: .vertical)) }

    // MARK: - 录制

    @objc private func recordArea() { startRecording(.area) }
    @objc private func recordScreen() { startRecording(.fullScreen) }
    @objc private func recordWindow() { startRecording(.window) }
    @objc private func recordApp() { startRecording(.application) }
    @objc private func stopRecording() {
        Task { await recorder.stop() }
    }

    /// 四种模式只有「选目标」不同，后面都汇到 `RecorderController`。
    ///
    /// 选目标阶段要先抓一遍冻结帧（框选和窗口拾取都靠它），这一步几百毫秒；
    /// 期间用户看到的还是静止画面，框完立刻撤掉覆盖层，录制从实时画面开始。
    private func startRecording(_ target: RecordingTarget) {
        guard !recorder.isRecording else {
            presentAlert(title: "已经在录制", message: "先停止当前录制，再开始新的。")
            return
        }
        // 录制时覆盖层不能和倒计时/标注叠着抢键盘
        guard ruler == nil, inPlaceAnnotator?.isActive != true else { return }

        Task { [weak self] in
            guard let self else { return }
            guard let prepared = await self.makeRecordingConfig(target) else { return }
            do {
                try await self.recorder.start(target: target,
                                              config: prepared.config,
                                              highlight: prepared.highlight)
            } catch let error as RecordingError {
                self.presentAlert(title: "无法开始录制", message: error.message)
            } catch {
                self.presentAlert(title: "无法开始录制", message: error.localizedDescription)
            }
        }
    }

    private func makeRecordingConfig(_ target: RecordingTarget) async
        -> (config: RecordingConfig, highlight: CGRect?)? {
        let url = RecorderController.destinationURL()
        switch target {
        case .area:
            guard let selection = await captureSession.selectRegion() else { return nil }
            // highlight 就是用户框的那块：录制期间一直画着边框，
            // 让人知道「录的就是这一块」，不用去猜工具条标题里写的是哪种模式
            return (RecordingConfig(target: .area,
                                    rect: selection.globalRect,
                                    displayID: selection.display.displayID,
                                    url: url,
capturesAudio: recordingSettings.capturesAudio,
                                    capturesMicrophone: recordingSettings.capturesMicrophone),
                    selection.globalRect)
        case .fullScreen:
            return (RecordingConfig(target: .fullScreen,
                                    displayID: Self.displayUnderMouse(),
                                    url: url,
capturesAudio: recordingSettings.capturesAudio,
                                    capturesMicrophone: recordingSettings.capturesMicrophone),
                    nil)   // 整屏画边框没意义
        case .window:
            guard let windowID = await captureSession.selectWindow() else { return nil }
            let bounds = WindowPicker.enumerate(excludingPID: getpid())
                .first(where: { $0.windowID == windowID })?.bounds
            return (RecordingConfig(target: .window,
                                    displayID: Self.displayUnderMouse(),
                                    windowID: windowID,
                                    url: url,
capturesAudio: recordingSettings.capturesAudio,
                                    capturesMicrophone: recordingSettings.capturesMicrophone),
                    bounds)
        case .application:
            // 前台 App 必须在任何 activate 之前取，否则拿到的是 Baton 自己
            guard let front = NSWorkspace.shared.frontmostApplication else {
                presentAlert(title: "找不到要录的应用", message: "没有前台应用。")
                return nil
            }
            let windows = WindowPicker.enumerate(excludingPID: getpid())
                .filter { $0.ownerPID == front.processIdentifier }
            var union = windows.first?.bounds
            for window in windows.dropFirst() { union = union?.union(window.bounds) ?? window.bounds }
            return (RecordingConfig(target: .application,
                                    displayID: Self.displayUnderMouse(),
                                    ownerPID: front.processIdentifier,
                                    url: url,
capturesAudio: recordingSettings.capturesAudio,
                                    capturesMicrophone: recordingSettings.capturesMicrophone),
                    union)
        }
    }

    /// 鼠标所在屏的 displayID；拿不到就交给系统挑主屏。
    private static func displayUnderMouse() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(mouse) {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber {
                return number.uint32Value
            }
        }
        return nil
    }

    @objc private func showRuler() {
        // 已经在尺子里、或正在标注时不叠第二层覆盖窗
        guard ruler == nil, inPlaceAnnotator?.isActive != true else { return }
        let controller = RulerController(settings: rulerSettings)
        controller.onCaptureArea = { [weak self] image, scale in
            // 尺子里量好的区域直接进标注，不用再重新框一次
            self?.presentAnnotation(image: image, scale: scale.width)
        }
        ruler = controller
        Task { [weak self] in
            let outcome = await controller.run()
            self?.ruler = nil
            if case .failed(let reason) = outcome {
                self?.log.error("尺子失败：\(reason, privacy: .public)")
                self?.presentAlert(title: "尺子打不开", message: reason)
            }
        }
    }

    @objc private func translateSelection() {
        Task { await translator?.translateSelection() }
    }

    private func capture(intent: CaptureIntent, action: CaptureAction = .copy) {
        // 尺子开着时按截图热键：先把尺子收掉，别让两层冻结帧打架
        ruler?.cancel()
        // 倒计时还没走完又触发别的截图：以新的为准，别两个面板叠着
        countdown?.dismiss()
        countdown = nil
        let started = Date()
        ActionLog.action("capture.begin",
                         "intent=\(intent.logText) action=\(action.logText) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
        NSApp.activate()
        Task { [weak self] in
            guard let self else { return }
            let outcome = await captureSession.begin(intent: intent, action: action)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch outcome {
            case .cancelled:
                log.debug("截图取消")
                ActionLog.result("capture.cancelled", "ms=\(ms)")
            case .failed(let reason):
                log.error("截图失败：\(reason, privacy: .public)")
                ActionLog.fail("capture.failed", "ms=\(ms) reason=\(reason)")
                presentAlert(title: "截图失败", message: reason)
            case .captured(let result):
                ActionLog.result("capture.done",
                                 "rect=\(result.screenRect.logText) px=\(result.pixelRect.logText) ms=\(ms)")
                await handle(result)
            }
        }
    }

    private func handle(_ result: CaptureResult) async {
        // 每张成品都留一份，供「回溯上一次截图」用
        if let image = result.cropped {
            lastShot = (image, captureScale(of: result))
        }
        switch result.action {
        case .ocr(let silent):
            guard let image = result.cropped else { return }
            await translator?.recognize(image: image, silent: silent)
        case .translate:
            guard let image = result.cropped else { return }
            await translator?.translate(image: image)
        case .edit:
            guard let image = result.cropped else { return }
            // Longshot 式原地编辑：覆盖层留着当舞台，工具条浮在选区外
            if inPlaceAnnotator?.present(result: result,
                                         overlay: captureSession.overlayController) == true {
                return
            }
            presentAnnotation(image: image, scale: captureScale(of: result))
        case .pin:
            guard let image = result.cropped else { return }
            pinController.pin(image, scale: captureScale(of: result), near: result.screenRect)
            ActionLog.result("pin.created", "count=\(pinController.count) at=\(result.screenRect.logText)")
        case .scroll:
            await runScroll(from: result)
        case .save(let format):
            guard let image = result.cropped else { return }
            saveImage(image, format: format)
        default:
            copyToPasteboard(result)
        }
    }

    /// 直接保存，不经过标注窗。用户自己选位置，取消就什么都不发生。
    private func saveImage(_ image: CGImage, format: ImageFormat) {
        let panel = NSSavePanel()
        let stamp = Self.fileTimestamp()
        let type: UTType
        switch format {
        case .png:
            type = .png
            panel.nameFieldStringValue = "Baton-\(stamp).png"
        case .jpeg:
            type = .jpeg
            panel.nameFieldStringValue = "Baton-\(stamp).jpg"
        case .heic:
            type = .heic
            panel.nameFieldStringValue = "Baton-\(stamp).heic"
        }
        panel.allowedContentTypes = [type]
        ActionLog.action("save.panel", "format=\(format.rawValue)")
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let destination = CGImageDestinationCreateWithURL(
                      url as CFURL, type.identifier as CFString, 1, nil) else {
                ActionLog.result("save.panel", "cancelled=1")
                return
            }
            CGImageDestinationAddImage(destination, image, nil)
            let done = CGImageDestinationFinalize(destination)
            ActionLog.result("save.image", "ok=\(done) file=\(url.lastPathComponent) px=\(image.width)x\(image.height)")
        }
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 长截图：调用方保证覆盖层还停在选区上（框选后直接进、或标注工具条里点按钮）。
    private func runScroll(from result: CaptureResult) async {
        let session = ScrollCaptureController(
            selection: CaptureSelection(globalRect: result.screenRect, display: result.display),
            overlay: captureSession.overlayController
        )
        switch await session.run() {
        case .finished(let image):
            // 长图比屏幕高，交给可滚动的标注窗口
            let scale = CGFloat(image.width) / max(result.screenRect.width, 1)
            log.info("长截图完成：\(image.width)×\(image.height)px")
            lastShot = (image, max(scale, 1))
            // 收尾时标注窗必须主动前置，否则长图开在 Chrome 后面
            presentAnnotation(image: image, scale: max(scale, 1))
        case .cancelled:
            log.debug("长截图取消")
        case .failed(let reason):
            log.error("长截图失败：\(reason, privacy: .public)")
            presentAlert(title: "长截图失败", message: reason)
        }
    }

    /// 裁剪图的像素 ÷ 选区点数 = 真实倍率。降采样抓帧时也不失真。
    private func captureScale(of result: CaptureResult) -> CGFloat {
        guard result.screenRect.width > 0 else { return 1 }
        let width = CGFloat(result.cropped?.width ?? 0)
        return max(width / result.screenRect.width, 1)
    }

    /// 打开标注窗口。
    ///
    /// LSUIElement 的 App 直接 show 顶不到别的 App 前面——长截图自动收尾时
    /// 用户手还停在 Chrome 上，窗口会开在它后面，看起来就是「点完成没反应」。
    /// 必须先切 regular + activate；regular 由窗口关闭时释放，和偏好窗口同一套路。
    private func presentAnnotation(image: CGImage, scale: CGFloat) {
        if !annotatorHoldingRegular {
            activation.enterRegular()
            annotatorHoldingRegular = true
        }
        NSApp.activate(ignoringOtherApps: true)
        annotator?.show(image: image, scale: scale)
    }

    private func copyToPasteboard(_ result: CaptureResult) {
        guard let image = result.cropped else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)])
        log.info("已复制 \(Int(result.screenRect.width))×\(Int(result.screenRect.height)) 到剪贴板")
    }

    /// 打开剪贴板历史。菜单项和全局热键都走这里，也给 `--clip-panel` 诊断用。
    public func openClipboardPanel() {
        guard let clipboard else {
            presentAlert(title: "剪贴板历史不可用", message: "数据库初始化失败，请查看日志。")
            return
        }
        clipboard.showHistory()
    }

    @objc private func showClipboard() {
        openClipboardPanel()
    }

    // MARK: - 其他

    private func presentAlert(title: String, message: String) {
        ActionLog.action("alert", "title=\(title) message=\(message)")
        // 覆盖层在 .screenSaver 层：要压住它得同层；没有覆盖层时用普通模态层就够
        ModalAlert.notify(title: title, message: message, name: "alert",
                          above: captureSession.overlayController.frontWindow)
    }

    @objc private func quit() {
        ActionLog.app("quit", "pins=\(pinController.count)")
        NSApp.terminate(nil)
    }

    /// 日志目录直接开在 Finder 里——用户遇到问题，让他自己把 baton.log 发过来就行。
    @objc private func openLogFolder() {
        ActionLog.action("log.reveal", ActionLog.shared.directory.path)
        NSWorkspace.shared.selectFile(ActionLog.shared.fileURL.path,
                                     inFileViewerRootedAtPath: ActionLog.shared.directory.path)
    }
}

// MARK: - 日志用的短描述

private extension CGRect {
    /// 日志里不用带小数：点位是整数，小数点只会让 grep 变难
    var logText: String {
        "\(Int(origin.x)),\(Int(origin.y)) \(Int(width))x\(Int(height))"
    }
}

private extension CaptureIntent {
    var logText: String {
        switch self {
        case .area: return "area"
        case .window: return "window"
        case .element: return "element"
        case .fullScreen(let id): return "fullScreen(\(id.map(String.init) ?? "underMouse"))"
        case .lastArea: return "lastArea"
        case .windowID(let id): return "windowID(\(id))"
        case .fixed(let rect): return "fixed(\(rect.logText))"
        }
    }
}

private extension CaptureAction {
    var logText: String {
        switch self {
        case .copy: return "copy"
        case .save(let format): return "save(\(format.rawValue))"
        case .edit: return "edit"
        case .pin: return "pin"
        case .ocr(let silent): return "ocr(silent:\(silent))"
        case .translate: return "translate"
        case .scroll(let direction): return "scroll(\(direction))"
        case .pickColor: return "pickColor"
        case .ruler: return "ruler"
        }
    }
}

import AppKit
import Carbon
import os

/// 按前台 App 自动切换输入法。
///
/// 两类数据：
/// - **记忆**：离开某个 App 时记下当时的源，回来就切回去。这是主体行为，无需配置。
/// - **规则**：显式指定某个 App 固定用哪个源，优先于记忆。
///
/// 没有规则也没有记忆时不干预——强行切回某个"默认源"会和用户的手动切换打架。
@MainActor
public final class InputSourceService {
    public private(set) var settings: InputSourceSettings

    private let hub: EventHub
    private let catalog = InputSourceCatalog()
    private let store: InputSourceStore
    private let log = Logger(subsystem: "com.selier.baton", category: "inputsource")

    private var task: Task<Void, Never>?
    private var pendingSwitch: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var lastKey: String?
    private let focusWatcher = BrowserFocusWatcher()
    /// 焦点此刻是不是在浏览器地址栏。地址栏里切源是临时行为，不能写进 App 记忆
    private var inAddressBar = false

    public init(hub: EventHub, directory: URL? = nil) throws {
        self.hub = hub
        self.store = try InputSourceStore(directory: directory)
        self.settings = store.load()
    }

    public var isEnabled: Bool { settings.enabled }
    public var currentSourceID: String? { catalog.currentID }
    public var currentSourceName: String? { catalog.currentName }
    public var installedSources: [InputSourceInfo] { catalog.all }
    public var memory: [String: String] { settings.memory }
    public var rules: [String: String] { settings.rules }
    public var ignoredApps: Set<String> { settings.ignored }
    public var switchDelayMs: Int { settings.switchDelayMs }
    public var addressBarSourceID: String? { settings.addressBarSourceID }

    public func sourceName(id: String) -> String? {
        installedSources.first { $0.id == id }?.name
    }

    public func start() {
        guard task == nil else { return }

        // 启动时不切换：用户此刻可能正在输入，替他把源改掉很突兀
        lastKey = Self.key(for: NSWorkspace.shared.frontmostApplication)

        task = Task { [weak self] in
            guard let self else { return }
            for await event in hub.events(buffering: 8) {
                if case .frontAppChanged(let app) = event {
                    handleFrontApp(app)
                }
            }
        }

        // 用户手动切换时也要更新记忆，否则「我在这个 App 里换过一次」会被下次切 App 覆盖
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rememberCurrentSource()
            }
        }

        log.info("输入法记忆已启用（\(self.settings.memory.count) 条记忆，\(self.settings.rules.count) 条规则）")

        syncFocusWatcher()
    }

    public func stop() {
        task?.cancel()
        task = nil
        pendingSwitch?.cancel()
        pendingSwitch = nil
        focusWatcher.stop()
        inAddressBar = false
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observer = nil
    }

    // MARK: - 对外操作

    public func setEnabled(_ enabled: Bool) {
        settings.enabled = enabled
        persist()
        syncFocusWatcher()
    }

    /// 传 nil 关掉地址栏规则。
    public func setAddressBarSource(_ sourceID: String?) {
        settings.addressBarSourceID = sourceID
        persist()
        syncFocusWatcher()
    }

    /// 地址栏监听只在「总开关开 + 配了源」时才轮询，没配就一点开销都不产生。
    /// 不在这里判断辅助功能权限：用户可能开着设置页去授权，权限到手后应当立刻生效，
    /// 读不到时 `BrowserFocusReader` 自己会快速返回 unknown。
    private func syncFocusWatcher() {
        let shouldRun = settings.enabled && settings.addressBarSourceID != nil
        if shouldRun {
            focusWatcher.onChange = { [weak self] focus, key in
                self?.handleBrowserFocus(focus, key: key)
            }
            focusWatcher.start()
        } else {
            focusWatcher.stop()
            focusWatcher.onChange = nil
            inAddressBar = false
        }
    }

    /// 传 nil 删除该 App 的显式规则，回到「按记忆走」。
    public func setRule(bundleID: String, sourceID: String?) {
        if let sourceID {
            settings.rules[bundleID] = sourceID
        } else {
            settings.rules.removeValue(forKey: bundleID)
        }
        persist()
    }

    public func rule(for bundleID: String) -> String? {
        settings.rules[bundleID]
    }

    /// 忽略某个 App：不套规则、不记记忆。取消忽略后原来的规则和记忆仍然有效。
    public func setIgnored(_ bundleID: String, _ ignored: Bool) {
        if ignored {
            settings.ignored.insert(bundleID)
        } else {
            settings.ignored.remove(bundleID)
        }
        persist()
    }

    public func isIgnored(_ bundleID: String) -> Bool {
        settings.ignored.contains(bundleID)
    }

    public func removeMemory(_ bundleID: String) {
        settings.memory.removeValue(forKey: bundleID)
        persist()
    }

    public func clearMemory() {
        settings.memory.removeAll()
        persist()
    }

    /// 切换延迟限制在 0–500ms：太短没意义，太长会让用户觉得输入法卡了。
    public func setSwitchDelay(_ milliseconds: Int) {
        settings.switchDelayMs = min(max(milliseconds, 0), 500)
        persist()
    }

    // MARK: - 事件处理

    private func handleFrontApp(_ app: FrontApp) {
        let key = app.bundleID ?? "pid:\(app.pid)"

        // 面板把 Baton 自己变成前台，不能因此记成「Baton 用的是这个源」
        if app.bundleID == Bundle.main.bundleIdentifier { return }

        // 通知中心、输入法候选、常驻后台的代理进程都会短暂「前台」，
        // 把它们记成记忆只会让列表变成一堆看不懂的条目，也没有切换的意义
        if let running = NSRunningApplication(processIdentifier: app.pid),
           running.activationPolicy != .regular {
            return
        }

        guard key != lastKey else { return }

        if let previous = lastKey,
           InputSourceResolver.shouldRemember(previous, settings: settings) {
            rememberCurrentSource(for: previous)
        }
        lastKey = key

        // 换了 App，地址栏状态作废；上一次还在等延迟的切换也作废
        inAddressBar = false
        pendingSwitch?.cancel()
        pendingSwitch = nil

        guard settings.enabled else { return }
        guard let target = InputSourceResolver.target(for: key, settings: settings) else { return }
        applyTarget(target, key: key, appName: app.name ?? key)
    }

    /// 浏览器焦点在地址栏和网页之间移动。
    ///
    /// 只在「进入 / 离开地址栏」时动一次，不做持续强切：用户可能为了搜中文内容
    /// 手动换回中文，一直按回去就没法用了。
    private func handleBrowserFocus(_ focus: BrowserFocus, key: String) {
        let nowInBar = focus == .shell
        guard nowInBar != inAddressBar else { return }
        inAddressBar = nowInBar

        pendingSwitch?.cancel()
        pendingSwitch = nil

        guard settings.enabled, !key.isEmpty else { return }
        guard let target = InputSourceResolver.target(for: key,
                                                      settings: settings,
                                                      inAddressBar: inAddressBar) else {
            return
        }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? key
        // 地址栏不等延迟：延迟是为了躲 App 激活时吞首字符，而地址栏是同一进程内的焦点移动，
        // 反着等只会让第一个字母先用旧源打出去
        applyTarget(target, key: key, appName: appName, respectsDelay: false)
    }

    /// 切到目标源，按设定的延迟执行。等待期间换 App / 用户自己换源就放弃。
    private func applyTarget(_ target: String, key: String, appName: String, respectsDelay: Bool = true) {
        guard catalog.contains(id: target) else {
            log.info("规则指向的输入源不存在，跳过：\(target, privacy: .public)")
            return
        }
        guard target != catalog.currentID else { return }

        let delay = respectsDelay ? settings.switchDelayMs : 0
        guard delay > 0 else {
            select(target, appName: appName)
            return
        }

        pendingSwitch = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            } catch {
                return
            }
            guard let self, self.lastKey == key else { return }
            // 等待期间用户可能自己切了源，别把他改回去
            guard target != self.catalog.currentID else { return }
            self.select(target, appName: appName)
        }
    }

    private func select(_ target: String, appName: String) {
        if catalog.select(id: target) {
            log.debug("切到 \(target, privacy: .public)（\(appName, privacy: .public)）")
        } else {
            log.error("切换输入源失败：\(target, privacy: .public)")
        }
    }

    private func rememberCurrentSource() {
        guard let key = lastKey else { return }
        rememberCurrentSource(for: key)
    }

    private func rememberCurrentSource(for key: String) {
        guard InputSourceResolver.shouldRemember(key, settings: settings) else { return }
        // 地址栏里用的是「敲网址的源」，不是这个 App 的习惯，记进去会把记忆搞脏
        guard !inAddressBar else { return }
        guard let current = catalog.currentID else { return }
        guard settings.memory[key] != current else { return }
        settings.memory[key] = current
        persist()
    }

    private func persist() {
        do {
            try store.save(settings)
        } catch {
            log.error("输入法设置保存失败：\(String(describing: error), privacy: .public)")
        }
    }

    private static func key(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        if let bundleID = app.bundleIdentifier { return bundleID }
        return "pid:\(app.processIdentifier)"
    }
}

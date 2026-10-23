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
    private var observer: NSObjectProtocol?
    private var lastKey: String?

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
    }

    public func stop() {
        task?.cancel()
        task = nil
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observer = nil
    }

    // MARK: - 对外操作

    public func setEnabled(_ enabled: Bool) {
        settings.enabled = enabled
        persist()
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

    // MARK: - 事件处理

    private func handleFrontApp(_ app: FrontApp) {
        let key = app.bundleID ?? "pid:\(app.pid)"

        // 面板把 Baton 自己变成前台，不能因此记成「Baton 用的是这个源」
        if app.bundleID == Bundle.main.bundleIdentifier { return }
        guard key != lastKey else { return }

        if let previous = lastKey {
            rememberCurrentSource(for: previous)
        }
        lastKey = key

        guard settings.enabled else { return }
        guard let target = InputSourceResolver.target(for: key, settings: settings) else { return }
        guard catalog.contains(id: target) else {
            log.info("规则指向的输入源不存在，跳过：\(target, privacy: .public)")
            return
        }
        guard target != catalog.currentID else { return }

        if catalog.select(id: target) {
            log.debug("切到 \(target, privacy: .public)（\(app.name ?? key, privacy: .public)）")
        } else {
            log.error("切换输入源失败：\(target, privacy: .public)")
        }
    }

    private func rememberCurrentSource() {
        guard let key = lastKey else { return }
        rememberCurrentSource(for: key)
    }

    private func rememberCurrentSource(for key: String) {
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

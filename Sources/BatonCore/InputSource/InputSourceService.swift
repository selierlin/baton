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
    /// 输入法启用/停用列表变了（装了新输入法、卸载旧的）
    private var availabilityObserver: NSObjectProtocol?
    private var lastKey: String?
    private let focusWatcher = BrowserFocusWatcher()
    /// 焦点此刻是不是在浏览器地址栏。地址栏里切源是临时行为，不能写进 App 记忆
    private var inAddressBar = false
    /// 当前源是不是被地址栏 / 网站规则定下的。这时的源不代表用户对这个 App 的习惯，
    /// 记进记忆会把它冲掉（比如 GitHub 里写中文评论，会把 GitHub 的记忆写死成中文）
    private var suppressMemory = false
    /// 上一次「我们自己换的源」。换源通知分不清是谁换的，靠它把 Baton 自己的动作排掉，
    /// 否则进输入框时自动切的那一下会被当成用户偏好学进去
    private var lastSelfSwitchAt: Date?
    /// 同一条学习记录 1 秒内只算一次：Chrome 换源偶尔连发两条通知，
    /// 不去重的话一次手动切换就能直接攒满建出规则
    private var lastLearned: (id: String, at: Date)?
    /// 上一次把「规则命中时间」写盘的时刻。命中可能很频繁，按小时节流；
    /// 判断粒度是两个月，丢一小时的记录不影响结论
    private var lastHitPersistAt: Date?
    /// 读 AX 不能上主线程，用户换源时才读一次，不用常驻轮询
    private let learnQueue = DispatchQueue(label: "com.selier.baton.site-learn", qos: .utility)
    /// 当前系统里能选、已启用的源 ID。缓存起来，UI 每次刷新不必重新问 TIS
    private var installedIDs: Set<String> = []

    /// 配置里引用了、但系统里现在找不到的源。换输入法后旧配置会落到这里
    public private(set) var missingSources: [MissingSource] = []

    public init(hub: EventHub, directory: URL? = nil) throws {
        self.hub = hub
        self.store = try InputSourceStore(directory: directory)
        self.settings = store.load()
        // 只在启动时清一次：判定粒度是天，跑定时器不值当
        normalizeLearnedRules()
        pruneStaleRules()
        // 启动时对一次账：Baton 没运行时换掉的输入法，通知没送到过
        refreshSourceAvailability()
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
    public var isLearningEnabled: Bool { settings.learningEnabled }
    /// 学习中还没攒够次数的组合
    public var learnCandidates: [SiteRuleCandidate] { settings.learnCandidates }

    public func sourceName(id: String) -> String? {
        // 先查缓存：源被卸载后 TIS 里已经没有了，但配置里还引用着，得能说出它叫什么
        settings.sourceNames[id] ?? installedSources.first { $0.id == id }?.name
    }

    public func isSourceAvailable(_ id: String) -> Bool {
        installedIDs.contains(id)
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
                self?.handleSelectedSourceChanged()
            }
        }

        // 装/卸/启停输入法。只在真的变了才发，比定时扫一遍省得多
        availabilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 通知可能早于 TIS 列表更新，稍等一下再对账
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated {
                    self?.refreshSourceAvailability()
                }
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
        if let availabilityObserver {
            DistributedNotificationCenter.default().removeObserver(availabilityObserver)
        }
        availabilityObserver = nil
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

    // MARK: - 网站规则

    public var siteRules: [SiteRule] { settings.siteRules }

    /// 同一个「域名 + 关键字」只留一条，重复添加等于改源。
    public func addSiteRule(_ rule: SiteRule) {
        var normalized = rule
        normalized.host = SiteRuleMatcher.normalizeHost(rule.host) ?? rule.host
        normalized.keyword = (rule.keyword?.isEmpty ?? true) ? nil : rule.keyword
        guard !normalized.host.isEmpty, !normalized.sourceID.isEmpty else { return }

        settings.siteRules.removeAll { $0.id == normalized.id }
        // 手工配过的输入框，学习记录就作废：否则再重复两次，自动学到的会把手工这条覆盖掉
        if let keyword = normalized.keyword {
            settings.learnCandidates.removeAll { $0.host == normalized.host && $0.keyword == keyword }
        }
        settings.siteRules.append(normalized)
        persist()
        syncFocusWatcher()
    }

    public func removeSiteRule(id: String) {
        let before = settings.siteRules.count
        settings.siteRules.removeAll { $0.id == id }
        guard settings.siteRules.count != before else { return }
        persist()
        syncFocusWatcher()
    }

    public func setSiteRuleSource(id: String, sourceID: String) {
        guard let index = settings.siteRules.firstIndex(where: { $0.id == id }) else { return }
        settings.siteRules[index].sourceID = sourceID
        // 用户亲手改过的就不再是「学出来的」：去掉标记，也就不会再被启动清理带走
        settings.siteRules[index].learned = nil
        settings.siteRules[index].createdAt = nil
        persist()
    }

    /// 关掉自动学习时顺手清空候选：留着不学也没用，重新打开时从头开始更符合直觉。
    /// 已经建好的规则不动——那是用户看得到的既有配置。
    public func setLearning(_ enabled: Bool) {
        settings.learningEnabled = enabled
        if !enabled {
            settings.learnCandidates.removeAll()
        }
        persist()
    }

    public func clearLearnCandidates() {
        guard !settings.learnCandidates.isEmpty else { return }
        settings.learnCandidates.removeAll()
        persist()
    }

    /// 这条规则最近一次命中是什么时候。nil = 从没命中过（重启后仍保留，不归零）。
    public func lastHit(ruleID: String) -> Date? {
        settings.siteRules.first { $0.id == ruleID }?.lastUsed
    }

    /// 记一次命中。写盘按小时节流：每进一次输入框就可能命中一次，
    /// 次次落盘没必要，而清理判定只看「两个月内有没有」。
    /// `internal` + `now` 参数是为了让测试能验证节流。
    func noteRuleHit(_ id: String, now: Date = Date()) {
        guard let index = settings.siteRules.firstIndex(where: { $0.id == id }) else { return }
        settings.siteRules[index].lastUsed = now
        if let lastHitPersistAt, now.timeIntervalSince(lastHitPersistAt) < 3600 { return }
        lastHitPersistAt = now
        persist()
    }

    /// 启动清理：自动学的规则两个月没再命中，多半是当时临时用的站点。
    /// 手工配的规则不动——那是用户自己写下来的配置。
    /// 启动时把自动规则的关键字按现行规则重算一遍，并合并重复。
    /// 老版本存的是整段 placeholder，产品名一改就多出一条同名规则。
    private func normalizeLearnedRules() {
        let before = settings.siteRules
        let candidatesBefore = settings.learnCandidates
        SiteRuleLearning.normalizeLearned(&settings.siteRules)
        SiteRuleLearning.normalizeCandidates(&settings.learnCandidates)
        SiteRuleLearning.dropCandidatesCoveredBy(settings.siteRules, &settings.learnCandidates)
        guard settings.siteRules != before || settings.learnCandidates != candidatesBefore else { return }
        persist()
        ActionLog.state("input.normalize",
                        "规则 \(before.count) -> \(settings.siteRules.count)，候选 \(candidatesBefore.count) -> \(settings.learnCandidates.count)")
    }

    private func pruneStaleRules() {
        let removed = SiteRuleLearning.pruneStale(&settings.siteRules)
        guard !removed.isEmpty else { return }
        persist()
        let names = removed.map { "\($0.host)›\($0.keyword ?? "整站")" }.joined(separator: ", ")
        ActionLog.state("input.prune", "\(removed.count) 条：\(names)")
        log.info("清理 \(removed.count) 条两个月没用过的自动规则")
    }

    /// 地址栏 / 网站规则都要靠轮询焦点，没配任何一条就一点开销都不产生。
    /// 不在这里判断辅助功能权限：用户可能开着设置页去授权，权限到手后应当立刻生效，
    /// 读不到时 `BrowserContextReader` 自己会快速返回 unknown。
    private func syncFocusWatcher() {
        let hasSiteRules = !settings.siteRules.isEmpty
        let shouldRun = settings.enabled && (settings.addressBarSourceID != nil || hasSiteRules)
        focusWatcher.needsHost = hasSiteRules
        if shouldRun {
            focusWatcher.onChange = { [weak self] context, key in
                self?.handleBrowserContext(context, key: key)
            }
            focusWatcher.start()
        } else {
            focusWatcher.stop()
            focusWatcher.onChange = nil
            inAddressBar = false
            suppressMemory = false
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

    // MARK: - 失效的输入源

    /// 对一次账：哪些配着的源现在已经不可用了。
    ///
    /// 只在三个时刻跑：启动、系统发「输入法启停变了」通知、迁移之后。
    /// 不定时扫——换输入法是低频动作，为此常驻计时器不值当。
    ///
    /// `sources` 只为测试留口子；正常调用走 TIS 的实际列表。
    public func refreshSourceAvailability(_ sources: [InputSourceInfo]? = nil) {
        let list = sources ?? catalog.all
        // 读不到列表（无图形会话、TIS 异常）时保持原判：把整份配置误判成失效，
        // 会让用户一点「迁移」就全改成同一个源，比不提示糟糕得多
        guard !list.isEmpty else { return }

        installedIDs = Set(list.map(\.id))
        cacheSourceNames(list)
        recomputeMissing()
    }

    /// 迁移：把指向旧源的所有配置一次换成新源。
    ///
    /// 不做自动匹配——「搜狗拼音卸载了该换成谁」只有用户知道。这里只负责
    /// 在用户选好之后把五处引用（App 规则 / 记忆 / 地址栏 / 网站规则 / 学习记录）改干净。
    @discardableResult
    public func migrateSource(from old: String, to new: String) -> MigrationSummary {
        guard old != new, installedIDs.contains(new) else { return .none }

        var apps = Set<String>()
        for (key, value) in settings.rules where value == old {
            settings.rules[key] = new
            apps.insert(key)
        }
        for (key, value) in settings.memory where value == old {
            settings.memory[key] = new
            apps.insert(key)
        }
        let addressBar = settings.addressBarSourceID == old
        if addressBar {
            settings.addressBarSourceID = new
        }
        var siteRules = 0
        for index in settings.siteRules.indices where settings.siteRules[index].sourceID == old {
            settings.siteRules[index].sourceID = new
            // 用户刚确认过这条配置还在乎，顺手刷新时间：否则旧源失效期间从没命中过，
            // 下次启动就会被「两个月没用」当临时站点清掉
            settings.siteRules[index].lastUsed = Date()
            siteRules += 1
        }
        var candidates = 0
        for index in settings.learnCandidates.indices where settings.learnCandidates[index].sourceID == old {
            settings.learnCandidates[index].sourceID = new
            candidates += 1
        }

        let summary = MigrationSummary(apps: apps.count,
                                       siteRules: siteRules,
                                       candidates: candidates,
                                       addressBar: addressBar)
        guard !summary.isEmpty else { return .none }

        // 两个源各自攒过同一个框的候选：迁移后变成重复项，合并成一条，次数取大的
        mergeDuplicateCandidates()
        persist()
        refreshSourceAvailability()
        ActionLog.state("input.migrate", "\(old) -> \(new)：\(summary.total) 处")
        log.info("迁移输入法配置：\(old, privacy: .public) -> \(new, privacy: .public)，\(summary.total) 处")
        return summary
    }

    /// 把「这个源叫什么」存一份。系统卸载后查不到名字，失效提示就只能显示 ID。
    private func cacheSourceNames(_ sources: [InputSourceInfo]) {
        var names = settings.sourceNames
        for source in sources {
            names[source.id] = source.name
        }
        // 只留还在用的和配置里引用到的。否则换个输入法装十次，这份缓存会一直变长
        let referenced = referencedSourceIDs()
        let kept = names.filter { installedIDs.contains($0.key) || referenced.contains($0.key) }
        guard kept != settings.sourceNames else { return }
        settings.sourceNames = kept
        persist()
    }

    private func referencedSourceIDs() -> Set<String> {
        var ids = Set(settings.rules.values)
        ids.formUnion(settings.memory.values)
        ids.formUnion(settings.siteRules.map(\.sourceID))
        ids.formUnion(settings.learnCandidates.map(\.sourceID))
        if let bar = settings.addressBarSourceID {
            ids.insert(bar)
        }
        return ids
    }

    private func recomputeMissing() {
        var appKeys: [String: Set<String>] = [:]
        for (key, value) in settings.rules where !installedIDs.contains(value) {
            appKeys[value, default: []].insert(key)
        }
        for (key, value) in settings.memory where !installedIDs.contains(value) {
            appKeys[value, default: []].insert(key)
        }

        var siteCounts: [String: Int] = [:]
        for rule in settings.siteRules where !installedIDs.contains(rule.sourceID) {
            siteCounts[rule.sourceID, default: 0] += 1
        }
        var candidateCounts: [String: Int] = [:]
        for candidate in settings.learnCandidates where !installedIDs.contains(candidate.sourceID) {
            candidateCounts[candidate.sourceID, default: 0] += 1
        }
        var bars = Set<String>()
        if let bar = settings.addressBarSourceID, !installedIDs.contains(bar) {
            bars.insert(bar)
        }

        let ids = Set(appKeys.keys)
            .union(siteCounts.keys)
            .union(candidateCounts.keys)
            .union(bars)

        missingSources = ids.map { id in
            MissingSource(sourceID: id,
                          name: sourceName(id: id) ?? id,
                          appCount: appKeys[id]?.count ?? 0,
                          siteRuleCount: siteCounts[id] ?? 0,
                          candidateCount: candidateCounts[id] ?? 0,
                          addressBar: bars.contains(id))
        }.sorted {
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func mergeDuplicateCandidates() {
        var merged: [SiteRuleCandidate] = []
        for candidate in settings.learnCandidates {
            if let index = merged.firstIndex(where: {
                $0.host == candidate.host && $0.keyword == candidate.keyword
            }) {
                merged[index].hits = max(merged[index].hits, candidate.hits)
                merged[index].lastSeen = max(merged[index].lastSeen, candidate.lastSeen)
            } else {
                merged.append(candidate)
            }
        }
        settings.learnCandidates = merged
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

        // 换了 App，地址栏 / 网站规则的状态作废；上一次还在等延迟的切换也作废
        inAddressBar = false
        suppressMemory = false
        pendingSwitch?.cancel()
        pendingSwitch = nil

        guard settings.enabled else { return }
        guard let target = InputSourceResolver.target(for: key, settings: settings) else { return }
        applyTarget(target, key: key, appName: app.name ?? key)
    }

    /// 浏览器上下文变了：进/出地址栏、点到某个输入框、切到一个网站。
    ///
    /// 只在「上下文变了」时动一次，不做持续强切：用户可能为了搜中文内容手动换回中文，
    /// 一直按回去就没法用了。
    private func handleBrowserContext(_ context: BrowserContext, key: String) {
        // key 为空 = 前台已经不是（受支持的）浏览器，切源交给 handleFrontApp
        guard !key.isEmpty else {
            inAddressBar = false
            // 这里不能清 suppressMemory：切走 App 时 watcher 会先报一次「不是浏览器」，
            // 紧接着 handleFrontApp 才去记上一个 App 的记忆。提前清掉，网站规则定下的源
            // 就会被当成用户的习惯写进记忆（实测把 Chrome 的记忆写成了中文输入法）。
            return
        }

        let inBar = context.kind == .addressBar
        let site = inBar
            ? nil
            : SiteRuleMatcher.match(host: context.host, label: context.label, rules: settings.siteRules)
        inAddressBar = inBar
        suppressMemory = inBar || site != nil

        pendingSwitch?.cancel()
        pendingSwitch = nil

        guard settings.enabled else { return }
        guard let target = InputSourceResolver.target(for: key,
                                                      settings: settings,
                                                      inAddressBar: inBar,
                                                      host: context.host,
                                                      fieldLabel: context.label) else {
            return
        }
        ActionLog.state("input.ctx",
                        "kind=\(context.kind) host=\(context.host ?? "-") "
                        + "label=\(String((context.label ?? "-").prefix(24))) "
                        + "target=\(target) suppress=\(suppressMemory)")
        if let site, site.sourceID == target {
            noteRuleHit(site.id)
        }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? key
        // 不等延迟：延迟是为了躲 App 激活时吞首字符，而这里是同一进程内的焦点移动，
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
        ActionLog.state("input.switch", "\(catalog.currentID ?? "-") -> \(target) (\(appName))")
        // 通知分不清是谁换的源，先登记一下，紧接着到达的那条通知就不算用户意图
        lastSelfSwitchAt = Date()
        if catalog.select(id: target) {
            log.debug("切到 \(target, privacy: .public)（\(appName, privacy: .public)）")
        } else {
            log.error("切换输入源失败：\(target, privacy: .public)")
        }
    }

    /// 换源通知：可能是用户按了 ⌃Space 或点菜单，也可能是 Baton 自己刚切的。
    ///
    /// 只按时间去重、不看当前源：`TISSelectInputSource` 的通知有可能早于当前源生效，
    /// 那时拿 `currentID` 比会认成「用户切了」，把切换前的旧源当成偏好学进去。
    private func handleSelectedSourceChanged() {
        if let lastSelfSwitchAt, Date().timeIntervalSince(lastSelfSwitchAt) < 0.6 {
            return
        }
        rememberCurrentSource()
        learnFromField()
    }

    // MARK: - 自动学习

    /// 用户手动换源后，看一眼焦点是不是落在网页输入框里。是就记一次。
    ///
    /// 这里不靠 `BrowserFocusWatcher`：那个表只有在配了地址栏或网站规则时才跑，
    /// 而学习要在「什么规则都没有」时也能工作。换成在换源这一瞬间读一次，
    /// 每次成本约 1ms，且跑在后台队列，比常驻 120ms 轮询省得多。
    private func learnFromField() {
        guard settings.enabled, settings.learningEnabled else { return }
        // 地址栏的源是「敲网址」的临时状态，不该学成这个网站的偏好
        guard !inAddressBar else { return }
        guard let source = catalog.currentID else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular,
              BrowserContextReader.isSupported(app.bundleIdentifier) else {
            return
        }
        let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        guard !settings.ignored.contains(key) else { return }

        let pid = app.processIdentifier
        learnQueue.async { [weak self] in
            let context = BrowserContextReader.read(pid: pid, needHost: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // 读的过程中切走了 App，这份上下文不是这个源的场景
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    self?.recordLearn(context: context, sourceID: source)
                }
            }
        }
    }

    /// 攒一次学习记录。`internal` 是为了让测试绕过 AX 直接喂上下文。
    func recordLearn(context: BrowserContext, sourceID: String, now: Date = Date()) {
        guard context.kind == .field,
              let host = context.host,
              let keyword = SiteRuleLearning.keyword(from: context.label) else {
            return
        }

        // 同一条组合 1 秒内只算一次：Chrome 换源偶尔连发两条通知，
        // 人不可能在 1 秒内为了同一个框换两次源
        let id = "\(host)|\(keyword)|\(sourceID)"
        if let lastLearned, lastLearned.id == id, now.timeIntervalSince(lastLearned.at) < 1 {
            return
        }

        // 这个框已经有规则：手工配的是用户明确写下的配置，自动学习不去覆盖，
        // 也不为它攒候选（在两个源之间来回切时，规则会被学来学去地翻）。
        // 已经学出来的、源又一样，说明想要的结果早就在了，重复确认没有意义。
        // 判定用「同一个框」而不是字符串相等：手工规则存的是整段 placeholder，
        // 学出来的是它前半句，字符串永远对不上
        let newRule = SiteRule(host: host, keyword: keyword, sourceID: sourceID)
        if let existing = settings.siteRules.first(where: { SiteRuleMatcher.sameField($0, newRule) }),
           existing.learned != true || existing.sourceID == sourceID {
            return
        }

        lastLearned = (id, now)

        var candidates = settings.learnCandidates
        let rule = SiteRuleLearning.record(host: host,
                                          keyword: keyword,
                                          sourceID: sourceID,
                                          candidates: &candidates,
                                          now: now)
        settings.learnCandidates = candidates

        if var rule {
            rule.learned = true
            // 同一个输入框只留一条：之前手动配过的，这次也按最新学到的来。
            // 但创建时间沿用旧的——重复确认一次不该把 60 天清理的起算点往后推
            let previous = settings.siteRules.first { $0.id == rule.id }
            rule.createdAt = previous?.createdAt ?? now
            rule.lastUsed = now
            settings.siteRules.removeAll { $0.id == rule.id }
            settings.siteRules.append(rule)
            ActionLog.state("input.learn",
                            "\(rule.host) › \(rule.keyword ?? "整站") = \(sourceID)（第 \(SiteRuleLearning.threshold) 次）")
            log.info("学到网站规则：\(rule.host, privacy: .public) › \(rule.keyword ?? "-", privacy: .public)")
            persist()
            // 规则从无到有，轮询表得跟着起来，否则下次进这个框不会自动切
            syncFocusWatcher()
            return
        }
        persist()
    }

    private func rememberCurrentSource() {
        guard let key = lastKey else { return }
        rememberCurrentSource(for: key)
    }

    private func rememberCurrentSource(for key: String) {
        guard InputSourceResolver.shouldRemember(key, settings: settings) else { return }
        // 地址栏里用的是「敲网址的源」，网页规则里用的是「这个网站的源」，
        // 都不是这个 App 的习惯，记进去会把记忆搞脏
        guard !inAddressBar, !suppressMemory else { return }
        guard let current = catalog.currentID else { return }
        guard settings.memory[key] != current else { return }
        settings.memory[key] = current
        ActionLog.state("input.memory", "\(key)=\(current)")
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

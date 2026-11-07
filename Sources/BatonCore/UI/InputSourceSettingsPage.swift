import AppKit

/// 输入法设置页。
///
/// 交互照着 InputSourcePro 的思路：不「先添加再配置」，而是一个可搜索的 App 列表，
/// 找到谁就直接给谁选源。规则、忽略、记忆都在同一行里表达，不再分成两个列表来回找。
@MainActor
final class InputSourceSettingsPage: NSView, NSSearchFieldDelegate {
    var onChange: (() -> Void)?

    private weak var service: InputSourceService?

    private let enabledSwitch = NSSwitch()
    private let currentLabel = NSTextField(labelWithString: "—")
    private let delayPopup = NSPopUpButton()
    private let addressBarPopup = NSPopUpButton()
    private let memoryCountLabel = NSTextField(labelWithString: "")
    private let clearMemoryButton = NSButton(title: "清除…", target: nil, action: nil)

    private let searchField = NSSearchField()
    private let listNote = NSTextField(labelWithString: "")
    private let scopeButton = NSButton(title: "显示全部", target: nil, action: nil)
    private let appsStack = NSStackView()
    private var appsBox: SettingsListView!
    private var refreshTimer: Timer?

    private var showAll = false
    private var allRows: [InputSourceRowModel] = []

    /// 一次最多铺这么多行。装了两三百个 App，全量铺出来既慢也没人看；
    /// 搜索框才是找东西的正路。
    private static let renderLimit = 80
    private static let delayChoices = [0, 50, 100, 200]

    init(service: InputSourceService?) {
        self.service = service
        super.init(frame: .zero)
        build()
        // 冒烟用：BATON_PREFS_SEARCH=chrom 直接看过滤结果，省得 UI scripting 点输入框
        if let seed = ProcessInfo.processInfo.environment["BATON_PREFS_SEARCH"] {
            searchField.stringValue = seed
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 搭建

    private func build() {
        enabledSwitch.translatesAutoresizingMaskIntoConstraints = false
        enabledSwitch.widthAnchor.constraint(equalToConstant: 38).isActive = true
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledChanged)

        currentLabel.font = .systemFont(ofSize: 12)
        currentLabel.textColor = .secondaryLabelColor

        delayPopup.addItems(withTitles: ["立即", "50 毫秒", "100 毫秒", "200 毫秒"])
        delayPopup.font = .systemFont(ofSize: 12)
        delayPopup.target = self
        delayPopup.action = #selector(delayChanged)
        delayPopup.translatesAutoresizingMaskIntoConstraints = false
        delayPopup.widthAnchor.constraint(equalToConstant: 110).isActive = true

        addressBarPopup.font = .systemFont(ofSize: 12)
        addressBarPopup.target = self
        addressBarPopup.action = #selector(addressBarChanged)
        addressBarPopup.translatesAutoresizingMaskIntoConstraints = false
        addressBarPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        memoryCountLabel.font = .systemFont(ofSize: 11)
        memoryCountLabel.textColor = .secondaryLabelColor
        clearMemoryButton.bezelStyle = .rounded
        clearMemoryButton.controlSize = .small
        clearMemoryButton.target = self
        clearMemoryButton.action = #selector(clearMemory)

        searchField.placeholderString = "搜索应用名或 bundle id"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 210).isActive = true

        listNote.font = .systemFont(ofSize: 11)
        listNote.textColor = .secondaryLabelColor
        listNote.alignment = .right
        listNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scopeButton.bezelStyle = .rounded
        scopeButton.controlSize = .small
        scopeButton.target = self
        scopeButton.action = #selector(toggleScope)

        appsStack.orientation = .vertical
        appsStack.alignment = .leading
        appsStack.spacing = 2

        let appsBox = SettingsListView(height: 320, stack: appsStack)
        self.appsBox = appsBox

        let searchRow = NSStackView(views: [searchField, listNote, scopeButton])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 8
        searchRow.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 6, right: 0)

        SettingsLayout.install([
            SettingsLayout.section("状态", [
                SettingsLayout.row("按 App 记住输入法",
                                   detail: "切到别的 App 时自动换回上次用的输入法",
                                   control: enabledSwitch),
                SettingsLayout.row("当前输入法", control: currentLabel),
                SettingsLayout.row("切换延迟",
                                   detail: "切过去后等一下再换源；某些 App 会吞掉首字符，调大试试",
                                   control: delayPopup),
                SettingsLayout.row("浏览器地址栏",
                                   detail: "焦点进地址栏时换源，敲网址不用先经过中文候选",
                                   control: addressBarPopup),
                SettingsLayout.row("输入法记忆", control: memoryRow()),
            ]),
            SettingsLayout.section("应用", [
                searchRow,
                appsBox,
            ]),
        ], in: self)
    }

    private func memoryRow() -> NSStackView {
        memoryCountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [memoryCountLabel, clearMemoryButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    // MARK: - 刷新

    func reload() {
        let enabled = service?.isEnabled ?? false
        enabledSwitch.state = enabled ? .on : .off
        currentLabel.stringValue = service?.currentSourceName ?? "—"
        selectDelay(service?.switchDelayMs ?? 0)
        delayPopup.isEnabled = enabled
        fillAddressBarPopup()
        addressBarPopup.isEnabled = enabled

        let memoryCount = service?.memory.count ?? 0
        memoryCountLabel.stringValue = memoryCount == 0 ? "还没有记录" : "\(memoryCount) 个 App 记住了上次的输入法"
        clearMemoryButton.isEnabled = memoryCount > 0

        rebuildApps()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard window != nil else { return }
        // 当前输入源会随用户手动切换变化，窗口开着时轻轻轮询即可
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentLabel.stringValue = self.service?.currentSourceName ?? "—"
            }
        }
    }

    private func rebuildApps() {
        clear(appsStack)
        appsBox.setEmptyText(nil)

        guard let service else {
            appsBox.setEmptyText("输入法服务未启动")
            return
        }

        allRows = Self.makeRows(service: service)
        let keyword = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !keyword.isEmpty

        var pool = allRows
        if searching {
            pool = pool.filter {
                $0.name.localizedCaseInsensitiveContains(keyword)
                    || $0.bundleID.localizedCaseInsensitiveContains(keyword)
            }
        } else if !showAll {
            pool = pool.filter(\.isManaged)
        }

        let ordered = InputSourceRowModel.ordered(pool)
        let shown = ordered.prefix(Self.renderLimit)

        if shown.isEmpty {
            listNote.stringValue = ""
            appsBox.setEmptyText(searching
                ? "没有匹配「\(keyword)」的应用"
                : "还没有记录。切几个 App 就会自动出现在这里。")
            updateScopeButton(searching: searching)
            return
        }

        if ordered.count > shown.count {
            listNote.stringValue = "显示 \(shown.count)/\(ordered.count)，再输几个字缩小范围"
        } else {
            listNote.stringValue = searching ? "\(ordered.count) 个匹配" : "\(ordered.count) 个应用"
        }
        updateScopeButton(searching: searching)

        let sources = service.installedSources
        for row in shown {
            let view = InputSourceRuleRow(
                bundleID: row.bundleID,
                name: row.name,
                sourceID: row.ruleSourceID,
                isIgnored: row.isIgnored,
                memoryName: row.memorySourceID.flatMap { service.sourceName(id: $0) },
                hasConfig: row.hasAnyConfig,
                sources: sources
            )
            view.onSource = { [weak self] sourceID in
                service.setRule(bundleID: row.bundleID, sourceID: sourceID)
                self?.onChange?()
                DispatchQueue.main.async { self?.rebuildApps() }
            }
            view.onIgnore = { [weak self] ignored in
                service.setIgnored(row.bundleID, ignored)
                self?.onChange?()
                DispatchQueue.main.async { self?.rebuildApps() }
            }
            view.onRemove = { [weak self] in
                service.setRule(bundleID: row.bundleID, sourceID: nil)
                service.setIgnored(row.bundleID, false)
                service.removeMemory(row.bundleID)
                self?.onChange?()
                DispatchQueue.main.async { self?.reload() }
            }
            addRow(view, to: appsStack)
        }
    }

    /// 把「已安装的 App」和「配置/记忆里出现过的 App」并成一份。
    /// 后者可能已经卸载，但配置还在，得让人能看见并删掉。
    private static func makeRows(service: InputSourceService) -> [InputSourceRowModel] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var names: [String: String] = [:]

        for entry in InstalledAppCatalog.shared.all {
            names[entry.bundleID] = entry.name
        }
        let configured = Set(service.rules.keys)
            .union(service.ignoredApps)
            .union(service.memory.keys)
        for bundleID in configured where names[bundleID] == nil {
            names[bundleID] = InputSourceAppInfo.name(bundleID: bundleID)
        }

        return names.map { bundleID, name in
            InputSourceRowModel(
                bundleID: bundleID,
                name: name,
                ruleSourceID: service.rule(for: bundleID),
                isIgnored: service.isIgnored(bundleID),
                memorySourceID: service.memory[bundleID],
                isRunning: running.contains(bundleID)
            )
        }
    }

    private func updateScopeButton(searching: Bool) {
        scopeButton.isHidden = searching
        scopeButton.title = showAll
            ? "只看常用"
            : "显示全部（\(allRows.count)）"
    }

    private func addRow(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    /// 地址栏基本只该用能直接打英文的源，把这类排前面，省得在一堆中文输入法里翻。
    private func fillAddressBarPopup() {
        let sources = (service?.installedSources ?? []).sorted {
            if $0.isASCIICapable != $1.isASCIICapable { return $0.isASCIICapable }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let current = service?.addressBarSourceID

        addressBarPopup.removeAllItems()
        addressBarPopup.addItem(withTitle: "不处理")
        addressBarPopup.lastItem?.representedObject = nil
        for source in sources {
            addressBarPopup.addItem(withTitle: source.name)
            addressBarPopup.lastItem?.representedObject = source.id
        }

        if let current,
           let index = addressBarPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            addressBarPopup.selectItem(at: index)
        } else {
            // 配过的源被卸载了：显示「不处理」，但不清掉配置——装回来还能用
            addressBarPopup.selectItem(at: 0)
        }
    }

    private func selectDelay(_ ms: Int) {        if let index = Self.delayChoices.firstIndex(of: ms) {
            delayPopup.selectItem(at: index)
        } else {
            // 手改过 JSON 的值：选最接近的档，不把用户的选择悄悄改掉
            let nearest = Self.delayChoices.enumerated().min {
                abs($0.element - ms) < abs($1.element - ms)
            }?.offset ?? 0
            delayPopup.selectItem(at: nearest)
        }
    }

    // MARK: - 搜索

    func controlTextDidChange(_ obj: Notification) {
        rebuildApps()
    }

    // MARK: - 动作

    @objc private func enabledChanged() {
        service?.setEnabled(enabledSwitch.state == .on)
        reload()
        onChange?()
    }

    @objc private func delayChanged() {
        let index = delayPopup.indexOfSelectedItem
        guard index >= 0, index < Self.delayChoices.count else { return }
        service?.setSwitchDelay(Self.delayChoices[index])
        onChange?()
    }

    @objc private func addressBarChanged() {
        service?.setAddressBarSource(addressBarPopup.selectedItem?.representedObject as? String)
        onChange?()
    }

    @objc private func toggleScope() {        showAll.toggle()
        rebuildApps()
    }

    @objc private func clearMemory() {
        guard let service, !service.memory.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "清除所有输入法记忆？"
        alert.informativeText = "共 \(service.memory.count) 个 App。清除后它们会重新开始积累。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        service.clearMemory()
        reload()
        onChange?()
    }
}

// MARK: - 行模型

struct InputSourceRowModel: Equatable {
    let bundleID: String
    let name: String
    let ruleSourceID: String?
    let isIgnored: Bool
    let memorySourceID: String?
    let isRunning: Bool

    /// 有显式规则或勾了忽略，才算「配置过」
    var isConfigured: Bool { ruleSourceID != nil || isIgnored }
    /// 常用列表里要出现的：配置过、记住过、或者此刻正开着
    var isManaged: Bool { isConfigured || memorySourceID != nil || isRunning }
    var hasAnyConfig: Bool { isConfigured || memorySourceID != nil }

    /// 已配置 > 正在运行 > 记住过 > 其余，同组按名称。
    /// 这样「我明明设过」的 App 永远在前面，不用往下翻。
    static func ordered(_ rows: [InputSourceRowModel]) -> [InputSourceRowModel] {
        rows.sorted { lhs, rhs in
            if lhs.isConfigured != rhs.isConfigured { return lhs.isConfigured }
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            let leftMemory = lhs.memorySourceID != nil
            let rightMemory = rhs.memorySourceID != nil
            if leftMemory != rightMemory { return leftMemory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

// MARK: - 列表容器

/// 固定高度的滚动列表。设置页高度靠内容算，列表本身不能无限长，
/// 否则 App 一多整页就被撑出屏幕。
@MainActor
private final class SettingsListView: NSScrollView {
    private let stack: NSStackView
    private let listHeight: CGFloat
    private var emptyRow: NSView?

    init(height: CGFloat, stack: NSStackView) {
        self.stack = stack
        self.listHeight = height
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        documentView = doc

        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -6),
        ])

        wantsLayer = true
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 空态提示作为 stack 的一行、占满容器高度再居中。
    /// 直接浮在 NSScrollView 上会被 clip view 盖住，看不见。
    func setEmptyText(_ text: String?) {
        if let emptyRow {
            stack.removeArrangedSubview(emptyRow)
            emptyRow.removeFromSuperview()
            self.emptyRow = nil
        }
        guard let text, !text.isEmpty else { return }

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -8),
        ])

        stack.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.heightAnchor.constraint(equalToConstant: listHeight - 20),
        ])
        emptyRow = row
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 6
    }
}

/// NSScrollView 默认用非翻转坐标：内容从底部往上排，打开列表会停在末尾。
/// 列表要有「最新/最重要在顶部」的直觉，documentView 必须翻转。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 应用行

@MainActor
private final class InputSourceRuleRow: NSView {
    var onSource: ((String?) -> Void)?
    var onIgnore: ((Bool) -> Void)?
    var onRemove: (() -> Void)?

    private let popup = NSPopUpButton()
    private let ignoreCheck = NSButton(checkboxWithTitle: "忽略", target: nil, action: nil)
    private let configuredSourceID: String?

    init(bundleID: String,
         name: String,
         sourceID: String?,
         isIgnored: Bool,
         memoryName: String?,
         hasConfig: Bool,
         sources: [InputSourceInfo]) {
        self.configuredSourceID = sourceID
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        let icon = NSImageView()
        icon.image = AppIconProvider.shared.icon(bundleID: bundleID, appName: name, pointSize: 16)
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.toolTip = bundleID

        popup.font = .systemFont(ofSize: 12)
        popup.controlSize = .small
        // 第一项顺手告诉用户「这个 App 现在会用什么」：有记忆就显示记忆里的源
        popup.addItem(withTitle: memoryName.map { "记忆：\($0)" } ?? "按记忆")
        popup.lastItem?.representedObject = nil
        for source in sources {
            popup.addItem(withTitle: source.name)
            popup.lastItem?.representedObject = source.id
        }
        if let sourceID,
           let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == sourceID }) {
            popup.selectItem(at: index)
        } else {
            // 用标题选中而不是下标：NSPopUpButton 在「第一项 representedObject 为 nil」时
            // 有时会自己跳到下一个可选项，显式点名最稳
            popup.selectItem(withTitle: memoryName.map { "记忆：\($0)" } ?? "按记忆")
        }

        // 忽略时显示「不接管」而不是留着原规则：灰掉的 ABC 看着像还在生效
        popup.addItem(withTitle: "不接管")
        popup.lastItem?.isHidden = !isIgnored
        if isIgnored { popup.selectItem(withTitle: "不接管") }

        popup.target = self
        popup.action = #selector(sourceChanged)
        popup.isEnabled = !isIgnored
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 130).isActive = true

        ignoreCheck.font = .systemFont(ofSize: 11)
        ignoreCheck.state = isIgnored ? .on : .off
        ignoreCheck.target = self
        ignoreCheck.action = #selector(ignoreChanged)

        let remove = NSButton(image: NSImage(systemSymbolName: "xmark",
                                             accessibilityDescription: "移除")!,
                              target: self, action: #selector(removeTapped))
        remove.isBordered = false
        remove.imageScaling = .scaleProportionallyDown
        remove.toolTip = "移除这个 App 的规则和记忆"
        remove.isHidden = !hasConfig
        remove.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            remove.widthAnchor.constraint(equalToConstant: 18),
            remove.heightAnchor.constraint(equalToConstant: 18),
        ])

        let stack = NSStackView(views: [icon, nameLabel, popup, ignoreCheck, remove])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func sourceChanged() {
        onSource?(popup.selectedItem?.representedObject as? String)
    }

    @objc private func ignoreChanged() {
        let ignored = ignoreCheck.state == .on
        popup.isEnabled = !ignored
        popup.itemArray.last?.isHidden = !ignored
        if ignored {
            popup.selectItem(withTitle: "不接管")
        } else if let configuredSourceID,
                  let index = popup.itemArray.firstIndex(where: {
                      ($0.representedObject as? String) == configuredSourceID
                  }) {
            popup.selectItem(at: index)
        } else {
            popup.selectItem(at: 0)
        }
        onIgnore?(ignored)
    }

    @objc private func removeTapped() { onRemove?() }
}

// MARK: - App 名称

enum InputSourceAppInfo {
    /// bundle id 换成用户认得的名字。查不到就退回 id，至少不会显示空白。
    static func name(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

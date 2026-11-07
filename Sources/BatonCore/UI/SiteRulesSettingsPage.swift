import AppKit

/// 网站规则设置页。
///
/// 一条规则 = 域名 + 可选输入框关键字 + 输入法。关键字留空就是整站。
/// 添加走「采集」：点按钮后 8 秒内去浏览器点那个输入框，域名和 placeholder 自动填上，
/// 不用手抄无障碍文案（那个东西用户根本看不到）。
@MainActor
final class SiteRulesSettingsPage: NSView {
    var onChange: (() -> Void)?

    private weak var service: InputSourceService?

    private let countLabel = NSTextField(labelWithString: "")
    private let rulesStack = NSStackView()
    private var rulesBox: SettingsListView!
    private let captureButton = NSButton(title: "采集网站规则…", target: nil, action: nil)
    private let captureNote = NSTextField(labelWithString: "")
    private let learnCheck = NSSwitch()
    private let learnCountLabel = NSTextField(labelWithString: "")
    private let clearLearnButton = NSButton(title: "清空", target: nil, action: nil)

    private var captureTimer: Timer?
    private var captureDeadline: Date?
    /// 采集期间看到过的域名：没等到输入框时退化成整站规则
    private var captureHost: String?

    private var rows: [SiteRuleRow] = []
    private var hitTimer: Timer?
    /// 规则表的指纹（id + 源）。自动学习会在后台把规则加进来，靠它发现变化并重建列表
    private var rulesSignature = ""

    private static let captureSeconds: TimeInterval = 8

    init(service: InputSourceService?) {
        self.service = service
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 搭建

    private func build() {
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 2
        let rulesBox = SettingsListView(height: 250, stack: rulesStack)
        self.rulesBox = rulesBox

        captureButton.bezelStyle = .rounded
        captureButton.controlSize = .small
        captureButton.target = self
        captureButton.action = #selector(beginCapture)

        captureNote.font = .systemFont(ofSize: 11)
        captureNote.textColor = .secondaryLabelColor
        captureNote.lineBreakMode = .byWordWrapping
        captureNote.maximumNumberOfLines = 2
        captureNote.stringValue = "点按钮后 8 秒内切到浏览器，点一下要设置的输入框；停在页面正文就按整站设置。"

        let buttonRow = NSStackView(views: [captureButton, captureNote])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        learnCheck.translatesAutoresizingMaskIntoConstraints = false
        learnCheck.widthAnchor.constraint(equalToConstant: 38).isActive = true
        learnCheck.target = self
        learnCheck.action = #selector(learnChanged)

        learnCountLabel.font = .systemFont(ofSize: 11)
        learnCountLabel.textColor = .secondaryLabelColor
        learnCountLabel.lineBreakMode = .byTruncatingTail
        learnCountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        clearLearnButton.bezelStyle = .rounded
        clearLearnButton.controlSize = .small
        clearLearnButton.target = self
        clearLearnButton.action = #selector(clearLearn)

        let learnRow = NSStackView(views: [learnCountLabel, clearLearnButton])
        learnRow.orientation = .horizontal
        learnRow.alignment = .centerY
        learnRow.spacing = 8

        SettingsLayout.install([
            SettingsLayout.section("规则", [countRow(), rulesBox]),
            SettingsLayout.section("添加", [SettingsLayout.plain(buttonRow)]),
            SettingsLayout.section("自动学习", [
                SettingsLayout.row("自动学习输入框",
                                   detail: "同一网站的同一输入框，第二次用同一个输入法就自动建规则；学出来的规则 60 天没用过会在下次启动时清掉",
                                   control: learnCheck),
                SettingsLayout.row("学习中", control: learnRow),
            ]),
        ], in: self)
    }

    private func countRow() -> NSStackView {
        let stack = NSStackView(views: [countLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        return stack
    }

    // MARK: - 刷新

    func reload() {
        // 这一页也要判断「规则指向的源还在不在」，顺手对一次账
        service?.refreshSourceAvailability()
        rebuildRules()
        reloadLearning()
    }

    /// 只用来看「上次命中」在走。设置窗口关掉就停，不常驻。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hitTimer?.invalidate()
            hitTimer = nil
        } else if hitTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHits() }
            }
            RunLoop.main.add(timer, forMode: .common)
            hitTimer = timer
            // 窗口是复用的，重新打开时列表可能已经被后台学习改过了
            reload()
        }
    }

    private func refreshHits() {
        guard let service else { return }
        // 自动学习会在用户看不见的时候加规则，靠指纹发现变化把列表重建出来
        if Self.signature(of: service.siteRules) != rulesSignature {
            rebuildRules()
            reloadLearning()
            return
        }
        for row in rows {
            row.setLastHit(service.lastHit(ruleID: row.ruleID))
        }
        reloadLearning()
    }

    private static func signature(of rules: [SiteRule]) -> String {
        rules.map { "\($0.id)=\($0.sourceID)" }.sorted().joined(separator: ";")
    }

    private func reloadLearning() {
        guard let service else {
            learnCheck.state = .off
            learnCheck.isEnabled = false
            learnCountLabel.stringValue = "输入法服务未启动"
            clearLearnButton.isHidden = true
            return
        }
        learnCheck.isEnabled = true
        learnCheck.state = service.isLearningEnabled ? .on : .off

        let candidates = service.learnCandidates
        if !service.isLearningEnabled {
            learnCountLabel.stringValue = "已关闭，不再自动建规则"
        } else if candidates.isEmpty {
            learnCountLabel.stringValue = "还没有学习中的组合"
        } else {
            learnCountLabel.stringValue = "\(candidates.count) 条组合，各再重复一次就自动生效"
        }
        // 具体是哪几个框在攒次数：鼠标停一下能看到，不占版面
        learnCountLabel.toolTip = candidates.isEmpty ? nil : candidates.prefix(8).map {
            "\($0.host) › \($0.keyword) → \(service.sourceName(id: $0.sourceID) ?? $0.sourceID)（\($0.hits)/\(SiteRuleLearning.threshold)）"
        }.joined(separator: "\n")
        clearLearnButton.isHidden = candidates.isEmpty
    }

    private func rebuildRules() {
        clear(rulesStack)
        rulesBox?.setEmptyText(nil)
        rows.removeAll()

        guard let service else {
            countLabel.stringValue = "输入法服务未启动"
            rulesBox?.setEmptyText("输入法服务未启动")
            return
        }

        let rules = service.siteRules
        rulesSignature = Self.signature(of: rules)
        countLabel.stringValue = rules.isEmpty
            ? "还没有规则。同一个网站可以配多条：整站一条，某些输入框各一条。"
            : "\(rules.count) 条规则，越具体越优先（带关键字 > 整站，子域 = 主域）"
        captureButton.isEnabled = captureTimer == nil

        guard !rules.isEmpty else {
            rulesBox?.setEmptyText("点下面的「采集网站规则…」，8 秒内去浏览器点一下输入框。")
            return
        }

        let sources = service.installedSources
        for rule in rules.sorted(by: { ($0.host, $0.keyword ?? "") < ($1.host, $1.keyword ?? "") }) {
            let row = SiteRuleRow(rule: rule,
                                  sources: sources,
                                  missingName: service.isSourceAvailable(rule.sourceID)
                                      ? nil
                                      : (service.sourceName(id: rule.sourceID) ?? rule.sourceID))
            row.onSource = { [weak self] sourceID in
                service.setSiteRuleSource(id: rule.id, sourceID: sourceID)
                self?.onChange?()
            }
            row.onRemove = { [weak self] in
                service.removeSiteRule(id: rule.id)
                self?.reload()
                self?.onChange?()
            }
            addRow(row, to: rulesStack)
            rows.append(row)
        }
        refreshHits()
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

    // MARK: - 自动学习

    @objc private func learnChanged() {
        service?.setLearning(learnCheck.state == .on)
        reloadLearning()
        onChange?()
    }

    @objc private func clearLearn() {
        service?.clearLearnCandidates()
        reloadLearning()
        onChange?()
    }

    // MARK: - 采集

    @objc private func beginCapture() {
        guard service != nil, captureTimer == nil else { return }
        captureHost = nil
        captureDeadline = Date().addingTimeInterval(Self.captureSeconds)
        captureButton.isEnabled = false
        NSSound.beep()

        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
        updateCaptureNote()
    }

    private func captureTick() {
        guard let deadline = captureDeadline else { return }

        guard Date() < deadline else {
            let host = captureHost
            stopCapture()
            if let host {
                presentEditor(host: host, keyword: nil, capturedField: false)
            } else {
                captureNote.stringValue = "没读到网站。确认切到了 Chrome / Safari，并且窗口没被最小化。"
            }
            return
        }

        updateCaptureNote()

        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              BrowserContextReader.isSupported(front.bundleIdentifier) else {
            return
        }
        let context = BrowserContextReader.read(pid: front.processIdentifier, needHost: true)
        guard let host = context.host, !host.isEmpty else { return }

        switch context.kind {
        case .field:
            stopCapture()
            presentEditor(host: host, keyword: context.label, capturedField: true)
        case .page, .addressBar:
            captureHost = host
        case .unknown:
            break
        }
    }

    private func updateCaptureNote() {
        guard let deadline = captureDeadline else { return }
        let left = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
        captureNote.stringValue = "已开始采集：还剩 \(left) 秒，去浏览器点一下要设置的输入框…"
    }

    private func stopCapture() {
        captureTimer?.invalidate()
        captureTimer = nil
        captureDeadline = nil
        captureButton.isEnabled = true
    }

    // MARK: - 编辑对话框

    private func presentEditor(host: String, keyword: String?, capturedField: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        let alert = NSAlert()
        alert.messageText = capturedField ? "新增网站规则（已采集输入框）" : "新增网站规则（整站）"
        alert.informativeText = capturedField
            ? "关键字按「包含」匹配输入框文案，站点改文案后要回来改。留空则整站生效。"
            : "没等到输入框，按整站规则加。之后想限定到某个输入框，重新采集一次即可。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = makeEditorView(host: host, keyword: keyword)

        guard alert.runModal() == .alertFirstButtonReturn,
              let editor = alert.accessoryView as? SiteRuleEditorView else { return }
        guard let service else { return }

        service.addSiteRule(SiteRule(host: editor.host,
                                     keyword: editor.keyword,
                                     sourceID: editor.sourceID))
        reload()
        onChange?()
        captureNote.stringValue = "已添加 \(editor.host)\(editor.keyword.isEmpty ? "（整站）" : " › \(editor.keyword)")"
    }

    private func makeEditorView(host: String, keyword: String?) -> SiteRuleEditorView {
        SiteRuleEditorView(host: host,
                           keyword: keyword ?? "",
                           sources: service?.installedSources ?? [],
                           selected: service?.currentSourceID)
    }
}

// MARK: - 采集结果编辑

/// 三个字段的小面板：域名 / 输入框关键字 / 输入法。
/// 用固定坐标而不是 Auto Layout：`NSAlert.accessoryView` 只认 frame，约束容易算出 0 高。
@MainActor
private final class SiteRuleEditorView: NSView {
    let hostField = NSTextField()
    let keywordField = NSTextField()
    let sourcePopup = NSPopUpButton()

    var host: String { hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    var keyword: String { keywordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    var sourceID: String { (sourcePopup.selectedItem?.representedObject as? String) ?? "" }

    init(host: String, keyword: String, sources: [InputSourceInfo], selected: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 92))

        hostField.stringValue = host
        hostField.placeholderString = "github.com"
        keywordField.stringValue = keyword
        keywordField.placeholderString = "留空 = 整站"

        for source in sources {
            sourcePopup.addItem(withTitle: source.name)
            sourcePopup.lastItem?.representedObject = source.id
        }
        if let selected,
           let index = sourcePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected }) {
            sourcePopup.selectItem(at: index)
        }

        let rows: [(String, NSView)] = [
            ("域名", hostField),
            ("输入框关键字", keywordField),
            ("输入法", sourcePopup),
        ]
        for (offset, row) in rows.enumerated() {
            let top = CGFloat(92 - 26 - offset * 30)
            let label = NSTextField(labelWithString: row.0)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 0, y: top + 3, width: 84, height: 18)
            addSubview(label)

            let control = row.1
            control.frame = NSRect(x: 90, y: top, width: 250, height: 24)
            addSubview(control)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 一行规则

@MainActor
private final class SiteRuleRow: NSStackView {
    var onSource: ((String) -> Void)?
    var onRemove: (() -> Void)?

    let ruleID: String

    private let popup = NSPopUpButton()
    private let hitLabel = NSTextField(labelWithString: "")
    private let ruleSourceID: String

    init(rule: SiteRule, sources: [InputSourceInfo], missingName: String? = nil) {
        self.ruleID = rule.id
        self.ruleSourceID = rule.sourceID
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)

        let host = NSTextField(labelWithString: rule.host)
        host.font = .systemFont(ofSize: 12)
        host.lineBreakMode = .byTruncatingTail
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        host.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let scope = NSTextField(labelWithString: rule.isSiteWide ? "整站" : "含「\(rule.keyword ?? "")」")
        scope.font = .systemFont(ofSize: 11)
        scope.textColor = rule.isSiteWide ? .tertiaryLabelColor : .secondaryLabelColor
        scope.lineBreakMode = .byTruncatingTail
        scope.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scope.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        // 「上次命中」放这里：规则配好之后，用户唯一能确认它在工作的证据。
        // 固定宽度而不是跟着文案伸缩：每行字数不一样，一变就把右侧下拉框推得左右不齐
        hitLabel.font = .systemFont(ofSize: 10)
        hitLabel.alignment = .right
        hitLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hitLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        setLastHit(nil)

        popup.font = .systemFont(ofSize: 11)
        popup.controlSize = .small
        popup.target = self
        popup.action = #selector(sourceChanged)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 130).isActive = true

        for source in sources {
            popup.addItem(withTitle: source.name)
            popup.lastItem?.representedObject = source.id
        }
        if let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == rule.sourceID }) {
            popup.selectItem(at: index)
        } else {
            // 源被卸载了：显式说出来，别静默显示成别的输入法。名字可能很长，toolTip 里留全的
            popup.addItem(withTitle: "已卸载：\(missingName ?? "未知")")
            popup.lastItem?.representedObject = rule.sourceID
            popup.lastItem?.toolTip = "\(missingName ?? rule.sourceID) 已不在系统输入法列表里，这条规则暂时不生效"
            popup.selectItem(at: popup.numberOfItems - 1)
        }

        let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "删除")!,
                              target: nil, action: nil)
        remove.bezelStyle = .inline
        remove.isBordered = false
        remove.target = self
        remove.action = #selector(removeTapped)
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.widthAnchor.constraint(equalToConstant: 16).isActive = true

        // 域名和范围靠左，下拉框整列靠右：一屏十几条时，眼睛扫的是同一列的输入法名字。
        // 弹簧优先级压到最低，文案太长时先挤它，再截断域名
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        var line: [NSView] = [host, scope]

        // 「自动」标出这条不是手工配的：用户看到规则自己长出来时，得能一眼知道来由
        if rule.learned == true {
            let badge = NSTextField(labelWithString: "自动")
            badge.font = .systemFont(ofSize: 9)
            badge.textColor = .tertiaryLabelColor
            badge.toolTip = "Baton 学出来的：你在同一个输入框里两次用了这个输入法。删掉这行就不再自动切换"
            badge.setContentHuggingPriority(.required, for: .horizontal)
            line.append(badge)
        }

        line += [spacer, hitLabel, popup, remove]
        for view in line {
            addArrangedSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 只改文案，不重建视图：设置窗口开着时也能看到命中时间在走，而且不会把打开的下拉框顶掉。
    func setLastHit(_ date: Date?) {
        hitLabel.stringValue = Self.hitText(date)
        hitLabel.textColor = date == nil ? .tertiaryLabelColor : .secondaryLabelColor
        hitLabel.toolTip = date.map { "最近一次因为这条规则换了输入法：\(Self.stamp.string(from: $0))" }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func hitText(_ date: Date?) -> String {
        guard let date else { return "未命中过" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 45 { return "刚刚命中" }
        return Self.relative.localizedString(for: date, relativeTo: Date())
    }

    @objc private func sourceChanged() {
        guard let id = popup.selectedItem?.representedObject as? String,
              id != ruleSourceID else { return }
        onSource?(id)
    }

    @objc private func removeTapped() {
        onRemove?()
    }
}

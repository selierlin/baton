import AppKit
import UniformTypeIdentifiers

/// 滚动页：平滑滚动开关、每格距离、平滑度、强制平滑、排除的应用、现场诊断。
///
/// 原来这组控件挂在「通用」里，和登录项、截图、录制挤在一列，找一项要从头扫到尾。
/// 每个功能模块一页之后，进这一页看的就只是滚动。
@MainActor
final class ScrollSettingsPage: NSView {
    var onToggle: ((Bool) -> Void)?
    /// 拖动滑杆时回写「一格多少点 / 平滑度」
    var onTuning: ((Double, Double) -> Void)?
    /// 「我的鼠标没被识别」兜底开关
    var onForceMouseChange: ((Bool) -> Void)?
    /// 排除名单变化（bundle id 列表，已排序）
    var onExcludeChange: (([String]) -> Void)?
    /// 读当前值，用于页面刷新
    var settings: (() -> SmoothScrollSettings)?
    /// 最近一次滚动事件的处理结论，用于现场诊断
    var diagnostics: (() -> String?)?

    private let smoothSwitch = NSSwitch()
    private let forceMouseCheck = NSButton(checkboxWithTitle: "我的鼠标没被识别（强制平滑）",
                                           target: nil, action: nil)
    private let distanceSlider = NSSlider()
    private let durationSlider = NSSlider()
    private let distanceValue = NSTextField(labelWithString: "")
    private let durationValue = NSTextField(labelWithString: "")
    private let diagnosticLabel = NSTextField(labelWithString: "（滚一下滚轮，这里会显示判定结果）")
    private let addExcludeButton = NSButton(title: "添加应用…", target: nil, action: nil)
    private let excludeStack = NSStackView()
    private let excludeEmptyLabel = NSTextField(labelWithString: "还没有排除任何应用")
    private var diagnosticTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        smoothSwitch.translatesAutoresizingMaskIntoConstraints = false
        smoothSwitch.widthAnchor.constraint(equalToConstant: 38).isActive = true
        smoothSwitch.target = self
        smoothSwitch.action = #selector(smoothChanged)

        // 两颗滑杆：距离决定一格滚多远，平滑度决定尾巴多长（越大越飘）
        for slider in [distanceSlider, durationSlider] {
            slider.controlSize = .small
            slider.isContinuous = true
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
            slider.target = self
            slider.action = #selector(smoothTuned)
        }
        distanceSlider.minValue = 30
        distanceSlider.maxValue = 200
        durationSlider.minValue = 0.5
        durationSlider.maxValue = 5.0
        for label in [distanceValue, durationValue] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }

        forceMouseCheck.target = self
        forceMouseCheck.action = #selector(forceMouseChanged)
        forceMouseCheck.font = .systemFont(ofSize: 11)
        forceMouseCheck.translatesAutoresizingMaskIntoConstraints = false

        // 「滚一下看看」的现场诊断：不带这个，用户只能说「没效果」，没法定位是哪一环断的
        diagnosticLabel.font = .systemFont(ofSize: 11)
        diagnosticLabel.textColor = .secondaryLabelColor
        diagnosticLabel.lineBreakMode = .byTruncatingTail
        diagnosticLabel.translatesAutoresizingMaskIntoConstraints = false

        addExcludeButton.bezelStyle = .rounded
        addExcludeButton.controlSize = .small
        addExcludeButton.font = .systemFont(ofSize: 11)
        addExcludeButton.target = self
        addExcludeButton.action = #selector(addExcludedApp)
        addExcludeButton.translatesAutoresizingMaskIntoConstraints = false

        excludeStack.orientation = .vertical
        excludeStack.alignment = .leading
        excludeStack.spacing = 4
        excludeStack.translatesAutoresizingMaskIntoConstraints = false

        excludeEmptyLabel.font = .systemFont(ofSize: 11)
        excludeEmptyLabel.textColor = .tertiaryLabelColor
        excludeEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        SettingsLayout.install([
            SettingsLayout.section("滚动", [
                SettingsLayout.row("平滑滚动", detail: "只接管滚轮，触控板保持系统手感",
                                   control: smoothSwitch),
                SettingsLayout.row("每格滚动", detail: "滚轮转一格走多远", control: trailing(distanceSlider, distanceValue)),
                SettingsLayout.row("平滑度", detail: "越大尾巴越长，越小越跟手", control: trailing(durationSlider, durationValue)),
                SettingsLayout.plain(forceMouseCheck),
                SettingsLayout.plain(diagnosticLabel),
            ]),
            SettingsLayout.section("排除的应用", [
                SettingsLayout.row("这些 App 不接管", detail: "保持系统原始滚轮，适合游戏、远程桌面、画布类工具",
                                   control: addExcludeButton),
                SettingsLayout.plain(excludeEmptyLabel),
                SettingsLayout.plain(excludeStack),
            ]),
        ], in: self)
    }

    func reload(enabled: Bool) {
        smoothSwitch.state = enabled ? .on : .off
        if let settings = settings?() {
            distanceSlider.doubleValue = settings.pointsPerTick
            durationSlider.doubleValue = settings.duration
            forceMouseCheck.state = settings.forceMouse ? .on : .off
            rebuildExcludedApps(settings.excludedApps)
        }
        updateTuning()
        refreshDiagnostics()
    }

    private func rebuildExcludedApps(_ bundleIDs: [String]) {
        clear(excludeStack)
        excludeEmptyLabel.isHidden = !bundleIDs.isEmpty
        for bundleID in bundleIDs {
            let row = ExcludedAppRow(bundleID: bundleID, name: Self.displayName(for: bundleID))
            row.onRemove = { [weak self] in self?.removeExcludedApp(bundleID) }
            excludeStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: excludeStack.widthAnchor).isActive = true
        }
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private static func displayName(for bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName {
            return name
        }
        if let entry = InstalledAppCatalog.shared.all.first(where: { $0.bundleID == bundleID }) {
            return entry.name
        }
        return bundleID
    }

    private func removeExcludedApp(_ bundleID: String) {
        guard var list = settings?().excludedApps else { return }
        list.removeAll { $0 == bundleID }
        applyExcludedApps(list)
    }

    private func applyExcludedApps(_ list: [String]) {
        let sorted = Array(Set(list)).sorted()
        onExcludeChange?(sorted)
        rebuildExcludedApps(sorted)
    }

    @objc private func addExcludedApp() {
        // 运行中的 App 直接点，省去翻「应用程序」；不在列表里的再走文件选择
        let menu = NSMenu()
        let excluded = Set(settings?().excludedApps ?? [])
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { ($0.bundleIdentifier.map { !excluded.contains($0) } ?? false) }
            .sorted {
                ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
            }
        for app in running {
            guard let bundleID = app.bundleIdentifier else { continue }
            let item = NSMenuItem(title: app.localizedName ?? bundleID, action: #selector(pickExcludedFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bundleID
            menu.addItem(item)
        }
        if !running.isEmpty { menu.addItem(.separator()) }
        let browse = NSMenuItem(title: "选择应用程序…", action: #selector(browseExcludedApp), keyEquivalent: "")
        browse.target = self
        menu.addItem(browse)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: addExcludeButton.bounds.height + 4),
                   in: addExcludeButton)
    }

    @objc private func pickExcludedFromMenu(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        addExcluded(bundleID)
    }

    @objc private func browseExcludedApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "排除"
        panel.message = "选择不做平滑滚动的应用"
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !ids.isEmpty else { return }
        addExcluded(contentsOf: ids)
    }

    private func addExcluded(_ bundleID: String) { addExcluded(contentsOf: [bundleID]) }

    private func addExcluded(contentsOf bundleIDs: [String]) {
        guard var list = settings?().excludedApps else { return }
        list.append(contentsOf: bundleIDs)
        applyExcludedApps(list)
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
        let text = diagnostics?() ?? nil
        diagnosticLabel.stringValue = text ?? "（滚一下滚轮，这里会显示判定结果）"
        diagnosticLabel.textColor = (text?.hasPrefix("已接管") ?? false) ? .secondaryLabelColor : .systemOrange
    }

    private func updateTuning() {
        distanceValue.stringValue = String(format: "%.0f 点/格", distanceSlider.doubleValue)
        durationValue.stringValue = String(format: "%.1f 档", durationSlider.doubleValue)
        let enabled = smoothSwitch.state == .on
        distanceSlider.isEnabled = enabled
        durationSlider.isEnabled = enabled
        forceMouseCheck.isEnabled = enabled
        addExcludeButton.isEnabled = enabled
        excludeStack.isHidden = !enabled
        excludeEmptyLabel.isHidden = !enabled || !(settings?().excludedApps.isEmpty ?? true)
    }

    private func trailing(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    @objc private func smoothTuned() {
        updateTuning()
        onTuning?(distanceSlider.doubleValue, durationSlider.doubleValue)
    }

    @objc private func smoothChanged() {
        updateTuning()
        onToggle?(smoothSwitch.state == .on)
    }

    @objc private func forceMouseChanged() {
        onForceMouseChange?(forceMouseCheck.state == .on)
    }
}

/// 排除名单的一行：App 名 + bundle id + 移除按钮。
@MainActor
private final class ExcludedAppRow: NSView {
    var onRemove: (() -> Void)?

    init(bundleID: String, name: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.lineBreakMode = .byTruncatingTail

        let idLabel = NSTextField(labelWithString: bundleID)
        idLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        idLabel.textColor = .tertiaryLabelColor
        idLabel.lineBreakMode = .byTruncatingTail
        idLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let remove = NSButton(title: "移除", target: self, action: #selector(removeTapped))
        remove.isBordered = false
        remove.controlSize = .small
        remove.contentTintColor = .secondaryLabelColor
        remove.font = .systemFont(ofSize: 11)
        remove.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [nameLabel, idLabel, remove])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func removeTapped() { onRemove?() }
}

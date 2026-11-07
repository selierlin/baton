import AppKit
import Carbon.HIToolbox

/// 滚动视图的文档视图要翻过来，否则内容从底部开始排。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 热键页：一行一个动作，点右侧按钮后按下新组合即可改；右边的 ✕ 取消绑定。
///
/// 只写 `hotkeys.json` 里的覆盖项，默认值仍留在 `HotkeyAction` 里；
/// 取消绑定的动作留在 `disabled` 里：功能还在菜单里，只是不占全局快捷键。
/// 改完立刻回调，让 AppShell 重新注册（Carbon 必须先注销再注册）。
@MainActor
final class HotkeySettingsPage: NSView {
    var onChange: (() -> Void)?

    private static let hintText = "点快捷键后按下新组合 · Delete 恢复默认 · Esc 取消 · ✕ 取消绑定"

    private let store = try? HotkeySettingsStore()
    private var settings = HotkeySettings.default
    private var recorders: [HotkeyAction: HotkeyRecorder] = [:]
    private var toggles: [HotkeyAction: NSButton] = [:]
    private let hint = NSTextField(labelWithString: hintText)
    private let restoreAllButton = NSButton(title: "恢复默认…", target: nil, action: nil)
    /// 常驻的校验结果（重复 / 撞系统快捷键）。和 `hint` 分开，免得「已生效」把告警冲掉。
    private let warning = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        var rows: [NSView] = []
        for action in HotkeyAction.allCases {
            let recorder = HotkeyRecorder(combo: action.defaultCombo)
            recorder.onCommit = { [weak self] combo in self?.commit(combo, for: action) }
            recorder.onReset = { [weak self] in self?.reset(action) }
            recorders[action] = recorder

            let toggle = NSButton(title: "", target: nil, action: nil)
            toggle.bezelStyle = .inline
            toggle.isBordered = false
            toggle.imagePosition = .imageOnly
            toggle.target = self
            toggle.tag = HotkeyAction.allCases.firstIndex(of: action) ?? 0
            toggle.action = #selector(toggleBinding(_:))
            toggle.translatesAutoresizingMaskIntoConstraints = false
            toggle.widthAnchor.constraint(equalToConstant: 16).isActive = true
            toggles[action] = toggle

            let control = NSStackView(views: [recorder, toggle])
            control.orientation = .horizontal
            control.alignment = .centerY
            control.spacing = 6

            rows.append(SettingsLayout.row(action.title, control: control))
        }

        let grid = SettingsLayout.section("快捷键", rows)

        restoreAllButton.bezelStyle = .rounded
        restoreAllButton.controlSize = .small
        restoreAllButton.target = self
        restoreAllButton.action = #selector(restoreAllTapped)
        let reset = SettingsLayout.section("重置", [
            SettingsLayout.row("全部恢复默认",
                               detail: "改过的组合回到默认值，取消绑定的也一起恢复",
                               control: restoreAllButton),
        ])

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .systemOrange
        warning.maximumNumberOfLines = 4
        warning.lineBreakMode = .byWordWrapping
        warning.preferredMaxLayoutWidth = 420
        warning.isHidden = true

        let stack = NSStackView(views: [grid, reset, hint, warning])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        reset.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 动作从 8 个涨到 13 个，固定高度装不下：套一层滚动视图，
        // 以后再加动作也不用再改窗口尺寸。
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SettingsLayout.margin),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -SettingsLayout.margin),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
    }

    func reload() {
        settings = store?.load() ?? .default
        for (action, recorder) in recorders {
            recorder.update(settings.combo(for: action), bound: settings.isEnabled(action))
        }
        for (action, toggle) in toggles {
            refreshToggle(toggle, for: action)
        }
        // 本来就是默认值时按了也没变化，直接置灰，省得用户点了以为没生效
        restoreAllButton.isEnabled = settings != .default
        refreshWarnings()
    }

    /// 一次把所有改过的组合清掉。会丢东西，所以先问一句——
    /// 点错一次就要重新录十几个键，代价比多一次确认高。
    @objc private func restoreAllTapped() {
        Task { @MainActor in
            let ok = await ModalAlert.confirm(
                title: "恢复所有热键？",
                message: "改过的组合会回到默认值，取消绑定的也会一起恢复。这一步不能撤销。",
                confirm: "恢复默认",
                name: "hotkey-reset",
                above: window
            )
            guard ok else { return }
            settings = .default
            persist("已恢复全部默认快捷键")
        }
    }

    /// 注册时也会做同一套检查（`AppShell.registerHotkeys`）；这里只是把结果摊在界面上。
    /// 取消绑定的不参与：它没注册，报「重复」只会让人以为还有键在抢
    private func refreshWarnings() {
        let actions = HotkeyAction.allCases
            .filter { settings.isEnabled($0) }
            .map { ($0.title, settings.combo(for: $0)) }
        let warnings = HotkeyAudit.warnings(actions: actions)
        warning.stringValue = warnings.joined(separator: "\n")
        warning.isHidden = warnings.isEmpty
    }

    @objc private func toggleBinding(_ sender: NSButton) {
        let actions = HotkeyAction.allCases
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        if settings.isEnabled(action) {
            settings.unbind(action)
            persist("已取消「\(action.title)」的快捷键，功能还在菜单里")
        } else {
            settings.restore(action)
            persist("已恢复「\(action.title)」：\(settings.combo(for: action).display)")
        }
    }

    private func refreshToggle(_ button: NSButton, for action: HotkeyAction) {
        let bound = settings.isEnabled(action)
        button.image = NSImage(systemSymbolName: bound ? "xmark" : "arrow.uturn.backward",
                               accessibilityDescription: bound ? "取消绑定" : "恢复绑定")
        button.contentTintColor = bound ? .secondaryLabelColor : .controlAccentColor
        button.toolTip = bound
            ? "取消绑定：不再占全局快捷键，功能仍在菜单里"
            : "恢复绑定（\(settings.combo(for: action).display)）"
    }

    private func commit(_ combo: KeyCombo, for action: HotkeyAction) {
        if let conflict = settings.conflict(of: combo, ignoring: action) {
            hint.stringValue = "\(combo.display) 已被「\(conflict.title)」占用"
            hint.textColor = .systemOrange
            recorders[action]?.update(settings.combo(for: action))
            return
        }
        settings.set(combo, for: action)
        persist()
    }

    private func reset(_ action: HotkeyAction) {
        settings.set(nil, for: action)
        persist()
    }

    private func persist(_ successNote: String? = nil) {
        guard let store else {
            hint.stringValue = "配置目录不可写"
            hint.textColor = .systemOrange
            return
        }
        do {
            try store.save(settings)
            hint.stringValue = successNote ?? "已生效"
            hint.textColor = .secondaryLabelColor
            reload()
            onChange?()
        } catch {
            hint.stringValue = "保存失败：\(error.localizedDescription)"
            hint.textColor = .systemOrange
        }
    }
}

/// 一个「按下快捷键」的录制按钮。录的时候独占键盘，Esc 取消、Delete 恢复默认。
@MainActor
private final class HotkeyRecorder: NSButton {
    var onCommit: ((KeyCombo) -> Void)?
    var onReset: (() -> Void)?

    private var combo: KeyCombo
    private var isRecording = false
    /// 取消绑定的动作：按钮还在（点一下就能录新组合），但显示「未启用」而不是一个假的键
    private var isBound = true

    init(combo: KeyCombo) {
        self.combo = combo
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self
        action = #selector(tapped)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 132).isActive = true
        update(combo, bound: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ combo: KeyCombo, bound: Bool = true) {
        self.combo = combo
        self.isBound = bound
        guard !isRecording else { return }
        show(bound ? combo.display : "未启用", dimmed: !bound)
        bezelColor = nil
    }

    /// NSButton 没有 textColor，改颜色只能走 attributedTitle
    private func show(_ text: String, dimmed: Bool) {
        title = text
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: dimmed ? NSColor.secondaryLabelColor : NSColor.controlTextColor,
        ])
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    override func resignFirstResponder() -> Bool {
        stop()
        return true
    }

    @objc private func tapped() {
        isRecording = true
        show("按下快捷键…", dimmed: false)
        bezelColor = .controlAccentColor
        window?.makeFirstResponder(self)
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        show(isBound ? combo.display : "未启用", dimmed: !isBound)
        bezelColor = nil
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            stop()
            return
        case kVK_Delete, kVK_ForwardDelete:
            stop()
            onReset?()
            return
        default:
            break
        }

        guard let combo = KeyCombo(event: event) else {
            // 只有字母没有修饰键：Carbon 会把打字吞掉，直接拒
            NSSound.beep()
            return
        }
        self.combo = combo
        stop()
        onCommit?(combo)
    }
}

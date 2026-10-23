import AppKit
import Carbon.HIToolbox

/// 滚动视图的文档视图要翻过来，否则内容从底部开始排。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 热键页：一行一个动作，点右侧按钮后按下新组合即可改。
///
/// 只写 `hotkeys.json` 里的覆盖项，默认值仍留在 `HotkeyAction` 里；
/// 改完立刻回调，让 AppShell 重新注册（Carbon 必须先注销再注册）。
@MainActor
final class HotkeySettingsPage: NSView {
    var onChange: (() -> Void)?

    private static let hintText = "点快捷键后按下新组合 · Delete 恢复默认 · Esc 取消"

    private let store = try? HotkeySettingsStore()
    private var settings = HotkeySettings.default
    private var recorders: [HotkeyAction: HotkeyRecorder] = [:]
    private let hint = NSTextField(labelWithString: hintText)
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
            rows.append(SettingsLayout.row(action.title, control: recorder))
        }

        let grid = SettingsLayout.section("快捷键", rows)

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .systemOrange
        warning.maximumNumberOfLines = 4
        warning.lineBreakMode = .byWordWrapping
        warning.preferredMaxLayoutWidth = 420
        warning.isHidden = true

        let stack = NSStackView(views: [grid, hint, warning])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

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
            recorder.update(settings.combo(for: action))
        }
        refreshWarnings()
    }

    /// 注册时也会做同一套检查（`AppShell.registerHotkeys`）；这里只是把结果摊在界面上。
    private func refreshWarnings() {
        let actions = HotkeyAction.allCases.map { ($0.title, settings.combo(for: $0)) }
        let warnings = HotkeyAudit.warnings(actions: actions)
        warning.stringValue = warnings.joined(separator: "\n")
        warning.isHidden = warnings.isEmpty
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

    private func persist() {
        guard let store else {
            hint.stringValue = "配置目录不可写"
            hint.textColor = .systemOrange
            return
        }
        do {
            try store.save(settings)
            hint.stringValue = "已生效"
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
        update(combo)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ combo: KeyCombo) {
        self.combo = combo
        guard !isRecording else { return }
        title = combo.display
        bezelColor = nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    override func resignFirstResponder() -> Bool {
        stop()
        return true
    }

    @objc private func tapped() {
        isRecording = true
        title = "按下快捷键…"
        bezelColor = .controlAccentColor
        window?.makeFirstResponder(self)
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        title = combo.display
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

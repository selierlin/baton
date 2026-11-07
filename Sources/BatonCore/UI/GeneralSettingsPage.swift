import AppKit

/// 通用页：登录项、平滑滚动、截图延迟、录制音轨、权限。
///
/// 从 `PreferencesWindowController.swift` 搬出来的：那个文件里挤了四个页面类，
/// 每加一组设置都在同一个文件里长，改一处要滚过另外三页。
@MainActor
final class GeneralSettingsPage: NSView {
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

// MARK: - 小工具

@MainActor
func row(_ views: NSView...) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.spacing = 8
    return stack
}

extension PermissionKind {
    var title: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .screenRecording: return "屏幕录制"
        case .listenEvent: return "输入监控"
        }
    }
}

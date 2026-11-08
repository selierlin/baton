import AppKit

/// 滚动页：平滑滚动开关、每行距离、尾巴时长、强制平滑、现场诊断。
///
/// 原来这组控件挂在「通用」里，和登录项、截图、录制挤在一列，找一项要从头扫到尾。
/// 每个功能模块一页之后，进这一页看的就只是滚动。
@MainActor
final class ScrollSettingsPage: NSView {
    var onToggle: ((Bool) -> Void)?
    /// 拖动滑杆时回写「每行多少点 / 平滑时长」
    var onTuning: ((Double, Double) -> Void)?
    /// 「我的鼠标没被识别」兜底开关
    var onForceMouseChange: ((Bool) -> Void)?
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

        forceMouseCheck.target = self
        forceMouseCheck.action = #selector(forceMouseChanged)
        forceMouseCheck.font = .systemFont(ofSize: 11)
        forceMouseCheck.translatesAutoresizingMaskIntoConstraints = false

        // 「滚一下看看」的现场诊断：不带这个，用户只能说「没效果」，没法定位是哪一环断的
        diagnosticLabel.font = .systemFont(ofSize: 11)
        diagnosticLabel.textColor = .secondaryLabelColor
        diagnosticLabel.lineBreakMode = .byTruncatingTail
        diagnosticLabel.translatesAutoresizingMaskIntoConstraints = false

        SettingsLayout.install([
            SettingsLayout.section("滚动", [
                SettingsLayout.row("平滑滚动", detail: "只接管滚轮，触控板保持系统手感",
                                   control: smoothSwitch),
                SettingsLayout.row("每行滚动", control: trailing(distanceSlider, distanceValue)),
                SettingsLayout.row("平滑时长", control: trailing(durationSlider, durationValue)),
                SettingsLayout.plain(forceMouseCheck),
                SettingsLayout.plain(diagnosticLabel),
            ]),
        ], in: self)
    }

    func reload(enabled: Bool) {
        smoothSwitch.state = enabled ? .on : .off
        if let settings = settings?() {
            distanceSlider.doubleValue = settings.pointsPerLine
            durationSlider.doubleValue = settings.duration
            forceMouseCheck.state = settings.forceMouse ? .on : .off
        }
        updateTuning()
        refreshDiagnostics()
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
        distanceValue.stringValue = String(format: "%.0f 点/行", distanceSlider.doubleValue)
        durationValue.stringValue = String(format: "%.2f 秒", durationSlider.doubleValue)
        let enabled = smoothSwitch.state == .on
        distanceSlider.isEnabled = enabled
        durationSlider.isEnabled = enabled
        forceMouseCheck.isEnabled = enabled
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

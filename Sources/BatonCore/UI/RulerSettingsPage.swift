import AppKit

/// 设置 → 测量：单位、取色格式、吸附、线色线宽。
///
/// 每一改都立刻落 `ruler.json` 并通知还开着的尺子（`RulerSettingsStore.addObserver`），
/// 不用「保存」按钮——这类纯显示偏好，多一步确认只是多一次点击。
@MainActor
final class RulerSettingsPage: NSView {
    var onChange: (() -> Void)?

    private let store: RulerSettingsStore

    private let unitPop = NSPopUpButton()
    private let colorPop = NSPopUpButton()
    private let snapSwitch = NSSwitch()
    private let accentPop = NSPopUpButton()
    private let widthSlider = NSSlider()
    private let widthValue = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")

    init(store: RulerSettingsStore) {
        self.store = store
        super.init(frame: .zero)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        let settings = store.settings
        unitPop.selectItem(at: RulerUnit.allCases.firstIndex(of: settings.unit) ?? 0)
        colorPop.selectItem(at: RulerColorFormat.allCases.firstIndex(of: settings.colorFormat) ?? 0)
        snapSwitch.state = settings.snapEnabled ? .on : .off
        accentPop.selectItem(at: RulerAccent.allCases.firstIndex(of: settings.accent) ?? 0)
        widthSlider.doubleValue = settings.lineWidth
        widthValue.stringValue = String(format: "%.1f pt", settings.lineWidth)
        refreshPreview()
    }

    private func build() {
        widthValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        widthValue.textColor = .secondaryLabelColor
        // 滑杆右边挂数值，省得用户去数刻度
        let widthRow = NSStackView(views: [widthSlider, widthValue])
        widthRow.orientation = .horizontal
        widthRow.spacing = 8
        widthRow.alignment = .centerY

        let grid = [
            SettingsLayout.row("读数单位", control: unitPop),
            SettingsLayout.row("取色格式", detail: "取色器复制到剪贴板的格式", control: colorPop),
            SettingsLayout.row("测量线颜色", control: accentPop),
            SettingsLayout.row("测量线宽", control: widthRow),
            SettingsLayout.row("边缘吸附", detail: "按住 ⌥ 临时关掉", control: snapSwitch),
        ]

        for unit in RulerUnit.allCases {
            unitPop.addItem(withTitle: unit.title)
        }
        for format in RulerColorFormat.allCases {
            colorPop.addItem(withTitle: format.title)
        }
        for accent in RulerAccent.allCases {
            accentPop.addItem(withTitle: accent.title)
        }
        unitPop.target = self
        unitPop.action = #selector(changed)
        colorPop.target = self
        colorPop.action = #selector(changed)
        accentPop.target = self
        accentPop.action = #selector(changed)
        snapSwitch.target = self
        snapSwitch.action = #selector(changed)
        snapSwitch.translatesAutoresizingMaskIntoConstraints = false
        snapSwitch.widthAnchor.constraint(equalToConstant: 38).isActive = true

        widthSlider.minValue = RulerSettings.minLineWidth
        widthSlider.maxValue = RulerSettings.maxLineWidth
        widthSlider.isContinuous = true
        widthSlider.controlSize = .small
        widthSlider.target = self
        widthSlider.action = #selector(changed)
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        preview.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        preview.textColor = .secondaryLabelColor

        let hint = NSTextField(labelWithString: "尺子里 1–4 切换测量方式：框选 / 水平 / 垂直 / 角度。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        SettingsLayout.install([
            SettingsLayout.section("显示", grid),
            SettingsLayout.plain(preview),
            SettingsLayout.plain(hint),
        ], in: self)
    }

    @objc private func changed() {
        let unit = RulerUnit.allCases[max(0, unitPop.indexOfSelectedItem)]
        let format = RulerColorFormat.allCases[max(0, colorPop.indexOfSelectedItem)]
        let accent = RulerAccent.allCases[max(0, accentPop.indexOfSelectedItem)]
        let snap = snapSwitch.state == .on

        store.update { settings in
            settings.unit = unit
            settings.colorFormat = format
            settings.accent = accent
            settings.snapEnabled = snap
            settings.lineWidth = widthSlider.doubleValue
        }
        widthValue.stringValue = String(format: "%.1f pt", store.settings.lineWidth)
        refreshPreview()
        onChange?()
    }

    /// 用一组固定的示例数字演示当前单位/格式长什么样，改完立刻能看见差别。
    private func refreshPreview() {
        let settings = store.settings
        let scale = CGSize(width: 2, height: 2)
        let size = RulerMetrics.sizeText(width: 800, height: 600, scale: scale, unit: settings.unit)
        let color = RulerMetrics.colorText(red: 0x3A, green: 0x7B, blue: 0xD5,
                                           format: settings.colorFormat)
        preview.stringValue = "示例（800×600 px @2x）：\(size)    取色：\(color)"
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.font = .systemFont(ofSize: 12)
        return label
    }
}

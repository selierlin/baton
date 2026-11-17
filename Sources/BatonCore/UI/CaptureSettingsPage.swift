import AppKit

/// 截图页：延迟截图的秒数、成品图带不带阴影。
///
/// 和滚动、录制一起躺在「通用」里时，用户想改倒计时得先知道它被归到「通用」——
/// 按模块分页后路径就直了。
@MainActor
final class CaptureSettingsPage: NSView {
    /// 延迟截图的默认秒数（1–60）
    var delaySeconds: (() -> Int)?
    var onDelayChange: ((Int) -> Void)?
    /// 成品图是否带阴影
    var addsShadow: (() -> Bool)?
    var onShadowToggle: ((Bool) -> Void)?

    private let delayPopup = NSPopUpButton()
    private let shadowSwitch = NSSwitch()

    private static let delayChoices = [3, 5, 10, 15]

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

        shadowSwitch.target = self
        shadowSwitch.action = #selector(shadowChanged)
        shadowSwitch.translatesAutoresizingMaskIntoConstraints = false
        shadowSwitch.widthAnchor.constraint(equalToConstant: 38).isActive = true

        SettingsLayout.install([
            SettingsLayout.section("截图", [
                SettingsLayout.row("延迟截图", detail: "按下热键后先等这么久，再出现框选",
                                   control: delayPopup),
                SettingsLayout.row("截图阴影", detail: "复制、保存的图四周留一圈透明边并投下阴影；OCR 与翻译不受影响",
                                   control: shadowSwitch),
                SettingsLayout.plain(SettingsLayout.note("区域、全屏、上次区域这些动作本身没有设置项，按哪个键在「热键」页里绑。")),
            ]),
        ], in: self)
    }

    func reload() {
        selectDelay(delaySeconds?() ?? 5)
        shadowSwitch.state = (addsShadow?() ?? true) ? .on : .off
    }

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

    @objc private func shadowChanged() {
        ActionLog.action("setting.capture.shadow", "on=\(shadowSwitch.state == .on)")
        onShadowToggle?(shadowSwitch.state == .on)
    }
}

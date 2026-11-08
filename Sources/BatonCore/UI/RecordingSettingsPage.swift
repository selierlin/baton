import AppKit

/// 录制页：录屏时带不带系统声音、带不带麦克风旁白。
@MainActor
final class RecordingSettingsPage: NSView {
    /// 录制时是否带系统声音
    var capturesAudio: (() -> Bool)?
    var onAudioToggle: ((Bool) -> Void)?
    /// 录制时是否带麦克风旁白
    var capturesMicrophone: (() -> Bool)?
    var onMicrophoneToggle: ((Bool) -> Void)?

    private let audioSwitch = NSSwitch()
    private let microphoneSwitch = NSSwitch()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        for control in [audioSwitch, microphoneSwitch] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 38).isActive = true
        }
        audioSwitch.target = self
        audioSwitch.action = #selector(audioChanged)
        microphoneSwitch.target = self
        microphoneSwitch.action = #selector(microphoneChanged)

        SettingsLayout.install([
            SettingsLayout.section("录制", [
                SettingsLayout.row("录制系统声音", detail: "录下 App 播放的声音（不含麦克风）",
                                   control: audioSwitch),
                SettingsLayout.row("录制麦克风旁白", detail: "第一次打开会请求麦克风权限",
                                   control: microphoneSwitch),
            ]),
        ], in: self)
    }

    func reload() {
        audioSwitch.state = (capturesAudio?() ?? true) ? .on : .off
        microphoneSwitch.state = (capturesMicrophone?() ?? false) ? .on : .off
    }

    @objc private func audioChanged() {
        ActionLog.action("setting.audio", "on=\(audioSwitch.state == .on)")
        onAudioToggle?(audioSwitch.state == .on)
    }

    @objc private func microphoneChanged() {
        ActionLog.action("setting.microphone", "on=\(microphoneSwitch.state == .on)")
        onMicrophoneToggle?(microphoneSwitch.state == .on)
    }
}

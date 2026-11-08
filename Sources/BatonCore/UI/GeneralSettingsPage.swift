import AppKit

/// 通用页：只放全局的东西——登录时启动、系统权限、版本与目录。
///
/// 滚动、截图、录制的设置各自独立成页，这里不再当杂物间。
@MainActor
final class GeneralSettingsPage: NSView {
    var onLoginToggle: ((Bool) -> Void)?

    private let loginSwitch = NSSwitch()
    private let versionLabel = NSTextField(labelWithString: "")
    private var permissionLabels: [PermissionKind: NSTextField] = [:]
    private var permissionButtons: [PermissionKind: NSButton] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        loginSwitch.translatesAutoresizingMaskIntoConstraints = false
        loginSwitch.widthAnchor.constraint(equalToConstant: 38).isActive = true
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged)

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

        SettingsLayout.install([
            SettingsLayout.section("常规", [
                SettingsLayout.row("登录时启动", control: loginSwitch),
            ]),
            SettingsLayout.section("权限", permissionRows),
            SettingsLayout.section("关于", aboutRows()),
        ], in: self)
    }

    /// 版本 + 两个目录入口。出问题时用户第一件事就是找这两处，别让他去翻菜单栏。
    private func aboutRows() -> [NSView] {
        versionLabel.stringValue = Self.versionText
        versionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor

        let folders = NSStackView(views: [
            smallButton("打开配置文件夹", action: #selector(openConfigFolder)),
            smallButton("打开日志文件夹", action: #selector(openLogFolder)),
        ])
        folders.orientation = .horizontal
        folders.spacing = 8

        return [
            SettingsLayout.row("版本", control: versionLabel),
            SettingsLayout.plain(folders),
        ]
    }

    private func smallButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        // 直接用 `.build/debug/BatonApp` 跑时没有 Info.plist，如实标 dev
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    @objc private func openConfigFolder() {
        open(configFolder, name: "config.open")
    }

    @objc private func openLogFolder() {
        open(ActionLog.shared.directory, name: "log.open")
    }

    private func open(_ url: URL, name: String) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        ActionLog.action(name, url.path)
        NSWorkspace.shared.open(url)
    }

    private var configFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Baton", isDirectory: true)
    }

    func reload(loginEnabled: Bool) {
        loginSwitch.state = loginEnabled ? .on : .off
        for (kind, label) in permissionLabels {
            let granted = PermissionCenter.status(kind) == .granted
            label.stringValue = granted ? "已授权" : "未授权"
            label.textColor = granted ? .secondaryLabelColor : .systemOrange
            permissionButtons[kind]?.isHidden = granted
        }
    }

    @objc private func loginChanged() { onLoginToggle?(loginSwitch.state == .on) }

    @objc private func requestPermission(_ sender: NSButton) {
        let kinds = PermissionKind.allCases
        guard sender.tag >= 0, sender.tag < kinds.count else { return }
        PermissionCenter.request(kinds[sender.tag])
        reload(loginEnabled: loginSwitch.state == .on)
    }
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

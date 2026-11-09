import AppKit

/// OCR 页：本机 Vision / 百度 / 腾讯。
///
/// 凭据行的标题和 Keychain 条目名来自 `OCRProviderConfig.Kind.credentials`，
/// 这里只管按 kind 决定显示哪几行，不再把「App ID」写死在控件上。
@MainActor
final class OCRSettingsPage: NSView {
    var onSave: (() -> Void)?

    private let enginePopup = NSPopUpButton()
    private let credentialStack = NSStackView()
    private var credentialRows: [SettingsRowView] = []
    /// 两种凭据的输入框：账号类非密、密钥类密文。切换引擎时换标签复用同一对控件。
    private let idField = NSTextField()
    private let secretField = NSSecureTextField()
    private let variantPopup = NSPopUpButton()
    private let testButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    private let store = try? OCRSettingsStore()
    private var settings: OCRSettings = .default

    private static let engines: [(id: String, title: String)] = [
        ("vision", "本机 Vision（免费、离线）"),
        ("baidu", "百度 OCR（需要密钥）"),
        ("tencent", "腾讯 OCR（需要密钥）"),
    ]
    private static let variants: [(String, String)] = [
        ("general", "通用（速度快）"),
        ("accurate_basic", "高精度（无坐标）"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var selectedKind: OCRProviderConfig.Kind {
        let id = enginePopup.selectedItem?.representedObject as? String
        return OCRProviderConfig.Kind(rawValue: id ?? "") ?? .vision
    }

    private func build() {
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        enginePopup.translatesAutoresizingMaskIntoConstraints = false
        enginePopup.widthAnchor.constraint(equalToConstant: 280).isActive = true

        for field in [idField, secretField] {
            field.font = .systemFont(ofSize: 12)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        secretField.placeholderString = "留空则不修改已保存的密钥"

        variantPopup.translatesAutoresizingMaskIntoConstraints = false
        variantPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        variantPopup.addItems(withTitles: Self.variants.map(\.1))

        credentialStack.orientation = .vertical
        credentialStack.alignment = .leading
        credentialStack.spacing = 2
        credentialStack.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        testButton.title = "测试连接"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testTapped)
        testButton.toolTip = "用一张现画的测试图识别一次，确认密钥和额度没问题"

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [save, testButton, statusLabel])
        footer.orientation = .horizontal
        footer.spacing = 12

        SettingsLayout.install([
            SettingsLayout.section("识别服务", [
                SettingsLayout.row("识别引擎", detail: "本机 Vision 免费离线，够日常用",
                                   control: enginePopup),
                credentialStack,
            ]),
            SettingsLayout.plain(footer),
        ], in: self)

        // 先按行数最多的百度占位：窗口高度是建窗时按 fittingSize 量的，
        // 这时还没读配置，空着会让「OCR」页按无凭据行的高度定死、底下被切掉。
        // 必须放在 install 之后——行宽约束要两边的公共祖先，早激活会抛异常。
        rebuildRows(for: .baidu)
    }

    func reload() {
        settings = store?.load() ?? .default
        enginePopup.removeAllItems()
        for (id, title) in Self.engines {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = id
            enginePopup.menu?.addItem(item)
        }

        let activeID = settings.activeID
        enginePopup.selectItem(at: Self.engines.firstIndex { $0.0 == activeID } ?? 0)
        variantPopup.selectItem(at: Self.variants.firstIndex {
            $0.0 == (settings.active?.variant ?? "general")
        } ?? 0)

        idField.stringValue = ""
        secretField.stringValue = ""
        idField.placeholderString = "留空则不修改"
        rebuildRows(for: selectedKind)
        fillAccountID()
        statusLabel.stringValue = ""
    }

    /// Vision 没有凭据行；百度多一行「接口变体」；腾讯只有两个凭据。
    private func rebuildRows(for kind: OCRProviderConfig.Kind) {
        for row in credentialRows {
            credentialStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        credentialRows.removeAll()

        guard let credentials = kind.credentials else { return }
        addRow(credentials.idLabel, control: idField)
        addRow(credentials.secretLabel, control: secretField)
        if kind.hasVariant {
            addRow("接口变体", detail: "高精度模式不返回文字坐标", control: variantPopup)
        }
    }

    private func addRow(_ title: String, detail: String? = nil, control: NSView) {
        let row = SettingsLayout.row(title, detail: detail, control: control)
        credentialStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: credentialStack.widthAnchor).isActive = true
        credentialRows.append(row)
    }

    /// 账号（App ID / SecretId）不是秘密，存在配置文件里，切引擎时回显当前已存的。
    private func fillAccountID() {
        idField.stringValue = settings.providers.first { $0.kind == selectedKind }?.accountID ?? ""
    }

    /// 界面上的值 → 配置。不落盘，保存和测试共用。
    private func currentConfig() -> OCRProviderConfig {
        let kind = selectedKind
        guard let credentials = kind.credentials else { return .vision }

        var config = settings.providers.first { $0.kind == kind }
            ?? OCRProviderConfig(id: kind.rawValue,
                                 displayName: kind.rawValue,
                                 kind: kind,
                                 apiKeyRef: credentials.idAccount,
                                 secretRef: credentials.secretAccount,
                                 languageType: kind == .baidu ? "CHN_ENG" : "auto")
        let typedID = idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedID.isEmpty { config.accountID = typedID }
        if kind.hasVariant {
            config.variant = Self.variants[variantPopup.indexOfSelectedItem].0
        }
        return config
    }

    /// 刚敲进来还没保存的密钥；空则返回 nil，退回读 Keychain。
    /// 账号单独取，允许只改账号或只改密钥。
    private var typedKey: String? {
        let key = secretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    // MARK: - 动作

    @objc private func engineChanged() {
        idField.stringValue = ""
        secretField.stringValue = ""
        rebuildRows(for: selectedKind)
        fillAccountID()
        statusLabel.stringValue = ""
    }

    @objc private func saveTapped() {
        let kind = selectedKind
        var providers = settings.providers
        if !providers.contains(where: { $0.kind == .vision }) {
            providers.insert(.vision, at: 0)
        }

        let config = currentConfig()

        if let credentials = kind.credentials {
            let alreadyConfigured = providers.contains { $0.kind == kind }
            // 账号存在配置文件里，可以直接看；密钥在 Keychain，只能看「有没有填新的」
            if config.accountID == nil && !alreadyConfigured {
                statusLabel.stringValue = "首次配置需要填 \(credentials.idLabel)"
                return
            }
            if let key = typedKey {
                do {
                    try KeychainStore.save(key, account: credentials.secretAccount)
                } catch {
                    statusLabel.stringValue = "密钥写入失败：\(error.localizedDescription)"
                    return
                }
            } else if !alreadyConfigured {
                statusLabel.stringValue = "首次配置需要填 \(credentials.secretLabel)"
                return
            }
        }

        providers = providers.filter { $0.kind != kind }
        providers.append(config)
        settings = OCRSettings(providers: providers, activeID: config.id)

        do {
            try store?.save(settings)
            onSave?()
            secretField.stringValue = ""
            fillAccountID()
            statusLabel.stringValue = "已保存"
        } catch {
            statusLabel.stringValue = "保存失败：\(error.localizedDescription)"
        }
    }

    @objc private func testTapped() {
        let config = currentConfig()
        let key = typedKey

        testButton.isEnabled = false
        statusLabel.stringValue = "测试中…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.testButton.isEnabled = true }
            do {
                let transport = try OCRTransportFactory.make(config, key: key)
                let result = try await transport.recognize(OCRRequest(image: try OCRSelfTest.image()))
                let plain = result.text.replacingOccurrences(of: "\n", with: " ")
                self.statusLabel.stringValue = result.isEmpty
                    ? "接口通了，但没识别出字"
                    : "连通 \(result.milliseconds)ms · \(plain.prefix(20))"
            } catch {
                self.statusLabel.stringValue = "失败：\(error.localizedDescription)"
            }
        }
    }
}

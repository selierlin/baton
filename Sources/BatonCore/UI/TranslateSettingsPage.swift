import AppKit

/// 翻译页：服务商、凭据、语言对、静默模式。
///
/// 服务商要填的项由 `ProviderConfig.Kind.fields` 声明，页面按声明渲染。
/// 之前是靠「把接口地址那行的标题临时改成 App ID」塞百度一家，
/// 再加腾讯（SecretId/SecretKey）之后这种补丁就撑不住了。
@MainActor
final class TranslateSettingsPage: NSView {
    var onSave: (() -> Void)?

    private let providerPopup = NSPopUpButton()
    private let credentialStack = NSStackView()
    private var credentialRows: [SettingsRowView] = []
    private var credentialFields: [ProviderField.Target: NSTextField] = [:]
    private let targetPopup = NSPopUpButton()
    private let sourcePopup = NSPopUpButton()
    private let silentSwitch = NSSwitch()
    private let testButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    private let store = try? TranslateSettingsStore()
    private var settings: TranslateSettings = .default

    /// 目标语言：BCP-47 + 中文名。源语言多一个「自动」。
    private static let languages = TranslateSettings.languages

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 当前选中的是哪一家：已保存过的以配置里的 kind 为准，没保存过的看预设。
    private var selectedKind: ProviderConfig.Kind {
        guard let id = providerPopup.selectedItem?.representedObject as? String else {
            return .openAICompatible
        }
        if let existing = settings.providers.first(where: { $0.id == id }) {
            return existing.kind
        }
        return ProviderPreset.all.first { $0.id == id }?.kind ?? .openAICompatible
    }

    private func build() {
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        credentialStack.orientation = .vertical
        credentialStack.alignment = .leading
        credentialStack.spacing = 2
        credentialStack.translatesAutoresizingMaskIntoConstraints = false

        targetPopup.addItems(withTitles: Self.languages.map(\.1))
        sourcePopup.addItem(withTitle: "自动检测")
        sourcePopup.addItems(withTitles: Self.languages.map(\.1))
        for popup in [providerPopup, targetPopup, sourcePopup] {
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }

        silentSwitch.translatesAutoresizingMaskIntoConstraints = false
        silentSwitch.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        testButton.title = "测试连接"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testTapped)
        testButton.toolTip = "用一句 hello 发一次真实请求，确认密钥和额度没问题"

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [save, testButton, statusLabel])
        footer.orientation = .horizontal
        footer.spacing = 12

        SettingsLayout.install([
            SettingsLayout.section("服务商", [
                SettingsLayout.row("服务商", control: providerPopup),
                credentialStack,
            ]),
            SettingsLayout.section("语言", [
                SettingsLayout.row("目标语言", control: targetPopup),
                SettingsLayout.row("源语言", control: sourcePopup),
                SettingsLayout.row("静默模式", detail: "翻完不弹原文，只把结果放进剪贴板",
                                   control: silentSwitch),
            ]),
            SettingsLayout.plain(footer),
        ], in: self)

        // 先按字段最多的那一类占位：窗口高度是建窗时按 fittingSize 量的，
        // 这时还没读配置，空着会让「翻译」页按无凭据行的高度定死、底下被切掉。
        // 必须放在 install 之后——行宽约束要两边的公共祖先，早激活会抛异常。
        rebuildRows(for: .openAICompatible)
    }

    func reload() {
        settings = store?.load() ?? .default
        providerPopup.removeAllItems()

        // 预设在前，用户自建的（id 不在预设里）追加在后面
        var entries: [(String, String)] = ProviderPreset.all.map { ($0.id, $0.displayName) }
        for provider in settings.providers where !entries.contains(where: { $0.0 == provider.id }) {
            entries.append((provider.id, provider.displayName))
        }
        for (id, name) in entries {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.representedObject = id
            providerPopup.menu?.addItem(item)
        }

        let activeID = settings.activeID
        if let index = entries.firstIndex(where: { $0.0 == activeID }) {
            providerPopup.selectItem(at: index)
        } else {
            providerPopup.selectItem(at: 0)
        }

        rebuildRows(for: selectedKind)
        fillValues(for: providerPopup.selectedItem?.representedObject as? String)

        targetPopup.selectItem(at: Self.languages.firstIndex { $0.0 == settings.targetLanguage } ?? 0)
        if let source = settings.sourceLanguage,
           let index = Self.languages.firstIndex(where: { $0.0 == source }) {
            sourcePopup.selectItem(at: index + 1)
        } else {
            sourcePopup.selectItem(at: 0)
        }
        silentSwitch.state = settings.silentMode ? .on : .off
        statusLabel.stringValue = ""
    }

    // MARK: - 字段

    /// 按服务商声明的字段重建右侧输入区。切服务商时整块换掉，
    /// 免得百度的「App ID」留到腾讯那页上。
    private func rebuildRows(for kind: ProviderConfig.Kind) {
        for row in credentialRows {
            credentialStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        credentialRows.removeAll()
        credentialFields.removeAll()

        for spec in kind.fields {
            let field: NSTextField = spec.isSecret ? NSSecureTextField() : NSTextField()
            field.font = .systemFont(ofSize: 12)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
            field.placeholderString = spec.placeholder

            let row = SettingsLayout.row(spec.label, detail: spec.detail, control: field)
            credentialStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: credentialStack.widthAnchor).isActive = true
            credentialRows.append(row)
            credentialFields[spec.target] = field
        }
    }

    private func fillValues(for id: String?) {
        guard let id else { return }
        for field in credentialFields.values { field.stringValue = "" }

        if let existing = settings.providers.first(where: { $0.id == id }) {
            credentialFields[.endpoint]?.stringValue = existing.baseURL?.absoluteString ?? ""
            credentialFields[.model]?.stringValue = existing.model
            credentialFields[.accountID]?.stringValue = existing.appID ?? ""
            // 不主动读 Keychain：查询会弹钥匙串授权框，而这里只需要一个提示
            credentialFields[.secret]?.placeholderString = "留空则不修改"
            return
        }
        guard let preset = ProviderPreset.all.first(where: { $0.id == id }) else { return }
        credentialFields[.endpoint]?.stringValue = preset.baseURL
        credentialFields[.model]?.stringValue = preset.model
    }

    /// 把界面上的值拼成配置。非法时顺手把原因写到状态栏并返回 nil。
    private func configFromFields() -> ProviderConfig? {
        guard let id = providerPopup.selectedItem?.representedObject as? String else { return nil }
        let kind = selectedKind
        let name = providerPopup.titleOfSelectedItem ?? id

        var config = settings.providers.first { $0.id == id }
            ?? ProviderConfig(id: id, displayName: name, kind: kind, apiKeyRef: "provider.\(id)")
        config.displayName = name
        config.kind = kind

        switch kind {
        case .openAICompatible, .proxy:
            let raw = (credentialFields[.endpoint]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: raw), url.scheme != nil, url.host != nil else {
                statusLabel.stringValue = "接口地址不是合法 URL"
                return nil
            }
            config.baseURL = url
            config.model = (credentialFields[.model]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespaces)
        case .baiduTranslate, .tencentTranslate:
            let raw = (credentialFields[.accountID]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else {
                statusLabel.stringValue = "请先填 \(kind.fields.first?.label ?? "账号")"
                return nil
            }
            config.appID = raw
            // 这两家按账号签名，没有接口地址和模型，清掉免得旧值带过去
            config.baseURL = nil
            config.model = ""
        }
        return config
    }

    private var typedSecret: String? {
        let raw = (credentialFields[.secret]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    // MARK: - 动作

    @objc private func providerChanged() {
        rebuildRows(for: selectedKind)
        fillValues(for: providerPopup.selectedItem?.representedObject as? String)
        statusLabel.stringValue = ""
    }

    @objc private func saveTapped() {
        guard let config = configFromFields() else { return }

        var providers = settings.providers.filter { $0.id != config.id }
        providers.append(config)
        settings.providers = providers
        settings.activeID = config.id
        settings.targetLanguage = Self.languages[targetPopup.indexOfSelectedItem].0
        settings.sourceLanguage = sourcePopup.indexOfSelectedItem > 0
            ? Self.languages[sourcePopup.indexOfSelectedItem - 1].0
            : nil
        settings.silentMode = silentSwitch.state == .on

        do {
            try store?.save(settings)
            if let key = typedSecret {
                try KeychainStore.save(key, account: config.apiKeyRef)
            }
            onSave?()
            reload()
            statusLabel.stringValue = "已保存"
        } catch {
            statusLabel.stringValue = "保存失败：\(error.localizedDescription)"
        }
    }

    @objc private func testTapped() {
        guard let config = configFromFields() else { return }
        let secret = typedSecret
        // 目标语言就是英语时，拿 hello 再译成英语看不出对错，改测中文
        let target = settings.targetLanguage == "en" ? "zh-Hans" : settings.targetLanguage

        testButton.isEnabled = false
        statusLabel.stringValue = "测试中…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.testButton.isEnabled = true }
            do {
                let provider = try TranslateProviderFactory.make(config, secret: secret)
                let started = Date()
                let result = try await provider.translate(
                    TranslateRequest(text: "hello", source: "en", target: target))
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let text = result.text.replacingOccurrences(of: "\n", with: " ")
                self.statusLabel.stringValue = "连通 \(ms)ms · \(text.prefix(28))"
            } catch {
                self.statusLabel.stringValue = "失败：\(error.localizedDescription)"
            }
        }
    }
}

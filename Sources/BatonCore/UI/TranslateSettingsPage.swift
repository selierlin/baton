import AppKit

/// 翻译页：服务商预设、接口地址、模型、密钥、语言对、静默模式。
@MainActor
final class TranslateSettingsPage: NSView {
    var onSave: (() -> Void)?

    private let providerPopup = NSPopUpButton()
    private let modelField = NSTextField()
    private let baseURLField = NSTextField()
    private let keyField = NSSecureTextField()
    /// 百度翻译没有接口地址，这一行的标题会变成 App ID
    private var endpointRow: SettingsRowView?
    private let targetPopup = NSPopUpButton()
    private let sourcePopup = NSPopUpButton()
    private let silentSwitch = NSSwitch()
    private let statusLabel = NSTextField(labelWithString: "")

    private let store = try? TranslateSettingsStore()
    private var settings: TranslateSettings = .default

    /// 百度翻译不用 baseURL，接口地址那一栏改成 App ID。
    private var selectedKind: ProviderConfig.Kind {
        let id = providerPopup.selectedItem?.representedObject as? String
        return settings.providers.first { $0.id == id }?.kind ?? .openAICompatible
    }

    /// 目标语言：BCP-47 + 中文名。源语言多一个「自动」。
    private static let languages = TranslateSettings.languages

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        targetPopup.addItems(withTitles: Self.languages.map(\.1))
        sourcePopup.addItem(withTitle: "自动检测")
        sourcePopup.addItems(withTitles: Self.languages.map(\.1))

        for field in [modelField, baseURLField, keyField] {
            field.font = .systemFont(ofSize: 12)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        for popup in [providerPopup, targetPopup, sourcePopup] {
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        silentSwitch.translatesAutoresizingMaskIntoConstraints = false
        silentSwitch.widthAnchor.constraint(equalToConstant: 38).isActive = true
        keyField.placeholderString = "留空则不修改已保存的密钥"

        let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let footer = NSStackView(views: [save, statusLabel])
        footer.orientation = .horizontal
        footer.spacing = 12

        let endpoint = SettingsLayout.row("接口地址", control: baseURLField)
        endpointRow = endpoint
        let model = SettingsLayout.row("模型", control: modelField)
        SettingsLayout.install([
            SettingsLayout.section("服务商", [
                SettingsLayout.row("服务商", control: providerPopup),
                endpoint,
                model,
                SettingsLayout.row("API Key", detail: "留空则不修改已保存的密钥", control: keyField),
            ]),
            SettingsLayout.section("语言", [
                SettingsLayout.row("目标语言", control: targetPopup),
                SettingsLayout.row("源语言", control: sourcePopup),
                SettingsLayout.row("静默模式", detail: "翻完不弹原文，只把结果放进剪贴板",
                                   control: silentSwitch),
            ]),
            SettingsLayout.plain(footer),
        ], in: self)
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

        fillFields(for: providerPopup.selectedItem?.representedObject as? String)
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

    private func fillFields(for id: String?) {
        guard let id else { return }
        if let existing = settings.providers.first(where: { $0.id == id }) {
            let isBaidu = existing.kind == .baiduTranslate
            endpointRow?.title = isBaidu ? "App ID" : "接口地址"
            // 百度翻译没有模型参数：置灰保留，比整行消失更不容易让人以为漏了配置
            modelField.placeholderString = isBaidu ? "百度翻译不用填" : ""
            modelField.isEnabled = !isBaidu
            modelField.stringValue = existing.model
            baseURLField.stringValue = isBaidu
                ? (existing.appID ?? "")
                : (existing.baseURL?.absoluteString ?? "")
            keyField.stringValue = ""
            // 不主动读 Keychain：查询会弹钥匙串授权框，而这里只需要一个提示
            keyField.placeholderString = "留空则不修改"
            return
        }
        guard let preset = ProviderPreset.all.first(where: { $0.id == id }) else { return }
        endpointRow?.title = "接口地址"
        modelField.placeholderString = ""
        modelField.isEnabled = true
        modelField.stringValue = preset.model
        baseURLField.stringValue = preset.baseURL
        keyField.stringValue = ""
        keyField.placeholderString = "留空则不修改"
    }

    @objc private func providerChanged() {
        fillFields(for: providerPopup.selectedItem?.representedObject as? String)
    }

    @objc private func saveTapped() {
        guard let id = providerPopup.selectedItem?.representedObject as? String else { return }
        let name = providerPopup.titleOfSelectedItem ?? id
        let isBaidu = selectedKind == .baiduTranslate
        let rawEndpoint = baseURLField.stringValue.trimmingCharacters(in: .whitespaces)

        let config: ProviderConfig
        if isBaidu {
            guard !rawEndpoint.isEmpty else {
                statusLabel.stringValue = "请先填 App ID"
                return
            }
            config = ProviderConfig(id: id,
                                    displayName: name,
                                    kind: .baiduTranslate,
                                    model: "",
                                    apiKeyRef: "provider.\(id)",
                                    appID: rawEndpoint)
        } else {
            guard let host = URL(string: rawEndpoint) else {
                statusLabel.stringValue = "接口地址不是合法 URL"
                return
            }
            config = ProviderConfig(id: id,
                                    displayName: name,
                                    baseURL: host,
                                    model: modelField.stringValue,
                                    apiKeyRef: "provider.\(id)")
        }

        var providers = settings.providers.filter { $0.id != id }
        providers.append(config)
        settings.providers = providers
        settings.activeID = id
        settings.targetLanguage = Self.languages[targetPopup.indexOfSelectedItem].0
        settings.sourceLanguage = sourcePopup.indexOfSelectedItem > 0
            ? Self.languages[sourcePopup.indexOfSelectedItem - 1].0
            : nil
        settings.silentMode = silentSwitch.state == .on

        do {
            try store?.save(settings)
            let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                try KeychainStore.save(key, account: config.apiKeyRef)
                keyField.stringValue = ""
            }
            statusLabel.stringValue = "已保存"
            onSave?()
            reload()
            statusLabel.stringValue = "已保存"
        } catch {
            statusLabel.stringValue = "保存失败：\(error.localizedDescription)"
        }
    }
}

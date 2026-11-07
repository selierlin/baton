import AppKit

/// OCR 页：本机 Vision 还是百度，百度要 App ID / 密钥和接口变体。
@MainActor
final class OCRSettingsPage: NSView {
    var onSave: (() -> Void)?

    private let enginePopup = NSPopUpButton()
    private let akField = NSTextField()
    private let skField = NSSecureTextField()
    private let variantPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")

    private let store = try? OCRSettingsStore()
    private var settings: OCRSettings = .default

    private static let engines: [(String, String)] = [
        ("vision", "本机 Vision（免费、离线）"),
        ("baidu", "百度 OCR（需要密钥）"),
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

    private func build() {
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)

        akField.font = .systemFont(ofSize: 12)
        skField.font = .systemFont(ofSize: 12)
        for field in [akField, skField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        for popup in [enginePopup, variantPopup] {
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        skField.placeholderString = "留空则不修改已保存的密钥"
        variantPopup.addItems(withTitles: Self.variants.map(\.1))

        let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let grid = [
            SettingsLayout.row("识别引擎", detail: "本机 Vision 免费离线，够日常用",
                               control: enginePopup),
            SettingsLayout.row("App ID", control: akField),
            SettingsLayout.row("密钥", control: skField),
            SettingsLayout.row("接口变体", detail: "高精度模式不返回文字坐标",
                               control: variantPopup),
        ]

        let footer = NSStackView(views: [save, statusLabel])
        footer.orientation = .horizontal
        footer.spacing = 12

        SettingsLayout.install([
            SettingsLayout.section("识别服务", grid),
            SettingsLayout.plain(footer),
        ], in: self)
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

        akField.stringValue = ""
        akField.placeholderString = "留空则不修改"
        skField.stringValue = ""
        statusLabel.stringValue = ""
        updateEnabled()
    }

    private func updateEnabled() {
        let isBaidu = (enginePopup.selectedItem?.representedObject as? String) == "baidu"
        akField.isEnabled = isBaidu
        skField.isEnabled = isBaidu
        variantPopup.isEnabled = isBaidu
    }

    @objc private func engineChanged() { updateEnabled() }

    @objc private func saveTapped() {
        let id = (enginePopup.selectedItem?.representedObject as? String) ?? "vision"

        if id == "vision" {
            settings = OCRSettings(providers: [.vision], activeID: "vision")
        } else {
            let ak = akField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let sk = skField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                if !ak.isEmpty {
                    try KeychainStore.save(ak, account: BaiduOCRCredentials.accessKeyAccount)
                }
                if !sk.isEmpty {
                    try KeychainStore.save(sk, account: BaiduOCRCredentials.secretKeyAccount)
                }
            } catch {
                statusLabel.stringValue = "密钥写入失败：\(error.localizedDescription)"
                return
            }
            var baidu = OCRProviderConfig.baidu
            baidu.variant = Self.variants[variantPopup.indexOfSelectedItem].0
            settings = OCRSettings(providers: [.vision, baidu], activeID: "baidu")
        }

        do {
            try store?.save(settings)
            statusLabel.stringValue = "已保存"
            onSave?()
        } catch {
            statusLabel.stringValue = "保存失败：\(error.localizedDescription)"
        }
    }
}

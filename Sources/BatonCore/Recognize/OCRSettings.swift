import Foundation

public struct OCRProviderConfig: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// 本机 Apple Vision，不花钱、不联网，但吃内存（见 v2.1 §6）。
        case vision
        /// 百度通用文字识别。
        case baidu
    }

    public var id: String
    public var displayName: String
    public var kind: Kind
    /// Keychain 里的 AK 名（百度）。
    public var apiKeyRef: String?
    /// Keychain 里的 SK 名（百度）。
    public var secretRef: String?
    /// 百度 `language_type`，默认中英混合。
    public var languageType: String?
    /// 百度接口变体：`general_basic` / `accurate_basic`。
    public var variant: String?

    public init(id: String,
                displayName: String,
                kind: Kind,
                apiKeyRef: String? = nil,
                secretRef: String? = nil,
                languageType: String? = nil,
                variant: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.apiKeyRef = apiKeyRef
        self.secretRef = secretRef
        self.languageType = languageType
        self.variant = variant
    }

    public static let vision = OCRProviderConfig(id: "vision",
                                                 displayName: "本机 Vision",
                                                 kind: .vision)

    public static let baidu = OCRProviderConfig(id: "baidu",
                                                displayName: "百度 OCR",
                                                kind: .baidu,
                                                apiKeyRef: BaiduOCRCredentials.accessKeyAccount,
                                                secretRef: BaiduOCRCredentials.secretKeyAccount,
                                                languageType: "CHN_ENG",
                                                variant: "general")
}

public struct OCRSettings: Codable, Sendable, Equatable {
    public var providers: [OCRProviderConfig]
    public var activeID: String

    public init(providers: [OCRProviderConfig] = [.vision], activeID: String = "vision") {
        self.providers = providers
        self.activeID = activeID
    }

    public var active: OCRProviderConfig? {
        providers.first { $0.id == activeID } ?? providers.first
    }

    public enum CodingKeys: String, CodingKey {
        case providers, activeID
    }

    private enum LegacyKeys: String, CodingKey {
        case provider
    }

    /// 兼容「只有一个 provider 字段」的旧写法。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try container.decodeIfPresent([OCRProviderConfig].self, forKey: .providers),
           !decoded.isEmpty {
            providers = decoded
            activeID = try container.decodeIfPresent(String.self, forKey: .activeID) ?? decoded[0].id
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let provider = try legacy.decode(OCRProviderConfig.self, forKey: .provider)
            providers = [provider]
            activeID = provider.id
        }
    }

    public static var `default`: OCRSettings { OCRSettings() }
}

public struct OCRSettingsStore: Sendable {
    public let url: URL

    public init(directory: URL? = nil) throws {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: true)
            dir = base.appendingPathComponent("Baton", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("ocr.json")
    }

    public func load() -> OCRSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(OCRSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: OCRSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

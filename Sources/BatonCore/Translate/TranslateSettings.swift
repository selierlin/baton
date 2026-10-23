import Foundation

public struct ProviderConfig: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// OpenAI `/chat/completions` 协议。DeepSeek / Kimi / 智谱 / 硅基流动 / Ollama 都是这一族。
        case openAICompatible
        /// 百度翻译开放平台（MD5 签名，不是 Bearer）。
        case baiduTranslate
        /// 自家授权网关。协议按 OpenAI 兼容处理，差别只在语义：
        /// 日后接入订阅制后端时，baseURL 指向自己的服务，key 换成授权 token。
        /// 单列出来是为了 UI 能把「内置」和「我的密钥」分开。
        case proxy
    }

    public var id: String
    public var displayName: String
    public var kind: Kind
    /// 到 `/v1` 为止（含或不含都行）。百度翻译不用这个字段。
    public var baseURL: URL?
    public var model: String
    /// Keychain 里的 account 名，**不存明文**。
    public var apiKeyRef: String
    /// 百度翻译需要 appid + 密钥两个值，appid 不是秘密，直接放配置。
    public var appID: String?
    public var promptOverride: String?

    public init(id: String,
                displayName: String,
                kind: Kind = .openAICompatible,
                baseURL: URL? = nil,
                model: String = "",
                apiKeyRef: String,
                appID: String? = nil,
                promptOverride: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.apiKeyRef = apiKeyRef
        self.appID = appID
        self.promptOverride = promptOverride
    }

    /// OpenAI 兼容族的请求地址。
    public var chatCompletionsURL: URL? {
        baseURL?.appendingPathComponent("chat/completions")
    }
}

/// 常见服务商预设：填 key 就能用。
public struct ProviderPreset: Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let baseURL: String
    public let model: String

    public static let all: [ProviderPreset] = [
        ProviderPreset(id: "deepseek", displayName: "DeepSeek",
                       baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        ProviderPreset(id: "openai", displayName: "OpenAI",
                       baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        ProviderPreset(id: "kimi", displayName: "Kimi / Moonshot",
                       baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k"),
        ProviderPreset(id: "zhipu", displayName: "智谱 GLM",
                       baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash"),
        ProviderPreset(id: "siliconflow", displayName: "硅基流动",
                       baseURL: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-7B-Instruct"),
        ProviderPreset(id: "ollama", displayName: "Ollama（本地）",
                       baseURL: "http://localhost:11434/v1", model: "qwen2.5"),
    ]

    public func config(apiKeyRef: String? = nil) -> ProviderConfig? {
        guard let url = URL(string: baseURL) else { return nil }
        return ProviderConfig(id: id,
                              displayName: displayName,
                              baseURL: url,
                              model: model,
                              apiKeyRef: apiKeyRef ?? "provider.\(id)")
    }
}

public struct TranslateSettings: Codable, Sendable, Equatable {
    public var providers: [ProviderConfig]
    /// 当前选中的 provider id。
    public var activeID: String
    /// BCP-47。默认译成简体中文。
    public var targetLanguage: String
    /// `nil` 表示让模型自己判断源语言。
    public var sourceLanguage: String?
    /// 静默模式：不弹结果窗，只把译文写进剪贴板。
    public var silentMode: Bool

    enum CodingKeys: String, CodingKey {
        case providers, activeID, targetLanguage, sourceLanguage, silentMode
    }

    private enum LegacyKeys: String, CodingKey {
        case provider
    }

    public init(providers: [ProviderConfig],
                activeID: String,
                targetLanguage: String = "zh-Hans",
                sourceLanguage: String? = nil,
                silentMode: Bool = false) {
        self.providers = providers
        self.activeID = activeID
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
        self.silentMode = silentMode
    }

    public var active: ProviderConfig? {
        providers.first { $0.id == activeID } ?? providers.first
    }

    /// 兼容旧版单 provider 配置（`{"provider": {...}}`）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try container.decodeIfPresent([ProviderConfig].self, forKey: .providers),
           !decoded.isEmpty {
            providers = decoded
            activeID = try container.decodeIfPresent(String.self, forKey: .activeID) ?? decoded[0].id
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let provider = try legacy.decode(ProviderConfig.self, forKey: .provider)
            providers = [provider]
            activeID = provider.id
        }
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "zh-Hans"
        sourceLanguage = try container.decodeIfPresent(String.self, forKey: .sourceLanguage)
        silentMode = try container.decodeIfPresent(Bool.self, forKey: .silentMode) ?? false
    }

    public static var `default`: TranslateSettings {
        guard let preset = ProviderPreset.all[0].config() else {
            return TranslateSettings(providers: [], activeID: "")
        }
        return TranslateSettings(providers: [preset], activeID: preset.id)
    }
}

public struct TranslateSettingsStore: Sendable {
    public let url: URL

    public init(directory: URL? = nil) throws {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            dir = base.appendingPathComponent("Baton", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("translate.json")
    }

    public func load() -> TranslateSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(TranslateSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: TranslateSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

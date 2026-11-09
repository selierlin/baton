import Foundation

/// 服务商要填的一项。设置页按这个列表渲染行，不再靠「改行标题」适配各家。
public struct ProviderField: Sendable, Equatable, Hashable {
    public enum Target: String, Sendable, Hashable {
        /// → `ProviderConfig.baseURL`
        case endpoint
        /// → `ProviderConfig.model`
        case model
        /// → `ProviderConfig.appID`。各家叫法不同（App ID / SecretId / 应用 ID），只存值。
        case accountID
        /// → Keychain，account = `apiKeyRef`
        case secret
    }

    public let target: Target
    public let label: String
    public let placeholder: String?
    public let detail: String?

    public init(target: Target, label: String, placeholder: String? = nil, detail: String? = nil) {
        self.target = target
        self.label = label
        self.placeholder = placeholder
        self.detail = detail
    }

    public var isSecret: Bool { target == .secret }
}

public struct ProviderConfig: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// OpenAI `/chat/completions` 协议。DeepSeek / Kimi / 智谱 / 硅基流动 / Ollama 都是这一族。
        case openAICompatible
        /// 百度翻译开放平台（MD5 签名，不是 Bearer）。
        case baiduTranslate
        /// 腾讯云机器翻译（TC3-HMAC-SHA256 签名，JSON 请求体）。
        case tencentTranslate
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

extension ProviderConfig.Kind {
    /// 这个服务商要填什么。加一家新服务商只在这里声明字段，
    /// 设置页的 `TranslateSettingsPage` 按列表渲染，不用为新服务商写 if。
    public var fields: [ProviderField] {
        switch self {
        case .openAICompatible, .proxy:
            return [
                ProviderField(target: .endpoint,
                              label: "接口地址",
                              placeholder: "https://api.deepseek.com/v1"),
                ProviderField(target: .model, label: "模型", placeholder: "deepseek-chat"),
                ProviderField(target: .secret, label: "API Key", placeholder: "留空则不修改已保存的密钥"),
            ]
        case .baiduTranslate:
            return [
                ProviderField(target: .accountID,
                              label: "App ID",
                              placeholder: "百度翻译开放平台的 appid"),
                ProviderField(target: .secret,
                              label: "密钥",
                              placeholder: "留空则不修改已保存的密钥",
                              detail: "百度用 appid + 密钥做 MD5 签名，不用 API Key"),
            ]
        case .tencentTranslate:
            return [
                ProviderField(target: .accountID,
                              label: "SecretId",
                              placeholder: "访问管理 → API 密钥"),
                ProviderField(target: .secret,
                              label: "SecretKey",
                              placeholder: "留空则不修改已保存的密钥",
                              detail: "腾讯云用 SecretId + SecretKey 做 TC3 签名"),
            ]
        }
    }
}

/// 常见服务商预设：填 key 就能用。
public struct ProviderPreset: Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let kind: ProviderConfig.Kind
    /// OpenAI 兼容族才用得上；按账号签名的服务商（百度、腾讯）留空。
    public let baseURL: String
    public let model: String

    public init(id: String,
                displayName: String,
                kind: ProviderConfig.Kind = .openAICompatible,
                baseURL: String = "",
                model: String = "") {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
    }

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
        // 按账号签名、没有接口地址和模型的两家，排在最后：多数人用不到
        ProviderPreset(id: "baidu", displayName: "百度翻译",
                       kind: .baiduTranslate),
        ProviderPreset(id: "tencent", displayName: "腾讯翻译",
                       kind: .tencentTranslate),
    ]

    public func config(apiKeyRef: String? = nil) -> ProviderConfig? {
        let ref = apiKeyRef ?? "provider.\(id)"
        switch kind {
        case .openAICompatible, .proxy:
            guard let url = URL(string: baseURL) else { return nil }
            return ProviderConfig(id: id,
                                  displayName: displayName,
                                  kind: kind,
                                  baseURL: url,
                                  model: model,
                                  apiKeyRef: ref)
        case .baiduTranslate, .tencentTranslate:
            return ProviderConfig(id: id,
                                  displayName: displayName,
                                  kind: kind,
                                  apiKeyRef: ref)
        }
    }
}

public struct TranslateSettings: Codable, Sendable, Equatable {
    /// BCP-47 与中文名。设置页的下拉框和结果浮窗的身份行共用这一份，
    /// 免得两边各写一张表、加语言时漏掉一处。
    public static let languages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁体中文"),
        ("en", "英语"),
        ("ja", "日语"),
    ]

    public static func languageName(for code: String) -> String {
        languages.first { $0.code == code }?.name ?? code
    }

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

import Foundation

/// 配置 → 实现。调用方只拿 `any TranslateProvider`，不关心是哪家。
public enum TranslateProviderFactory {
    /// `secret` 只在设置页「测试」时传：用户刚敲完密钥还没保存，不该为了试一次就写进 Keychain。
    /// 传 `nil` 表示从 Keychain 取。
    public static func make(_ config: ProviderConfig,
                            secret: String? = nil,
                            session: URLSession = .shared) throws -> any TranslateProvider {
        switch config.kind {
        case .openAICompatible, .proxy:
            // `proxy` 走自家网关时协议仍是 OpenAI 兼容，只是 baseURL 和 key 的语义不同。
            if let secret {
                return OpenAICompatibleProvider(config: config, apiKey: secret, session: session)
            }
            return try OpenAICompatibleProvider(config: config, session: session)
        case .baiduTranslate:
            if let secret {
                return try BaiduTranslateProvider(config: config, secretKey: secret, session: session)
            }
            return try BaiduTranslateProvider(config: config, session: session)
        case .tencentTranslate:
            if let secret {
                return try TencentTranslateProvider(config: config, secretKey: secret, session: session)
            }
            return try TencentTranslateProvider(config: config, session: session)
        }
    }
}

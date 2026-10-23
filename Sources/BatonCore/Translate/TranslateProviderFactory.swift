import Foundation

/// 配置 → 实现。调用方只拿 `any TranslateProvider`，不关心是哪家。
public enum TranslateProviderFactory {
    public static func make(_ config: ProviderConfig,
                            session: URLSession = .shared) throws -> any TranslateProvider {
        switch config.kind {
        case .openAICompatible, .proxy:
            // `proxy` 走自家网关时协议仍是 OpenAI 兼容，只是 baseURL 和 key 的语义不同。
            return try OpenAICompatibleProvider(config: config, session: session)
        case .baiduTranslate:
            return try BaiduTranslateProvider(config: config, session: session)
        }
    }
}

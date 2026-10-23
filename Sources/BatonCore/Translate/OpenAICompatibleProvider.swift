import Foundation

/// OpenAI 兼容接口。一条通路覆盖 OpenAI / DeepSeek / Kimi / 智谱 / 硅基流动 / Ollama，
/// 差别只在 `baseURL + model`。
public struct OpenAICompatibleProvider: TranslateProvider {
    public let id: String
    public let displayName: String
    public let config: ProviderConfig

    private let apiKey: String
    private let session: URLSession

    public init(config: ProviderConfig, apiKey: String, session: URLSession = .shared) {
        self.config = config
        self.apiKey = apiKey
        self.session = session
        self.id = config.id
        self.displayName = config.displayName
    }

    /// 从 Keychain 取 key。取不到直接抛，避免带着空 key 发请求换回 401。
    public init(config: ProviderConfig, session: URLSession = .shared) throws {
        guard let key = KeychainStore.read(account: config.apiKeyRef), !key.isEmpty else {
            throw TranslateError.missingAPIKey(account: config.apiKeyRef)
        }
        self.init(config: config, apiKey: key, session: session)
    }

    public func translate(_ request: TranslateRequest) async throws -> TranslateResult {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslateError.emptyInput }

        guard let endpoint = config.chatCompletionsURL else {
            throw TranslateError.invalidEndpoint
        }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(ChatRequestBody(
            model: config.model,
            messages: [
                ChatMessage(role: "system",
                            content: config.promptOverride ?? Self.systemPrompt(source: request.source,
                                                                                 target: request.target)),
                ChatMessage(role: "user", content: text),
            ],
            temperature: 0,
            stream: false
        ))

        let started = CFAbsoluteTimeGetCurrent()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw TranslateError.cancelled
        } catch is CancellationError {
            throw TranslateError.cancelled
        } catch {
            throw TranslateError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranslateError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TranslateError.http(status: http.statusCode,
                                      body: String(decoding: data.prefix(400), as: UTF8.self))
        }

        let decoded: ChatResponseBody
        do {
            decoded = try JSONDecoder().decode(ChatResponseBody.self, from: data)
        } catch {
            throw TranslateError.invalidResponse
        }
        guard let output = decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
            throw TranslateError.invalidResponse
        }

        return TranslateResult(text: output,
                               providerID: id,
                               milliseconds: Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
    }

    // MARK: - Prompt

    static func systemPrompt(source: String?, target: String) -> String {
        let from = source.map { "from \(languageName($0)) " } ?? ""
        return """
        You are a translation engine. Translate the user's text \(from)into \(languageName(target)).
        Output only the translation — no explanations, no quotes, no preamble.
        Preserve line breaks, markdown, code blocks, inline code and numbers exactly as they are.
        If the text is already in the target language, return it unchanged.
        """
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "zh-Hans", "zh-CN", "zh": return "Simplified Chinese"
        case "zh-Hant", "zh-TW": return "Traditional Chinese"
        case "en", "en-US", "en-GB": return "English"
        case "ja", "ja-JP": return "Japanese"
        case "ko", "ko-KR": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        case "ru": return "Russian"
        default: return code
        }
    }
}

// MARK: - Wire

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatRequestBody: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let stream: Bool
}

private struct ChatResponseBody: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}

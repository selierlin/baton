import Foundation

/// 腾讯云机器翻译（TMT）。
///
/// 和百度一样是「账号 + 密钥」型，但协议完全不同：JSON 请求体、TC3-HMAC-SHA256 签名，
/// 参数放在请求头里，接口地址固定。签名部分见 `TencentCloudSigner`。
public struct TencentTranslateProvider: TranslateProvider {
    public static let host = "tmt.tencentcloudapi.com"
    public static let endpoint = URL(string: "https://\(host)/")!
    public static let service = "tmt"
    public static let apiVersion = "2018-03-21"
    /// 翻译的地域只影响就近接入，不影响计费；广州是默认值。
    public static let region = "ap-guangzhou"

    public let id: String
    public let displayName: String
    public let config: ProviderConfig

    private let secretID: String
    private let secretKey: String
    private let session: URLSession

    public init(config: ProviderConfig,
                secretKey: String,
                session: URLSession = .shared) throws {
        guard let secretID = config.appID, !secretID.isEmpty else {
            throw TranslateError.missingConfig("腾讯翻译需要 SecretId，到「设置 → 翻译」填一次")
        }
        guard !secretKey.isEmpty else {
            throw TranslateError.missingAPIKey(account: config.apiKeyRef)
        }
        self.config = config
        self.secretID = secretID
        self.secretKey = secretKey
        self.session = session
        self.id = config.id
        self.displayName = config.displayName
    }

    public init(config: ProviderConfig, session: URLSession = .shared) throws {
        guard let secret = KeychainStore.read(account: config.apiKeyRef) else {
            throw TranslateError.missingAPIKey(account: config.apiKeyRef)
        }
        try self.init(config: config, secretKey: secret, session: session)
    }

    public func translate(_ request: TranslateRequest) async throws -> TranslateResult {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslateError.emptyInput }
        // 单次上限 5000 字符，超了直接报错，别让服务端截断成半句。
        guard text.count <= 5000 else {
            throw TranslateError.tooLong(bytes: text.utf8.count, limit: 5000)
        }

        let body = try JSONSerialization.data(withJSONObject: [
            "SourceText": text,
            "Source": Self.languageCode(request.source),
            "Target": Self.languageCode(request.target),
            "ProjectId": 0,
        ])

        let timestamp = TencentCloudSigner.now()
        let signer = TencentCloudSigner(secretID: secretID, secretKey: secretKey)
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.httpBody = body
        for (key, value) in signer.headers(host: Self.host,
                                           service: Self.service,
                                           action: "TextTranslate",
                                           version: Self.apiVersion,
                                           region: Self.region,
                                           body: body,
                                           timestamp: timestamp) {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

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

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw TranslateError.invalidResponse
        }

        if let error = decoded.Response?.Error {
            throw TranslateError.service(code: error.Code,
                                         message: Self.explain(error.Code, fallback: error.Message))
        }
        guard let output = decoded.Response?.TargetText, !output.isEmpty else {
            throw TranslateError.invalidResponse
        }

        return TranslateResult(text: output,
                               providerID: id,
                               milliseconds: Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
    }

    // MARK: - 语言码与错误码

    /// BCP-47 → 腾讯语言码。腾讯基本沿用 ISO 639-1，只有繁体是 `zh-TW`，
    /// 不能像百度那样写成 `cht`。
    static func languageCode(_ code: String?) -> String {
        guard let code else { return "auto" }
        switch code {
        case "zh-Hans", "zh-CN", "zh": return "zh"
        case "zh-Hant", "zh-TW", "zh-HK": return "zh-TW"
        case "en", "en-US", "en-GB": return "en"
        case "ja", "ja-JP": return "ja"
        case "ko", "ko-KR": return "ko"
        case "fr", "fr-FR": return "fr"
        case "es", "es-ES": return "es"
        case "it", "it-IT": return "it"
        case "de", "de-DE": return "de"
        case "tr", "tr-TR": return "tr"
        case "ru", "ru-RU": return "ru"
        case "pt", "pt-BR", "pt-PT": return "pt"
        case "vi", "vi-VN": return "vi"
        case "id", "id-ID": return "id"
        case "th", "th-TH": return "th"
        case "ms", "ms-MY": return "ms"
        case "ar", "ar-SA": return "ar"
        case "hi", "hi-IN": return "hi"
        default: return code
        }
    }

    /// 腾讯的错误码是 `模块.原因` 的形式，翻成人话再带上原始 code，方便查文档。
    static func explain(_ code: String, fallback: String) -> String {
        let plain: String
        switch code {
        case "AuthFailure.SignatureFailure":
            plain = "签名错误，检查 SecretKey 是否抄错"
        case "AuthFailure.SecretIdNotFound":
            plain = "SecretId 不存在，检查访问管理里的密钥"
        case "AuthFailure.SignatureExpire":
            plain = "签名过期，本机时间可能不准"
        case "AuthFailure.TokenFailure":
            plain = "临时密钥失效"
        case "AuthFailure.UnauthorizedOperation":
            plain = "该密钥没有机器翻译权限，去控制台开通"
        case "FailedOperation.NoFreeAmount":
            plain = "免费额度已用完"
        case "FailedOperation.ServiceIsolate":
            plain = "账号欠费，服务已停"
        case "FailedOperation.UserNotRegistered":
            plain = "还没开通机器翻译服务"
        case "LimitExceeded":
            plain = "请求过于频繁，稍后再试"
        case "RequestLimitExceeded":
            plain = "QPS 超限，稍后再试"
        case "UnsupportedOperation.TextTooLong":
            plain = "单次文本过长"
        case "UnsupportedOperation.UnsupportedLanguage":
            plain = "不支持的语言方向"
        default:
            plain = fallback
        }
        return "\(plain)（\(code)）"
    }
}

private struct ResponseBody: Decodable {
    struct Body: Decodable {
        let TargetText: String?
        let Source: String?
        let Target: String?
        let Error: TencentServiceError?
    }
    let Response: Body?
}

import CryptoKit
import Foundation

/// 百度翻译开放平台。
///
/// 和 OpenAI 兼容族完全不同：不是 Bearer，而是 `appid + q + salt + 密钥` 的 MD5 签名，
/// 参数走 form-urlencoded。签名用的 `q` 必须是**原始文本**，不是 URL 编码后的。
public struct BaiduTranslateProvider: TranslateProvider {
    public static let endpoint = URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!

    public let id: String
    public let displayName: String
    public let config: ProviderConfig

    private let appID: String
    private let secretKey: String
    private let session: URLSession

    public init(config: ProviderConfig,
                secretKey: String,
                session: URLSession = .shared) throws {
        guard let appID = config.appID, !appID.isEmpty else {
            throw TranslateError.missingConfig("百度翻译需要 appid，用 --translate-appid 设置")
        }
        guard !secretKey.isEmpty else {
            throw TranslateError.missingAPIKey(account: config.apiKeyRef)
        }
        self.config = config
        self.appID = appID
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
        // 免费版单次上限 6000 字节，超了会被截断成半句话，不如直接报错。
        guard text.utf8.count <= 6000 else {
            throw TranslateError.tooLong(bytes: text.utf8.count, limit: 6000)
        }

        let from = Self.languageCode(request.source)
        let to = Self.languageCode(request.target)
        let salt = String(Int(Date().timeIntervalSince1970 * 1000))
        let sign = Self.signature(appID: appID, text: text, salt: salt, secret: secretKey)

        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // 严格编码：q 里的 `+`、`&`、`#` 原样发出会被表单解析或截断，译文就对不上了。
        // 注意签名用的是**编码前**的 q，这里只影响传输。
        urlRequest.httpBody = FormEncoding.body([
            (key: "q", value: text),
            (key: "from", value: from),
            (key: "to", value: to),
            (key: "appid", value: appID),
            (key: "salt", value: salt),
            (key: "sign", value: sign),
        ])

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

        if let code = decoded.error_code {
            throw TranslateError.service(code: code,
                                         message: decoded.error_msg ?? Self.explain(code))
        }
        guard let results = decoded.trans_result, !results.isEmpty else {
            throw TranslateError.invalidResponse
        }

        // 百度按段落返回数组，顺序即原文顺序；用换行拼回去保持段落结构。
        let output = results.map(\.dst).joined(separator: "\n")
        return TranslateResult(text: output,
                               providerID: id,
                               milliseconds: Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
    }

    // MARK: - 签名与语言映射

    /// `MD5(appid + q + salt + 密钥)`，小写十六进制。
    static func signature(appID: String, text: String, salt: String, secret: String) -> String {
        let raw = appID + text + salt + secret
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// BCP-47 → 百度语言码。注意日语是 `jp`、韩语是 `kor`、繁体是 `cht`，不是 ISO 写法。
    static func languageCode(_ code: String?) -> String {
        guard let code else { return "auto" }
        switch code {
        case "zh-Hans", "zh-CN", "zh": return "zh"
        case "zh-Hant", "zh-TW", "zh-HK": return "cht"
        case "en", "en-US", "en-GB": return "en"
        case "ja", "ja-JP": return "jp"
        case "ko", "ko-KR": return "kor"
        case "fr", "fr-FR": return "fra"
        case "es", "es-ES": return "spa"
        case "pt", "pt-BR", "pt-PT": return "pt"
        case "de", "de-DE": return "de"
        case "it", "it-IT": return "it"
        case "ru", "ru-RU": return "ru"
        case "th", "th-TH": return "th"
        case "ar", "ar-SA": return "ara"
        default: return code
        }
    }

    static func explain(_ code: String) -> String {
        switch code {
        case "52001": return "请求超时，请重试"
        case "52002": return "百度侧系统错误"
        case "52003": return "未授权用户，appid 或密钥不对"
        case "54000": return "必填参数为空"
        case "54001": return "签名错误，检查密钥"
        case "54003": return "访问频率受限（免费版 QPS=1）"
        case "54004": return "账户余额不足"
        case "54005": return "长文本请求过于频繁"
        case "58000": return "客户端 IP 非法，检查百度后台是否设了 IP 白名单"
        case "58001": return "译文语言方向不支持"
        case "58002": return "服务已关闭，去百度控制台开启"
        case "90107": return "认证未通过或未生效"
        default: return "百度翻译返回错误 \(code)"
        }
    }
}

private struct ResponseBody: Decodable {
    struct Item: Decodable {
        let src: String
        let dst: String
    }
    let from: String?
    let to: String?
    let trans_result: [Item]?
    let error_code: String?
    let error_msg: String?
}

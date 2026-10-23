import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 百度通用文字识别。
///
/// 和翻译一样是「先换 token，再用 token 调接口」两步：
/// `POST /oauth/2.0/token` 拿 `access_token`（有效期 30 天），
/// 再 `POST /rest/2.0/ocr/v1/general_basic` 提交 base64 图片。
///
/// 返回的 `location` 本来就是**左上原点像素**，和 `OCRLine` 的约定一致，不用翻转。
public struct BaiduOCRTransport: OCRTransport {
    public static let tokenEndpoint = URL(string: "https://aip.baidubce.com/oauth/2.0/token")!
    public static let recognizeBase = URL(string: "https://aip.baidubce.com/rest/2.0/ocr/v1")!

    /// 官方限制 base64 后 4MB，留一点余量。
    static let uploadLimit = 3_800_000

    /// 百度用后缀区分「带不带位置」，很容易踩：
    /// `general_basic` / `accurate_basic` **只返回文字，没有 `location`**；
    /// `general` / `accurate` 才返回 `location`。
    /// 需要画框、需要按坐标排序时用后者。
    public enum Variant: String, Sendable {
        /// 通用文字识别（标准版），只给文字。默认走这条——多数账号只领了它的免费额度。
        case generalBasic = "general_basic"
        /// 通用文字识别（含位置信息版）。
        case general = "general"
        /// 高精度版，只给文字。
        case accurateBasic = "accurate_basic"
        /// 高精度版（含位置信息版），QPS 2。
        case accurate = "accurate"
    }

    private let accessKey: String
    private let secretKey: String
    private let variant: Variant
    private let languageType: String
    private let cacheURL: URL
    private let session: URLSession

    public init(accessKey: String,
                secretKey: String,
                variant: Variant = .general,
                languageType: String = "CHN_ENG",
                cacheURL: URL? = nil,
                session: URLSession = .shared) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.variant = variant
        self.languageType = languageType
        self.cacheURL = cacheURL ?? Self.defaultCacheURL()
        self.session = session
    }

    /// 从 Keychain 取 AK/SK。account 约定见 `BaiduOCRCredentials`。
    public init(apiKeyRef: String,
                secretRef: String,
                variant: Variant = .general,
                languageType: String = "CHN_ENG",
                cacheURL: URL? = nil,
                session: URLSession = .shared) throws {
        guard let ak = KeychainStore.read(account: apiKeyRef), !ak.isEmpty else {
            throw OCRError.missingCredential(account: apiKeyRef)
        }
        guard let sk = KeychainStore.read(account: secretRef), !sk.isEmpty else {
            throw OCRError.missingCredential(account: secretRef)
        }
        self.init(accessKey: ak,
                  secretKey: sk,
                  variant: variant,
                  languageType: languageType,
                  cacheURL: cacheURL,
                  session: session)
    }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        let started = CFAbsoluteTimeGetCurrent()
        let payload = try Self.encodeForUpload(request.image)
        let token = try await accessToken()

        guard var components = URLComponents(url: Self.recognizeBase.appendingPathComponent(variant.rawValue),
                                             resolvingAgainstBaseURL: false) else {
            throw OCRError.requestFailed("识别地址拼装失败")
        }
        components.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = components.url else {
            throw OCRError.requestFailed("识别地址拼装失败")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // 必须严格编码：base64 里的 `+` 若原样发出，会被表单解析成空格，图片字节就废了。
        urlRequest.httpBody = FormEncoding.body([
            (key: "image", value: payload.base64EncodedString()),
            (key: "language_type", value: languageType),
            (key: "detect_direction", value: "false"),
        ])

        let data = try await send(urlRequest)
        if ProcessInfo.processInfo.environment["BATON_VERBOSE"] != nil {
            print("[baidu-ocr] upload=\(payload.count)B raw=\(String(decoding: data.prefix(1500), as: UTF8.self))")
        }
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw OCRError.requestFailed("返回格式不符合预期")
        }

        if let code = decoded.error_code {
            // token 过期时百度返回 110（参数为空）或 14（鉴权失败），清掉缓存下次重取。
            if code == 14 || code == 110 {
                try? FileManager.default.removeItem(at: cacheURL)
            }
            throw OCRError.service(code: code, message: decoded.error_msg ?? Self.explain(code))
        }

        let lines = (decoded.words_result ?? []).compactMap { item -> OCRLine? in
            let text = item.words.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard let box = item.location else {
                // `*_basic` 接口只给文字不给位置，坐标留空，不要连文本一起丢。
                return OCRLine(text: text, points: [])
            }
            return OCRLine(text: text, rect: CGRect(x: CGFloat(box.left),
                                                    y: CGFloat(box.top),
                                                    width: CGFloat(box.width),
                                                    height: CGFloat(box.height)))
        }

        return OCRResult(lines: OCRLine.readingOrder(lines),
                         milliseconds: Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
    }

    // MARK: - Token

    private struct CachedToken: Codable {
        /// AK 的摘要，换 key 后旧 token 自动失效。
        let scope: String
        let token: String
        let expiresAt: Date
    }

    private func accessToken() async throws -> String {
        let scope = Self.scope(of: accessKey)
        if let cached = Self.readCache(cacheURL),
           cached.scope == scope,
           cached.expiresAt.timeIntervalSinceNow > 3600 {
            return cached.token
        }

        guard var components = URLComponents(url: Self.tokenEndpoint, resolvingAgainstBaseURL: false) else {
            throw OCRError.requestFailed("token 地址不合法")
        }
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: accessKey),
            URLQueryItem(name: "client_secret", value: secretKey),
        ]
        guard let url = components.url else {
            throw OCRError.requestFailed("token 地址不合法")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30

        let data = try await send(urlRequest)
        let decoded: TokenBody
        do {
            decoded = try JSONDecoder().decode(TokenBody.self, from: data)
        } catch {
            throw OCRError.requestFailed("token 返回格式不符合预期")
        }
        guard let token = decoded.access_token, !token.isEmpty else {
            throw OCRError.requestFailed(decoded.error_description ?? "获取 access_token 失败")
        }

        let lifetime = TimeInterval(decoded.expires_in ?? 2_592_000)
        let cached = CachedToken(scope: scope,
                                 token: token,
                                 expiresAt: Date().addingTimeInterval(lifetime))
        if let encoded = try? JSONEncoder().encode(cached) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        return token
    }

    private static func scope(of key: String) -> String {
        String(key.hashValue)
    }

    private static func defaultCacheURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Baton", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("baidu-ocr-token.json")
    }

    private static func readCache(_ url: URL) -> CachedToken? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedToken.self, from: data)
    }

    // MARK: - 传输

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw OCRError.cancelled
        } catch is CancellationError {
            throw OCRError.cancelled
        } catch {
            throw OCRError.requestFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OCRError.requestFailed("没有拿到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OCRError.requestFailed("HTTP \(http.statusCode)："
                + String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    // MARK: - 图片预处理

    /// 百度按 base64 后的长度限 4MB。先降 JPEG 质量，不够再等比缩小。
    static func encodeForUpload(_ image: CGImage) throws -> Data {
        guard image.width > 0, image.height > 0 else { throw OCRError.emptyImage }

        func fits(_ data: Data) -> Bool {
            // base64 约为原始 4/3，这里直接按最终字符串长度比。
            data.base64EncodedString().utf8.count <= uploadLimit
        }

        for quality in [0.9, 0.75, 0.6] {
            if let data = jpeg(image, quality: quality), fits(data) { return data }
        }

        var current = image
        for _ in 0..<6 {
            guard let smaller = resized(current, factor: 0.7) else { break }
            current = smaller
            for quality in [0.85, 0.65] {
                if let data = jpeg(current, quality: quality), fits(data) { return data }
            }
            if current.width <= 320 || current.height <= 320 { break }
        }
        throw OCRError.requestFailed("图片压缩后仍超过 4MB 限制")
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer,
                                                                 UTType.jpeg.identifier as CFString,
                                                                 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    static func resized(_ image: CGImage, factor: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func explain(_ code: Int) -> String {
        switch code {
        case 1: return "百度服务内部错误"
        case 2: return "百度服务暂不可用"
        case 3: return "不支持的图片格式"
        case 4: return "图片为空"
        case 6: return "图片含敏感内容"
        case 14: return "IAM 鉴权失败，检查 AK/SK"
        case 17: return "今日请求量已达上限"
        case 18: return "QPS 超限，稍后再试"
        case 19: return "请求总量超限"
        case 100: return "参数无效"
        case 110: return "必选参数为空（通常是 access_token 失效）"
        case 216: return "图片大小超限"
        case 222: return "图片长宽比不满足要求"
        default: return "百度 OCR 返回错误 \(code)"
        }
    }
}

/// Keychain 里百度 OCR 两个凭据的固定 account 名。
public enum BaiduOCRCredentials {
    public static let accessKeyAccount = "ocr.baidu.ak"
    public static let secretKeyAccount = "ocr.baidu.sk"
}

private struct TokenBody: Decodable {
    let access_token: String?
    let expires_in: Int?
    let error: String?
    let error_description: String?
}

private struct ResponseBody: Decodable {
    struct Location: Decodable {
        let left: Double
        let top: Double
        let width: Double
        let height: Double
    }
    struct Item: Decodable {
        let words: String
        let location: Location?
    }
    let words_result: [Item]?
    let error_code: Int?
    let error_msg: String?
}

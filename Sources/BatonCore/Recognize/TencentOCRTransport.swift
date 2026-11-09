import CoreGraphics
import Foundation

/// 腾讯云通用文字识别（GeneralBasicOCR）。
///
/// 和百度最大的不同：腾讯不受「带不带坐标」的接口变体折磨，
/// `TextDetections[].Polygon` 恒定返回四点，顺序是左上 → 右上 → 右下 → 左下，
/// 正好是 `OCRLine.points` 的约定，不用翻转也不用猜。
public struct TencentOCRTransport: OCRTransport {
    public static let host = "ocr.tencentcloudapi.com"
    public static let endpoint = URL(string: "https://\(host)/")!
    public static let service = "ocr"
    public static let apiVersion = "2018-10-15"
    public static let region = "ap-guangzhou"

    /// 官方限制：图片 base64 后不超过 7MB。留一点余量。
    static let base64Limit = 6_800_000

    private let secretID: String
    private let secretKey: String
    private let languageType: String
    private let session: URLSession

    public init(secretID: String,
                secretKey: String,
                languageType: String = "auto",
                session: URLSession = .shared) {
        self.secretID = secretID
        self.secretKey = secretKey
        self.languageType = languageType
        self.session = session
    }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        let started = CFAbsoluteTimeGetCurrent()
        let payload = try OCREncoding.encode(request.image, base64Limit: Self.base64Limit)

        let body = try JSONSerialization.data(withJSONObject: [
            "ImageBase64": payload.base64EncodedString(),
            "LanguageType": languageType,
        ])

        let signer = TencentCloudSigner(secretID: secretID, secretKey: secretKey)
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.httpBody = body
        for (key, value) in signer.headers(host: Self.host,
                                           service: Self.service,
                                           action: "GeneralBasicOCR",
                                           version: Self.apiVersion,
                                           region: Self.region,
                                           body: body) {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let data = try await send(urlRequest)
        if ProcessInfo.processInfo.environment["BATON_VERBOSE"] != nil {
            print("[tencent-ocr] upload=\(payload.count)B raw=\(String(decoding: data.prefix(1500), as: UTF8.self))")
        }

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw OCRError.requestFailed("返回格式不符合预期")
        }
        if let error = decoded.Response?.Error {
            throw OCRError.requestFailed(Self.explain(error.Code, fallback: error.Message))
        }

        let lines = (decoded.Response?.TextDetections ?? []).compactMap { item -> OCRLine? in
            let text = item.DetectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let points = (item.Polygon ?? []).map { CGPoint(x: CGFloat($0.X), y: CGFloat($0.Y)) }
            return OCRLine(text: text, points: points)
        }

        return OCRResult(lines: OCRLine.readingOrder(lines),
                         milliseconds: Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
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

    static func explain(_ code: String, fallback: String) -> String {
        let plain: String
        switch code {
        case "AuthFailure.SignatureFailure":
            plain = "签名错误，检查 SecretKey 是否抄错"
        case "AuthFailure.SecretIdNotFound":
            plain = "SecretId 不存在，检查访问管理里的密钥"
        case "AuthFailure.SignatureExpire":
            plain = "签名过期，本机时间可能不准"
        case "FailedOperation.ImageDecodeFailed":
            plain = "图片解码失败"
        case "FailedOperation.OcrFailed":
            plain = "识别失败，换张清晰的图再试"
        case "FailedOperation.NoFreeAmount":
            plain = "免费额度已用完"
        case "FailedOperation.ServiceIsolate":
            plain = "账号欠费，服务已停"
        case "FailedOperation.UserNotRegistered":
            plain = "还没开通文字识别服务"
        case "LimitExceeded.TooLargeFileError":
            plain = "图片过大"
        case "ResourceUnavailable.InArrears":
            plain = "账号欠费"
        case "RequestLimitExceeded":
            plain = "QPS 超限，稍后再试"
        case "UnsupportedOperation.UnsupportedLanguage":
            plain = "不支持的语言"
        default:
            plain = fallback
        }
        return "\(plain)（\(code)）"
    }
}

/// Keychain 里腾讯 OCR 两个凭据的固定 account 名。
public enum TencentOCRCredentials {
    public static let secretIDAccount = "ocr.tencent.secretid"
    public static let secretKeyAccount = "ocr.tencent.secretkey"
}

private struct ResponseBody: Decodable {
    struct Body: Decodable {
        struct Point: Decodable {
            let X: Double
            let Y: Double
        }
        struct Detection: Decodable {
            let DetectedText: String
            let Confidence: Double?
            let Polygon: [Point]?
        }
        let TextDetections: [Detection]?
        let Error: TencentServiceError?
    }
    let Response: Body?
}

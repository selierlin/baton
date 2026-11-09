import CryptoKit
import Foundation

/// 腾讯云 API 3.0 的 TC3-HMAC-SHA256 签名。
///
/// 腾讯云所有产品的签名算法都是同一套，差别只有 `service`（翻译 `tmt`、OCR `ocr`）
/// 和 `X-TC-Action/Version/Region` 三个头。所以签名抽在这里，
/// 各产品只负责拼自己的 JSON 请求体和解析响应。
///
/// 签名是四层 HMAC 链：
/// `HMAC("TC3"+SecretKey, 日期)` → `HMAC(.., service)` → `HMAC(.., "tc3_request")` → `HMAC(.., stringToSign)`。
/// 中间任意一层的 key 用错位置，签出来的都是合法格式的错签名，服务端只会回一个人畜无害的
/// `AuthFailure.SignatureFailure`——所以这个函数必须能被单测直接打。
public struct TencentCloudSigner: Sendable {
    public static let algorithm = "TC3-HMAC-SHA256"
    public static let contentType = "application/json; charset=utf-8"

    public let secretID: String
    public let secretKey: String

    public init(secretID: String, secretKey: String) {
        self.secretID = secretID
        self.secretKey = secretKey
    }

    /// 拼好一整套请求头。调用方再塞 `URLRequest` 即可。
    public func headers(host: String,
                        service: String,
                        action: String,
                        version: String,
                        region: String?,
                        body: Data,
                        timestamp: Int = TencentCloudSigner.now()) -> [String: String] {
        var headers = [
            "Authorization": authorization(host: host,
                                           service: service,
                                           body: body,
                                           timestamp: timestamp),
            "Content-Type": Self.contentType,
            "Host": host,
            "X-TC-Action": action,
            "X-TC-Timestamp": String(timestamp),
            "X-TC-Version": version,
        ]
        if let region, !region.isEmpty {
            headers["X-TC-Region"] = region
        }
        return headers
    }

    /// `Authorization` 头。签名域固定为 `POST /` —— 腾讯云所有接口都是 POST 到根路径，
    /// 参数全在请求体里，所以没有 query string 要参与签名。
    public func authorization(host: String,
                              service: String,
                              body: Data,
                              timestamp: Int) -> String {
        Self.authorization(secretID: secretID,
                           secretKey: secretKey,
                           host: host,
                           service: service,
                           body: body,
                           timestamp: timestamp)
    }

    // MARK: - 纯函数，单测直接打

    public static func authorization(secretID: String,
                                     secretKey: String,
                                     host: String,
                                     service: String,
                                     body: Data,
                                     timestamp: Int) -> String {
        let date = dateString(timestamp: timestamp)
        let signedHeaders = "content-type;host"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\n"

        let canonicalRequest = [
            "POST",
            "/",
            "",                       // query string 为空
            canonicalHeaders,
            signedHeaders,
            sha256Hex(body),
        ].joined(separator: "\n")

        let scope = "\(date)/\(service)/tc3_request"
        let stringToSign = [
            algorithm,
            String(timestamp),
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let secretDate = hmac(key: Data("TC3\(secretKey)".utf8), data: Data(date.utf8))
        let secretService = hmac(key: secretDate, data: Data(service.utf8))
        let secretSigning = hmac(key: secretService, data: Data("tc3_request".utf8))
        let signature = hmac(key: secretSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return "\(algorithm) Credential=\(secretID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    /// UTC 日期，签名域里的 `date` 必须是 UTC，用本地时区会在跨零点前后全挂。
    public static func dateString(timestamp: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day],
                                            from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    public static func now() -> Int { Int(Date().timeIntervalSince1970) }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }
}

/// 腾讯云的错误块。腾讯把业务错误也放在 HTTP 200 里：`{"Response":{"Error":{...}}}`，
/// 只看状态码会把「签名错」当成「成功但没内容」。
public struct TencentServiceError: Decodable, Sendable {
    public let Code: String
    public let Message: String

    public init(Code: String, Message: String) {
        self.Code = Code
        self.Message = Message
    }
}

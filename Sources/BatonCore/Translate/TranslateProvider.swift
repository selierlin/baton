import Foundation

public struct TranslateRequest: Sendable, Equatable {
    public var text: String
    /// BCP-47 源语言；`nil` 表示交给模型自动判断。
    public var source: String?
    /// BCP-47 目标语言。
    public var target: String

    public init(text: String, source: String? = nil, target: String = "zh-Hans") {
        self.text = text
        self.source = source
        self.target = target
    }
}

public struct TranslateResult: Sendable, Equatable {
    public var text: String
    public var providerID: String
    public var milliseconds: Int

    public init(text: String, providerID: String, milliseconds: Int) {
        self.text = text
        self.providerID = providerID
        self.milliseconds = milliseconds
    }
}

public enum TranslateError: Error, Sendable, Equatable {
    case emptyInput
    case missingAPIKey(account: String)
    case missingConfig(String)
    case tooLong(bytes: Int, limit: Int)
    case invalidEndpoint
    case invalidResponse
    case http(status: Int, body: String)
    case service(code: String, message: String)
    case transport(String)
    case cancelled
}

extension TranslateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "没有可翻译的文本"
        case .missingAPIKey(let account):
            // 直接给出可执行动作：用户看到的多半是浮窗，不会去翻日志或 Keychain
            return "未配置密钥（Keychain 条目 \(account)）；到「设置 → 翻译」填一次 API Key 再保存"
        case .missingConfig(let message):
            return message
        case .tooLong(let bytes, let limit):
            return "文本 \(bytes) 字节，超过单次上限 \(limit) 字节"
        case .invalidEndpoint:
            return "接口地址不合法"
        case .invalidResponse:
            return "接口返回格式不符合预期"
        case .http(let status, let body):
            return "接口返回 \(status)：\(body)"
        case .service(let code, let message):
            return "\(message)（\(code)）"
        case .transport(let message):
            return "网络错误：\(message)"
        case .cancelled:
            return "已取消"
        }
    }
}

/// 翻译只依赖这个协议。换服务商、换模型都只换实现或配置，调用方不动。
public protocol TranslateProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func translate(_ request: TranslateRequest) async throws -> TranslateResult
}

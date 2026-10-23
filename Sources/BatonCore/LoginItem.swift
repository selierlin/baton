import Foundation
import ServiceManagement

public struct LoginItemStatus: Sendable {
    public let enabled: Bool
    public let requiresApproval: Bool
    public let rawValue: Int
    public let detail: String

    public init(enabled: Bool, requiresApproval: Bool, rawValue: Int, detail: String) {
        self.enabled = enabled
        self.requiresApproval = requiresApproval
        self.rawValue = rawValue
        self.detail = detail
    }
}

/// `SMAppService.mainApp` 的薄封装。
///
/// 只在**打包成 .app 并从 bundle 内运行**时有意义；从 `swift run` 直接跑会得到
/// `.notFound` 或注册失败，这是预期行为，不是 bug。
@MainActor
public final class LoginItem {
    public init() {}

    public var status: LoginItemStatus {
        let status = SMAppService.mainApp.status
        let detail: String
        switch status {
        case .enabled:
            detail = "已启用"
        case .notRegistered:
            detail = "未注册"
        case .requiresApproval:
            detail = "等待用户在系统设置中批准"
        case .notFound:
            detail = "服务尚未登记（首次注册前会返回此值，直接 register 即可）"
        @unknown default:
            detail = "未知状态 \(status.rawValue)"
        }
        return LoginItemStatus(enabled: status == .enabled,
                               requiresApproval: status == .requiresApproval,
                               rawValue: status.rawValue,
                               detail: detail)
    }

    /// 返回注册/注销后的最新状态；失败时抛出系统错误（含 error code）。
    @discardableResult
    public func setEnabled(_ enabled: Bool) throws -> LoginItemStatus {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        return status
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

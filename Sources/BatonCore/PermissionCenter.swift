import ApplicationServices
import CoreGraphics
import Foundation

public enum PermissionKind: String, Sendable, CaseIterable {
    case accessibility
    case screenRecording
    case listenEvent
}

public enum PermissionStatus: String, Sendable {
    case granted
    case denied
}

/// 只做「查询」和「触发系统引导」，不做弹窗文案。
/// 引导页由 AppShell 负责，避免每个功能各弹一次。
public enum PermissionCenter {
    public static func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .listenEvent:
            return CGPreflightListenEventAccess() ? .granted : .denied
        }
    }

    /// 触发系统授权流程。返回后不一定立刻 granted（多数要用户去系统设置），
    /// 调用方应重新 `status(_:)` 或等用户回来复检。
    public static func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            // kAXTrustedCheckOptionPrompt 是共享可变全局，Swift 6 下不能直接取。
            // 它的字面值就是 "AXTrustedCheckOptionPrompt"。
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .listenEvent:
            _ = CGRequestListenEventAccess()
        }
    }

    public static var all: [PermissionKind: PermissionStatus] {
        Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, status($0)) })
    }
}

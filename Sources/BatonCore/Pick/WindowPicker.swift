import CoreGraphics
import Foundation

/// 悬停拾取到的目标。坐标是**全局显示坐标（点，左上原点）**，已裁剪到光标所在那块屏。
public struct PickTarget: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case window
        case element
    }

    public let kind: Kind
    public let rect: CGRect
    public let label: String
    public let ownerPID: pid_t
    public let ownerName: String
    /// 命中窗口的 CGWindowID。窗口截图靠它做真实抓取，元素拾取用不到。
    public let windowID: Int

    public init(kind: Kind, rect: CGRect, label: String, ownerPID: pid_t,
                ownerName: String, windowID: Int) {
        self.kind = kind
        self.rect = rect
        self.label = label
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.windowID = windowID
    }
}

/// `CGWindowListCopyWindowInfo` 的一行，抽成值类型后命中测试就能单测。
public struct WindowInfo: Sendable, Equatable {
    public let windowID: Int
    public let ownerPID: pid_t
    public let ownerName: String
    public let title: String?
    public let layer: Int
    public let alpha: Double
    public let bounds: CGRect

    public init(windowID: Int, ownerPID: pid_t, ownerName: String, title: String?,
                layer: Int, alpha: Double, bounds: CGRect) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.title = title
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }

    public var displayLabel: String {
        guard let title, !title.isEmpty else { return ownerName }
        return "\(ownerName) — \(title)"
    }
}

public enum WindowPicker {
    /// 桌面元素不算窗口；菜单栏/Dock 的 layer 不为 0，一并排掉。
    public static func isCandidate(_ info: WindowInfo, excludingPID: pid_t? = nil) -> Bool {
        if let excludingPID, info.ownerPID == excludingPID { return false }
        guard info.layer == 0 else { return false }
        guard info.alpha > 0.01 else { return false }
        guard info.bounds.width >= 40, info.bounds.height >= 24 else { return false }
        return true
    }

    /// 列表顺序就是前到后，取第一个包含该点且仍合格的窗口。
    public static func pick(_ point: CGPoint,
                            from windows: [WindowInfo],
                            excludingPID: pid_t? = nil) -> WindowInfo? {
        windows.first { isCandidate($0, excludingPID: excludingPID) && $0.bounds.contains(point) }
    }

    /// 活动窗口 = 前台 App 最靠前的那个普通窗口。
    ///
    /// 前台 App 由 `NSWorkspace.frontmostApplication` 给（LSUIElement 的 Baton 不抢前台），
    /// 窗口顺序由 `CGWindowListCopyWindowInfo` 保证「前到后」，所以取第一个命中即可。
    /// 不用 AX 的 `kAXFocusedWindow`：那要辅助功能权限，而窗口截图本身只需要录屏权限。
    public static func activeWindow(frontmostPID: pid_t,
                                    excludingPID: pid_t? = nil) -> WindowInfo? {
        activeWindow(frontmostPID: frontmostPID,
                     from: enumerate(excludingPID: excludingPID),
                     excludingPID: excludingPID)
    }

    /// 纯函数版本：列表顺序即「前到后」，取前台 App 的第一个合格窗口。
    public static func activeWindow(frontmostPID: pid_t,
                                    from windows: [WindowInfo],
                                    excludingPID: pid_t? = nil) -> WindowInfo? {
        guard frontmostPID > 0, frontmostPID != excludingPID else { return nil }
        return windows.first {
            $0.ownerPID == frontmostPID && isCandidate($0, excludingPID: excludingPID)
        }
    }

    /// 只读一次，调用方自己决定缓存多久。
    public static func enumerate(excludingPID: pid_t? = nil) -> [WindowInfo] {
        // 不 `.excludeDesktopElements`：壁纸/桌面图标本来就不在 layer 0，
        // 由 isCandidate 统一判定，规则只留一处。
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []

        var result: [WindowInfo] = []
        result.reserveCapacity(raw.count)

        for entry in raw {
            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary else { continue }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds) else { continue }

            let info = WindowInfo(
                windowID: entry[kCGWindowNumber as String] as? Int ?? 0,
                ownerPID: pid_t((entry[kCGWindowOwnerPID as String] as? Int) ?? 0),
                ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                title: entry[kCGWindowName as String] as? String,
                layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 0,
                bounds: bounds
            )
            if isCandidate(info, excludingPID: excludingPID) {
                result.append(info)
            }
        }
        return result
    }
}

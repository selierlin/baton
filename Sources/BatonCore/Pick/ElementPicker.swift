import ApplicationServices
import CoreGraphics
import Foundation

/// AX 命中测试的薄封装。
///
/// 注意不能用系统级元素 `AXUIElementCreateSystemWide()` 做命中——覆盖层是当前最前面的窗口，
/// 系统级命中会返回**我们自己**的 overlay。改为先由 `CGWindowList` 找到光标下的窗口，
/// 再对那个 App 的 AX 树做 `AXUIElementCopyElementAtPosition`。
@MainActor
enum ElementPicker {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Chrome / Electron 默认把整块网页只暴露成一个 `AXGroup`，拿不到链接、按钮这类细元素。
    /// 给目标 App 设 `AXEnhancedUserInterface = true` 后才会生成完整 web AX 树
    /// （VoiceOver 等辅助工具走的就是这条路）。代价是目标 App 要重建一次 AX 树，
    /// 所以每个 pid 只设一次。
    private static var enhancedPIDs: Set<pid_t> = []

    @discardableResult
    static func prepare(pid: pid_t) -> [AXError] {
        guard pid > 0, !enhancedPIDs.contains(pid) else { return [] }
        enhancedPIDs.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        // Safari/WebKit 认 AXEnhancedUserInterface，Chromium/Electron 认 AXManualAccessibility，
        // 两个都设，各自忽略不认识的那个。
        let first = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let second = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return [first, second]
    }

    static func element(at point: CGPoint, pid: pid_t) -> AXUIElement? {
        guard pid > 0, isTrusted else { return nil }
        prepare(pid: pid)
        let app = AXUIElementCreateApplication(pid)
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        guard error == .success, let hit else { return nil }
        return climb(from: hit)
    }

    /// 命中往往落到一行 `AXStaticText` 上，直接高亮一行字不好用。
    /// 只在文本类角色上向上收一层到两层，别一路爬到整窗。
    private static func climb(from element: AXUIElement, depth: Int = 0) -> AXUIElement {
        guard depth < 2, let role = string(element, kAXRoleAttribute) else { return element }
        guard role == kAXStaticTextRole || role == "AXUnknown" else { return element }
        guard let parent = parent(of: element) else { return element }
        return climb(from: parent, depth: depth + 1)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute),
              let size = size(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func label(of element: AXUIElement) -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard let text = string(element, attribute), !text.isEmpty else { continue }
            return text.count > 48 ? String(text.prefix(48)) + "…" : text
        }
        if let role = string(element, kAXRoleAttribute) {
            return role
        }
        return ""
    }

    static func role(of element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute)
    }

    /// 诊断用：把 AX 命中失败的原因摊开（错误码 / 角色 / 矩形）。
    static func diagnose(at point: CGPoint, pid: pid_t) -> String {
        enhancedPIDs.remove(pid)   // 诊断路径每次都重设，顺便拿到设置错误码
        let prepareErrors = prepare(pid: pid)
        // 给目标 App 留出重建 AX 树的时间。
        Thread.sleep(forTimeInterval: 0.6)
        var hit: AXUIElement?
        let app = AXUIElementCreateApplication(pid)
        let error = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        var text = "axErr=\(error.rawValue) trusted=\(isTrusted) pid=\(pid)"
        if !prepareErrors.isEmpty {
            text += " prepare=\(prepareErrors.map(\.rawValue))"
        }
        var flag: CFTypeRef?
        let flagErr = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &flag)
        text += " readback=\(flagErr.rawValue)/\(flag.map { "\($0)" } ?? "nil")"
        if let hit {
            let rect = frame(of: hit).map { "\($0.origin.x),\($0.origin.y) \($0.width)×\($0.height)" } ?? "nil"
            text += " role=\(role(of: hit) ?? "-") rect=(\(rect)) label=\(label(of: hit))"
        }

        var systemHit: AXUIElement?
        let systemError = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                           Float(point.x), Float(point.y),
                                                           &systemHit)
        if let systemHit {
            var hitPID: pid_t = 0
            AXUIElementGetPid(systemHit, &hitPID)
            let rect = frame(of: systemHit).map { "\($0.origin.x),\($0.origin.y) \($0.width)×\($0.height)" } ?? "nil"
            text += " | system err=\(systemError.rawValue) pid=\(hitPID)"
                + " role=\(role(of: systemHit) ?? "-") rect=(\(rect))"
        } else {
            text += " | system err=\(systemError.rawValue) nil"
        }
        return text
    }

    // MARK: - 属性读取

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(element, attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXValue.self)
    }
}

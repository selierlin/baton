import AppKit
import ApplicationServices

/// 划词取词：读当前前台 App 焦点元素的选中文本（Bob 的取词链路）。
///
/// 走 `kAXSelectedTextAttribute`，需要「辅助功能」授权；浏览器/Electron 同样支持，
/// 但前提是目标 App 的 AX 树已启用（Chrome 见 `ElementPicker.prepare`）。
///
/// **WebKit 不走这条路**：Safari 的 `AXWebArea` 只暴露 `AXSelectedTextMarkerRange`
/// （文字标记范围），`kAXSelectedTextAttribute` 一律返回「属性不支持」——
/// 用户在 Safari 里划词会得到「没有取到选中文本」。所以读到空时再按标记范围要一次文本，
/// 不靠 ⌘C 兜底：碰剪贴板会把用户复制的内容冲掉。
public enum SelectionReader {
    public static func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        let app = AXUIElementCreateApplication(front.processIdentifier)
        guard let focused = focusedElement(of: app) else { return nil }

        let direct = copy(focused, kAXSelectedTextAttribute) as? String
        return normalize(direct ?? markerText(of: focused))
    }

    /// 诊断串：取不到词时告诉用户「卡在哪一步」，而不是笼统说没权限。
    public static func diagnose() -> String {
        guard AXIsProcessTrusted() else { return "未授权「辅助功能」" }
        guard let front = NSWorkspace.shared.frontmostApplication else { return "没有前台 App" }
        guard front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return "前台是 Baton 自己"
        }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        guard let focused = focusedElement(of: app) else {
            return "\(front.localizedName ?? "前台 App") 没有暴露焦点元素"
        }
        let role = copy(focused, kAXRoleAttribute) as? String ?? "-"
        let direct = copy(focused, kAXSelectedTextAttribute) as? String
        let marker = markerText(of: focused)
        let picked = normalize(direct ?? marker)
        let source = direct != nil ? "AXSelectedText" : (marker != nil ? "TextMarkerRange" : "无")
        return "\(front.localizedName ?? "-")/\(role) 来源=\(source) "
            + "字符数=\(picked?.count ?? 0)"
    }

    private static func focusedElement(of app: AXUIElement) -> AXUIElement? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(focusedRef, to: AXUIElement.self)
    }

    /// Safari / WebKit：选中范围是 `AXTextMarkerRange`，用参数化属性把它翻成富文本再取字符串。
    private static func markerText(of element: AXUIElement) -> String? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            "AXSelectedTextMarkerRange" as CFString,
                                            &range) == .success,
              let range else { return nil }

        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXAttributedStringForTextMarkerRange" as CFString,
            range,
            &value
        ) == .success, let value else { return nil }

        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// 纯字符串处理单独拿出来：可以单测「只有空白 / 只有换行」这类边界。
    static func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

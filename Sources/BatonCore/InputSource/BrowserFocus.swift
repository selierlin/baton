import AppKit
import ApplicationServices
import os

/// 浏览器焦点落在哪一块。
public enum BrowserFocus: Equatable, Sendable {
    /// 焦点在网页里（含网页里的输入框）
    case page
    /// 焦点在浏览器自己界面的文本框：地址栏、搜索栏
    case shell
    /// 不是浏览器、窗口没 key、或者根本读不到
    case unknown
}

/// 读浏览器焦点位置。只用「辅助功能」权限，不走 AppleScript、不需要屏幕录制。
///
/// 为什么轮询而不是 AX 通知：Chromium 系基本不投 `AXFocusedUIElementChanged`
/// （实测 Chrome 上一条都没收到），Safari 也不保证。好在单次读取 1–2ms，
/// 且只在浏览器当前台时才轮。
///
/// 判定方式：从焦点元素沿 parent 往上找 `AXWebArea`。
/// - 找得到 → 在网页里
/// - 找不到且焦点是文本框 → 那是浏览器外壳的地址栏
/// - 其他（焦点在空白处、窗口本身） → `unknown`，不据此改源
///
/// 不依赖控件描述文案（「地址和搜索栏」「智能搜索栏」会跟着系统语言变），
/// 也不需要给 Chrome 打开 `AXManualAccessibility`——那是网页内容树的开关，
/// 打开会让 Chrome 常驻无障碍模式、复杂页面明显变慢。
public enum BrowserFocusReader {
    /// 结构可识别的浏览器。Chromium 系共用一套层级，Safari/WebKit 结构不同但同样能读。
    /// Firefox 的 chrome 是 XUL，没实测过——宁可先不列，免得把网页输入框误判成地址栏。
    public static let supportedBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// 往上找几层。Chrome 的地址栏埋在 10 层 group 里，网页输入框一般 3–6 层能碰到 AXWebArea。
    private static let maxDepth = 14

    public static func isSupported(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return supportedBundleIDs.contains(bundleID)
    }

    public static func focus(pid: pid_t) -> BrowserFocus {
        guard AXIsProcessTrusted() else { return .unknown }

        let app = AXUIElementCreateApplication(pid)
        // 目标 App 卡住时别把 Baton 也拖住：200ms 拿不到就当读不到
        AXUIElementSetMessagingTimeout(app, 0.2)

        // 窗口没有 key（后台、最小化）时读到的焦点不可信
        guard element(app, kAXFocusedWindowAttribute) != nil else { return .unknown }
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return .unknown }

        var node: AXUIElement? = focused
        var depth = 0
        while let current = node, depth < maxDepth {
            let role = string(current, kAXRoleAttribute)
            if role == "AXWebArea" { return .page }
            node = element(current, kAXParentAttribute)
            depth += 1
        }

        switch string(focused, kAXRoleAttribute) {
        case "AXTextField", "AXSearchField", "AXComboBox", "AXTextArea":
            return .shell
        default:
            // 焦点在窗口/工具栏空白处：这时候用户没在打字，改源没有意义
            return .unknown
        }
    }

    // MARK: - AX 取值

    private static func element(_ target: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func string(_ target: AXUIElement, _ name: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, name as CFString, &value) == .success else {
            return ""
        }
        return value as? String ?? ""
    }
}

/// 定时看一眼「浏览器焦点是不是挪到地址栏了」。
///
/// 只在状态真正变化时回调，服务端据此只切一次——不能每个 tick 都强切，
/// 否则用户手动换成中文搜中文内容会被一直按回英文。
@MainActor
public final class BrowserFocusWatcher {
    /// (焦点位置, 当前前台 App 的 rule key)
    public var onChange: ((BrowserFocus, String) -> Void)?

    /// 120ms：人从 ⌘L 到敲第一个键通常 250ms 以上，这个间隔够快，
    /// 单次读取 1–2ms，折算下来不到 2% 的一个核
    public var interval: TimeInterval = 0.12

    private var timer: Timer?
    private var lastFocus: BrowserFocus = .unknown
    private var lastKey: String?
    private let log = Logger(subsystem: "com.selier.baton", category: "inputsource")

    public init() {}

    public var isRunning: Bool { timer != nil }

    public func start() {
        guard timer == nil else { return }
        lastFocus = .unknown
        lastKey = nil
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common：菜单展开、拖窗口时也要继续跑
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        lastFocus = .unknown
        lastKey = nil
    }

    private func tick() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular,
              BrowserFocusReader.isSupported(app.bundleIdentifier) else {
            if lastFocus != .unknown || lastKey != nil {
                lastFocus = .unknown
                lastKey = nil
                onChange?(.unknown, "")
            }
            return
        }

        let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        let focus = BrowserFocusReader.focus(pid: app.processIdentifier)
        guard focus != lastFocus || key != lastKey else { return }
        lastFocus = focus
        lastKey = key
        onChange?(focus, key)
    }
}

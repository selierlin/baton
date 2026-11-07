import AppKit
import ApplicationServices
import os

/// 浏览器当前的输入上下文：焦点在哪、在哪个站、在什么输入框里。
public struct BrowserContext: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 不是浏览器、窗口没 key、读不到
        case unknown
        /// 浏览器外壳的文本框：地址栏、搜索栏
        case addressBar
        /// 网页正文，但没有聚焦输入框
        case page
        /// 网页里的输入框
        case field
    }

    public let kind: Kind
    /// 规范化后的域名。`needHost == false` 时为 nil
    public let host: String?
    /// 焦点输入框上能读到的文案（placeholder / title / description / identifier 里第一个非空的）
    public let label: String?

    public init(kind: Kind, host: String? = nil, label: String? = nil) {
        self.kind = kind
        self.host = host
        self.label = label
    }

    public static let unknown = BrowserContext(kind: .unknown)
}

/// 读浏览器上下文。只用「辅助功能」权限，不走 AppleScript、不需要屏幕录制。
///
/// 为什么轮询而不是 AX 通知：Chromium 系基本不投 `AXFocusedUIElementChanged`
/// （实测 Chrome 上一条都没收到），Safari 也不保证。好在单次成本很低。
///
/// 判定方式：从焦点元素沿 parent 往上找 `AXWebArea`。
/// - 找得到 + 焦点是文本框 → 网页输入框
/// - 找得到 + 其他 → 网页正文
/// - 找不到 + 焦点是文本框 → 浏览器外壳（地址栏）
/// - 其他 → unknown，不据此改源
///
/// 不依赖控件描述文案（「地址和搜索栏」「智能搜索栏」会跟着系统语言变），
/// 也不需要给 Chrome 打开 `AXManualAccessibility`：实测不开也能读到聚焦输入框的
/// role / placeholder。开了反而让 Chrome 常驻无障碍模式、复杂页面变慢。
public enum BrowserContextReader {
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

    public static func isSupported(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return supportedBundleIDs.contains(bundleID)
    }

    /// 往上找几层。Chrome 的地址栏埋在 10 层 group 里，网页输入框一般 3–6 层能碰到 AXWebArea。
    private static let maxDepth = 14

    /// 算作「文本框」的 role。地址栏和网页输入框都落在这几个里。
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    /// 读地址栏是一次整窗遍历，热了 1–2ms。用窗口标题当缓存键省掉大部分：
    /// 换页时标题基本都会变，SPA 内跳转标题不变、但域名通常也不变。
    /// 读取现在跑在后台队列，加锁是为了让将来可能的并发调用不出错。
    private struct HostCache: Sendable {
        var pid: pid_t
        var title: String
        var host: String?
    }

    private static let hostCacheLock = OSAllocatedUnfairLock<HostCache?>(initialState: nil)

    public static func read(pid: pid_t, needHost: Bool) -> BrowserContext {
        guard AXIsProcessTrusted() else { return .unknown }

        let app = AXUIElementCreateApplication(pid)
        // 目标 App 卡住时别把 Baton 也拖住：200ms 拿不到就当读不到
        AXUIElementSetMessagingTimeout(app, 0.2)

        // 窗口没有 key（后台、最小化）时读到的焦点不可信
        guard let window = element(app, kAXFocusedWindowAttribute) else { return .unknown }
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return .unknown }

        var node: AXUIElement? = focused
        var depth = 0
        var inWeb = false
        while let current = node, depth < maxDepth {
            if string(current, kAXRoleAttribute) == "AXWebArea" {
                inWeb = true
                break
            }
            node = element(current, kAXParentAttribute)
            depth += 1
        }

        let role = string(focused, kAXRoleAttribute)
        let isTextInput = textRoles.contains(role)

        let kind: BrowserContext.Kind
        if inWeb {
            kind = isTextInput ? .field : .page
        } else if isTextInput {
            kind = .addressBar
        } else {
            // 焦点在窗口/工具栏空白处：这时候用户没在打字，改源没有意义
            return .unknown
        }

        let label = kind == .field ? fieldLabel(focused) : nil
        let host = needHost ? addressBarHost(app: app, window: window, pid: pid) : nil
        return BrowserContext(kind: kind, host: host, label: label)
    }

    // MARK: - 取字段

    /// 输入框的身份只能靠无障碍属性：placeholder 最稳定，其次是 title/description。
    /// 富文本编辑器经常一个都没有，那这条规则就不该命中（交给整站规则）。
    private static func fieldLabel(_ element: AXUIElement) -> String? {
        let candidates = [
            kAXPlaceholderValueAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXIdentifierAttribute,
        ]
        for key in candidates {
            let text = string(element, key).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    private static func addressBarHost(app: AXUIElement, window: AXUIElement, pid: pid_t) -> String? {
        let title = string(window, kAXTitleAttribute)
        if !title.isEmpty,
           let cache = hostCacheLock.withLock({ $0 }),
           cache.pid == pid, cache.title == title {
            return cache.host
        }

        guard let raw = addressBarValue(window), !raw.isEmpty else { return nil }
        let host = SiteRuleMatcher.normalizeHost(raw)
        if !title.isEmpty {
            hostCacheLock.withLock { $0 = HostCache(pid: pid, title: title, host: host) }
        }
        return host
    }

    /// 地址栏 = 窗口里第一个不在 `AXWebArea` 子树里的文本框。
    private static func addressBarValue(_ window: AXUIElement) -> String? {
        func find(_ node: AXUIElement, _ depth: Int, _ inWeb: Bool) -> String? {
            if depth > maxDepth { return nil }
            let role = string(node, kAXRoleAttribute)
            let web = inWeb || role == "AXWebArea"
            if !web, textRoles.contains(role) {
                let value = string(node, kAXValueAttribute)
                if !value.isEmpty { return value }
            }
            guard let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            for child in children {
                if let hit = find(child, depth + 1, web) { return hit }
            }
            return nil
        }
        return find(window, 0, false)
    }

    // MARK: - AX 取值

    private static func attribute(_ target: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func element(_ target: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(target, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func string(_ target: AXUIElement, _ name: String) -> String {
        attribute(target, name) as? String ?? ""
    }
}

/// 定时看一眼浏览器的输入上下文变没变。
///
/// 只在状态真正变化时回调，服务端据此只切一次——不能每个 tick 都强切，
/// 否则用户手动换成中文搜中文内容会被一直按回去。
///
/// 两条性能约束：
/// 1. AX 读取放后台队列。AX 是跨进程同步调用，目标 App 卡死时要等满 messaging
///    timeout（200ms）才返回，跑在主线程上就是看得见的卡顿。
/// 2. 前台不是受支持的浏览器时直接把表停掉。轮询的开销不在那 0.1ms 的计算，
///    而在每秒 8 次把 CPU 叫醒。
@MainActor
public final class BrowserFocusWatcher {
    /// (上下文, 当前前台 App 的 rule key)
    public var onChange: ((BrowserContext, String) -> Void)?

    /// 120ms：人从 ⌘L 到敲第一个键通常 250ms 以上，这个间隔够快
    public var interval: TimeInterval = 0.12

    /// 只有配了网站规则才需要读域名——那是一次整窗遍历，能省则省
    public var needsHost = false

    private let queue = DispatchQueue(label: "com.selier.baton.browser-focus", qos: .utility)
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var started = false
    /// 上一次 AX 读还没回来就不再排新的，别让慢 App 把队列堆起来
    private var reading = false
    private var last: BrowserContext = .unknown
    private var lastKey: String?

    public init() {}

    public var isRunning: Bool { started }

    public func start() {
        guard !started else { return }
        started = true
        last = .unknown
        lastKey = nil
        // 用激活通知决定起停表，而不是每 120ms 问一次前台是谁
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncTimer() }
        }
        syncTimer()
    }

    public func stop() {
        started = false
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        stopTimer()
        last = .unknown
        lastKey = nil
        reading = false
    }

    /// 前台是受支持的浏览器才起表；切到别的 App 停掉，切回来由激活通知唤起。
    private func syncTimer() {
        guard started else { return }
        guard frontBrowser() != nil else {
            stopTimer()
            report(.unknown, key: "")
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common：菜单展开、拖窗口时也要继续跑
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // 刚切回来先读一次，不用等第一个间隔
        tick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func frontBrowser() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular,
              BrowserContextReader.isSupported(app.bundleIdentifier) else {
            return nil
        }
        return app
    }

    private func tick() {
        guard !reading else { return }
        guard let app = frontBrowser() else {
            stopTimer()
            report(.unknown, key: "")
            return
        }

        let pid = app.processIdentifier
        let key = app.bundleIdentifier ?? "pid:\(pid)"
        let needHost = needsHost
        reading = true
        queue.async { [weak self] in
            let context = BrowserContextReader.read(pid: pid, needHost: needHost)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reading = false
                    guard self.started else { return }
                    // 读的过程中前台换了 App，这份结果已经过期
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    self.report(context, key: key)
                }
            }
        }
    }

    private func report(_ context: BrowserContext, key: String) {
        guard context != last || key != lastKey else { return }
        last = context
        lastKey = key
        onChange?(context, key)
    }
}

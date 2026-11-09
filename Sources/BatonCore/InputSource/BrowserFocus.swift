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
    /// 焦点元素的身份，只在读普通 App 时有值。用来区分「还是同一个框，只是文案没了」
    /// 和「换到了另一个读不到文案的框」——两者的后续处理完全相反。
    public let fieldKey: String?

    public init(kind: Kind, host: String? = nil, label: String? = nil, fieldKey: String? = nil) {
        self.kind = kind
        self.host = host
        self.label = label
        self.fieldKey = fieldKey
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

    /// 读任意 App 里「焦点是不是落在文本框」以及这个框的文案。
    ///
    /// 和 `read(pid:needHost:)` 的区别：那个是给浏览器用的，要判断焦点在地址栏
    /// 还是网页里，得沿 parent 一路找 `AXWebArea`；这个是给普通 App 用的，
    /// 只关心「焦点在不在一个可输入的地方」，两三次 AX 调用就能出结果。
    ///
    /// 拿不到文案（很多自绘输入框没有 placeholder）时返回 `.field` + `label == nil`：
    /// 调用方据此知道「有输入框但没法按关键字区分」，也就不会误命中带关键字的规则。
    ///
    /// `stableLabelOnly`：学习时用。排掉 `AXTitle`——原生 App 的文本区标题往往是
    /// 文档名（TextEdit 的「First Text View」、编辑器里的文件名），按它学出来的规则
    /// 下次换个文件就不命中了。匹配时不需要这个限制，标题也是有效线索。
    public static func readField(pid: pid_t, stableLabelOnly: Bool = false) -> BrowserContext {
        guard AXIsProcessTrusted() else { return .unknown }

        let app = AXUIElementCreateApplication(pid)
        // 和浏览器那条一样：目标 App 卡住时别把 Baton 也拖住
        AXUIElementSetMessagingTimeout(app, 0.2)

        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return .unknown }
        let role = string(focused, kAXRoleAttribute)
        guard textRoles.contains(role) else { return .unknown }
        return BrowserContext(kind: .field,
                              host: nil,
                              label: fieldLabel(focused, includeTitle: !stableLabelOnly),
                              fieldKey: elementKey(focused))
    }

    /// 焦点元素的身份。`CFHash` 对 AXUIElement 是按「pid + 元素」算的，
    /// 同一个控件反复读回来是同一个值，换控件就变。
    ///
    /// 不能用位置尺寸代替：输入框会随内容长高，打字时几何就变了，
    /// 那样「同一个框文案消失」会被误判成「换了框」。
    private static func elementKey(_ element: AXUIElement) -> String? {
        let hash = CFHash(element)
        return hash == 0 ? nil : String(hash)
    }

    // MARK: - 取字段

    /// 输入框的身份只能靠无障碍属性：placeholder 最稳定，其次是 title/description。
    /// 富文本编辑器经常一个都没有，那这条规则就不该命中（交给整站规则）。
    private static func fieldLabel(_ element: AXUIElement, includeTitle: Bool = true) -> String? {
        var candidates = [kAXPlaceholderValueAttribute]
        if includeTitle { candidates.append(kAXTitleAttribute) }
        candidates += [kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
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

/// 定时看一眼焦点所在的输入框变没变（浏览器、普通 App 共用）。
///
/// 只在状态真正变化时回调，服务端据此只切一次——不能每个 tick 都强切，
/// 否则用户手动换成中文搜中文内容会被一直按回去。
///
/// 两条性能约束：
/// 1. AX 读取放后台队列。AX 是跨进程同步调用，目标 App 卡死时要等满 messaging
///    timeout（200ms）才返回，跑在主线程上就是看得见的卡顿。
/// 2. 前台既不是受支持的浏览器、也没有配 App 规则时直接把表停掉。轮询的开销不在
///    那 0.1ms 的计算，而在每秒 8 次把 CPU 叫醒。
@MainActor
public final class BrowserFocusWatcher {
    /// (上下文, 当前前台 App 的 rule key)
    public var onChange: ((BrowserContext, String) -> Void)?

    /// 120ms：人从 ⌘L 到敲第一个键通常 250ms 以上，这个间隔够快
    public var interval: TimeInterval = 0.12

    /// 只有配了网站规则才需要读域名——那是一次整窗遍历，能省则省
    public var needsHost = false

    /// 浏览器那条链要不要跑（配了地址栏或网站规则）。纯 App 规则时应当关掉，
    /// 否则用户随便切到 Chrome 就会白白开始轮询
    public var watchesBrowsers = true

    /// 除浏览器外，还要盯输入框的 App（配了 App 级规则的那些）
    public var appBundleIDs: Set<String> = []

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
        // 已经在跑：规则可能刚改过（新加了某个 App 的规则），按新配置重判一次要不要轮询
        if started {
            syncTimer()
            return
        }
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

    /// 前台是「值得盯的」才起表；切到别的 App 停掉，切回来由激活通知唤起。
    private func syncTimer() {
        guard started else { return }
        guard frontWatchedApp() != nil else {
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

    /// 当前前台这个 App 值不值得盯：配了 App 规则的 App，或（浏览器那条链开着时）受支持的浏览器。
    ///
    /// 不重新枚举运行中的 App：`frontmostApplication` 是 NSWorkspace 的缓存值，
    /// 一次不到 1µs；真正贵的是后面那次跨进程 AX 读。
    private func frontWatchedApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular else {
            return nil
        }
        if let bundleID = app.bundleIdentifier, appBundleIDs.contains(bundleID) {
            return app
        }
        guard watchesBrowsers, BrowserContextReader.isSupported(app.bundleIdentifier) else {
            return nil
        }
        return app
    }

    private func tick() {
        guard !reading else { return }
        guard let app = frontWatchedApp() else {
            stopTimer()
            report(.unknown, key: "")
            return
        }

        let pid = app.processIdentifier
        let key = app.bundleIdentifier ?? "pid:\(pid)"
        // 浏览器要区分地址栏 / 网页，得走整窗遍历；普通 App 只关心有没有输入框，读得更浅
        let isBrowser = watchesBrowsers && BrowserContextReader.isSupported(app.bundleIdentifier)
        let needHost = needsHost
        reading = true
        queue.async { [weak self] in
            let context = isBrowser
                ? BrowserContextReader.read(pid: pid, needHost: needHost)
                : BrowserContextReader.readField(pid: pid)
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

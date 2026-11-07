import AppKit
import CoreGraphics

/// 滚轮位移的单位。行数与像素必须分开处理：一行约 40pt，像素值不能再乘一遍。
public enum ScrollUnit: Sendable {
    case lines
    case points
}

public struct ScrollSample: Sendable {
    /// 归一化后的可用位移（`unit` 说明它的单位）
    public let deltaX: Double
    public let deltaY: Double
    public let unit: ScrollUnit
    public let isContinuous: Bool
    /// `CGEventField.scrollWheelEventScrollPhase`
    public let phase: Int64
    /// `CGEventField.scrollWheelEventMomentumPhase`
    public let momentum: Int64
    /// 触控板的加速度累计值；鼠标恒为 0（Mos 也拿它判触控板）
    public let scrollCount: Int64
    /// 原始事件的修饰键（保留 ⌃/⌥ 等，某些 App 会据此改变滚动行为）
    public let flags: UInt64
    /// 事件的生产者进程。鼠标厂商驱动会在中间重写事件，靠它把驱动补的假相位认出来
    public let sourcePID: Int32
    public let timestamp: TimeInterval

    public init(deltaX: Double,
                deltaY: Double,
                unit: ScrollUnit = .lines,
                isContinuous: Bool = false,
                phase: Int64 = 0,
                momentum: Int64 = 0,
                scrollCount: Int64 = 0,
                flags: UInt64 = 0,
                sourcePID: Int32 = 0,
                timestamp: TimeInterval = 0) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.unit = unit
        self.isContinuous = isContinuous
        self.phase = phase
        self.momentum = momentum
        self.scrollCount = scrollCount
        self.flags = flags
        self.sourcePID = sourcePID
        self.timestamp = timestamp
    }

    /// 离散鼠标：没有相位、没有惯性、没有加速度累计。
    /// 不能只看 `isContinuous`——有些鼠标驱动会把它标成 1，那样会整段跳过平滑。
    public var isDiscreteMouse: Bool {
        phase == 0 && momentum == 0 && scrollCount == 0
    }
}

public struct FrontApp: Sendable, Equatable {
    public let pid: pid_t
    public let bundleID: String?
    public let name: String?

    public init(pid: pid_t, bundleID: String?, name: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }

    /// 输入法规则的匹配键：优先 bundle id，退化到 pid
    public var ruleKey: String { bundleID ?? "pid:\(pid)" }
}

public enum InputEvent: Sendable {
    case scroll(ScrollSample)
    case frontAppChanged(FrontApp)
    case clipboardChanged(changeCount: Int)
}

/// 输入事件总线。所有 source 只在主线程产事件，订阅者拿 AsyncStream。
///
/// 高频事件（滚动）用 `.bufferingNewest(1)`：平滑滚动的语义是「只要最新的位移」，
/// 堆积旧样本反而会拖出延迟。
@MainActor
public final class EventHub {
    public private(set) var frontApp: FrontApp?
    public private(set) var clipboardChangeCount = NSPasteboard.general.changeCount
    public private(set) var scrollTapActive = false
    /// tap 是否真的能吞事件。只有 `.defaultTap` 可以，且需要「辅助功能」权限。
    public private(set) var scrollTapIntercepts = false
    public private(set) var scrollInterceptionUnavailableReason: String?

    /// 返回 true 表示事件已被接管，不再放行。只在需要平滑滚动时挂上。
    public var scrollInterceptor: (@MainActor (ScrollSample) -> Bool)?

    private var subscribers: [UUID: AsyncStream<InputEvent>.Continuation] = [:]
    private var frontAppTask: Task<Void, Never>?
    private var clipboardTimer: Timer?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapWatchdog: Timer?

    public init() {}

    public func events(buffering: Int = 16) -> AsyncStream<InputEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(buffering)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.subscribers.removeValue(forKey: id)
                }
            }
        }
    }

    public func start() {
        startFrontAppObserver()
        startClipboardPolling()
        startScrollTap()
    }

    public func stop() {
        frontAppTask?.cancel()
        frontAppTask = nil
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        tapWatchdog?.invalidate()
        tapWatchdog = nil
        teardownScrollTap()
    }

    /// 挂/摘拦截器。`listenOnly` 与 `defaultTap` 是两种 tap，切换只能重建。
    public func setScrollInterceptor(_ interceptor: (@MainActor (ScrollSample) -> Bool)?) {
        scrollInterceptor = interceptor
        if tap != nil {
            installScrollTap()
        }
    }

    /// 自己往剪贴板写内容后调用：把当次 changeCount 直接记成「已见过」。
    ///
    /// 以前用计数器，连写两次后对不上实际的 changeCount 就会把紧接的外部复制吞掉；
    /// 记当前值则是幂等的，写几次都不会漂。
    public func noteSelfPasteboardWrite() {
        clipboardChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - front app

    private func startFrontAppObserver() {
        let current = NSWorkspace.shared.frontmostApplication
        if let current {
            frontApp = FrontApp(pid: current.processIdentifier,
                                bundleID: current.bundleIdentifier,
                                name: current.localizedName)
        }

        frontAppTask = Task { [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            for await note in center.notifications(named: NSWorkspace.didActivateApplicationNotification) {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    continue
                }
                let info = FrontApp(pid: app.processIdentifier,
                                    bundleID: app.bundleIdentifier,
                                    name: app.localizedName)
                self?.frontApp = info
                self?.emit(.frontAppChanged(info))
            }
        }
    }

    // MARK: - clipboard

    private func startClipboardPolling() {
        clipboardChangeCount = NSPasteboard.general.changeCount
        // 0.25s：连按两次复制的间隔通常在 0.3s 以上，再慢就会漏中间那条
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPasteboard()
            }
        }
    }

    private func pollPasteboard() {
        let count = NSPasteboard.general.changeCount
        guard count != clipboardChangeCount else { return }
        clipboardChangeCount = count
        emit(.clipboardChanged(changeCount: count))
    }

    // MARK: - scroll tap

    private func startScrollTap() {
        installScrollTap()

        // tap 会被系统静默禁用（超时/用户输入），必须自己看门狗
        tapWatchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rearmScrollTapIfNeeded()
            }
        }
    }

    private func installScrollTap() {
        teardownScrollTap()
        guard CGPreflightListenEventAccess() else {
            scrollInterceptionUnavailableReason = "缺少「输入监控」权限"
            return
        }

        let wantsIntercept = scrollInterceptor != nil
        var intercepting = wantsIntercept
        var newTap: CFMachPort?

        if wantsIntercept {
            newTap = makeScrollTap(options: .defaultTap)
            if newTap == nil {
                // .defaultTap 需要「辅助功能」；没有就退回只监听，不能连累其它功能
                intercepting = false
                scrollInterceptionUnavailableReason = "缺少「辅助功能」权限，已退回只监听"
            }
        }
        if newTap == nil {
            newTap = makeScrollTap(options: .listenOnly)
        }
        guard let newTap else {
            scrollInterceptionUnavailableReason = "无法创建滚动事件 tap"
            return
        }
        if intercepting { scrollInterceptionUnavailableReason = nil }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        self.tap = newTap
        self.runLoopSource = source
        scrollTapActive = true
        scrollTapIntercepts = intercepting
    }

    private func makeScrollTap(options: CGEventTapOptions) -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        return CGEvent.tapCreate(tap: .cgSessionEventTap,
                                 place: .headInsertEventTap,
                                 options: options,
                                 eventsOfInterest: mask,
                                 callback: batonScrollTapCallback,
                                 userInfo: Unmanaged.passUnretained(self).toOpaque())
    }

    private func teardownScrollTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
        scrollTapActive = false
        scrollTapIntercepts = false
    }

    private func rearmScrollTapIfNeeded() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// 在 tap 回调线程上把 CGEvent 拆成纯值，避免把非 Sendable 的 CGEvent 跨隔离域传。
    ///
    /// 单位靠 `isContinuous` 分，不能按「哪个字段非零」猜：
    /// - 离散事件（`isContinuous == 0`）：`delta` 是行数，`pointDelta` 只是系统按 1 行 = 10pt
    ///   估出来的伴随值。拿 pointDelta 再乘 40 会把一格放大 10 倍。
    /// - 像素事件（`isContinuous == 1`）：`delta` 只剩个 ±1 的符号，真正有用的是 `pointDelta`。
    nonisolated static func sample(from event: CGEvent) -> ScrollSample {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        func axis(_ index: Int) -> (value: Double, unit: ScrollUnit) {
            let lines = Double(event.getIntegerValueField(index == 1
                ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2))
            let point = event.getDoubleValueField(index == 1
                ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2)
            let fixed = event.getDoubleValueField(index == 1
                ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2)

            if !continuous {
                if lines != 0 { return (lines, .lines) }
                if fixed != 0 { return (fixed, .points) }
                return (point, .points)
            }
            if point != 0 { return (point, .points) }
            if fixed != 0 { return (fixed, .points) }
            return (lines, .lines)
        }

        let y = axis(1)
        let x = axis(2)
        // 两轴单位可能不同（竖着滚是行、横向拨是像素），按有位移的那根轴算
        let unit: ScrollUnit = y.value != 0 ? y.unit : x.unit

        return ScrollSample(
            deltaX: x.value,
            deltaY: y.value,
            unit: unit,
            isContinuous: continuous,
            phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            scrollCount: event.getIntegerValueField(.scrollWheelEventScrollCount),
            flags: event.flags.rawValue,
            sourcePID: Int32(clamping: event.getIntegerValueField(.eventSourceUnixProcessID)),
            timestamp: TimeInterval(event.timestamp) / 1_000_000_000
        )
    }

    fileprivate func ingest(_ sample: ScrollSample) {
        emit(.scroll(sample))
    }

    private func emit(_ event: InputEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }
}

private func batonScrollTapCallback(proxy: CGEventTapProxy,
                                    type: CGEventType,
                                    event: CGEvent,
                                    userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let hub = Unmanaged<EventHub>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if Thread.isMainThread {
            MainActor.assumeIsolated { hub.rearmNow() }
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

    // 自己投出去的插值事件：放行，并且不能再算一次输入（否则自激）
    if event.getIntegerValueField(.eventSourceUserData) == ScrollSmoother.magicTag {
        return Unmanaged.passUnretained(event)
    }

    let sample = EventHub.sample(from: event)
    guard Thread.isMainThread else { return Unmanaged.passUnretained(event) }

    var swallowed = false
    MainActor.assumeIsolated {
        hub.ingest(sample)
        if let interceptor = hub.scrollInterceptor {
            swallowed = interceptor(sample)
        }
    }
    return swallowed ? nil : Unmanaged.passUnretained(event)
}

extension EventHub {
    fileprivate func rearmNow() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

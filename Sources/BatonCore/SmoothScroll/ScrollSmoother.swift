import AppKit
import CoreGraphics
import Foundation
import os

/// 把离散滚轮事件改写成「一串带相位的像素位移」再投回去。
///
/// 实现的几个关键决定（对照 Mos 的 `ScrollCore` / `ScrollPoster`）：
/// 1. **不用 `isContinuous` 判断触控板**。不少鼠标驱动（含部分蓝牙鼠标、装了厂商驱动的）
///    会把滚轮事件标成连续事件，按 `isContinuous` 过滤会导致「完全没效果」。
///    真正的判据是 `phase` / `momentumPhase` / `scrollCount`：触控板必然带其中之一。
/// 2. **投递必须走 `.cghidEventTap`**。实测 `postToPid` 对 `NSScrollView` 无效——
///    事件进了进程但滚动视图不动，表现就是「拦截成功、画面不动」。
///    走 HID tap 要自己补两件东西：`location`（否则事件落在原点，按位置命中会滚错窗口）
///    和 `eventSourceUserData` 指纹（否则会被自己的 tap 再吞一遍，无限循环）。
/// 3. **按显示器刷新率逐帧投**，不是固定 8ms。8ms 在 60Hz 屏上是两帧并一帧，
///    测出来就是「一大步 + 一小步」的锯齿，看着发卡。
/// 4. **帧循环用 `CADisplayLink`，dt 取标称帧长**。不用真实间隔：主线程偶尔卡一下时，
///    按真实 dt 补偿会让下一帧一次吐出好几帧的量，看起来就是个「跳」。
@MainActor
public final class ScrollSmoother {
    /// 自投事件的指纹。"BATO"
    public nonisolated static let magicTag: Int64 = 0x4241_544F

    public private(set) var settings: SmoothScrollSettings
    public private(set) var lastSample: ScrollSample?
    /// 最近一次滚动的处理结论，给设置页做诊断
    public private(set) var lastDecision: String?
    /// 被吞掉的原始事件数（= 参与平滑的滚轮格数）
    public private(set) var swallowedTicks = 0
    /// 投递出去的插值事件数
    public var postedFrames: Int { framer.postedFrames }

    /// 会替鼠标「伪造」连续滚动特征的驱动后台进程。
    /// 这些进程发出的事件带着相位/加速度累计，按触控板处理就整段跳过平滑，
    /// 用户看到的是「开关打开但完全没效果」。
    private static let driverBundleIDs: Set<String> = [
        "com.logitech.manager.daemon",   // Logi Options+ 后台
        "com.logitech.kiyhi.manager",
        "com.logitech.LogiOptions",
        "com.steermouse.driver",
        "com.usboverdrive.driver",
    ]

    private var sourceBundleIDs: [Int32: String?] = [:]

    private let store: SmoothScrollStore?
    private let framer = ScrollFramer()

    public init(store: SmoothScrollStore?) {
        self.store = store
        self.settings = store?.load() ?? SmoothScrollSettings()
    }

    public var isEnabled: Bool { settings.enabled }

    public func setEnabled(_ enabled: Bool, persist shouldPersist: Bool = true) {
        settings.enabled = enabled
        if !enabled { finishGesture() }
        if shouldPersist { persist() }
    }

    public func apply(_ mutate: (inout SmoothScrollSettings) -> Void) {
        mutate(&settings)
        persist()
    }

    /// 返回 true 表示原事件已被吞掉，由本对象负责重放。
    public func consume(_ sample: ScrollSample) -> Bool {
        lastSample = sample

        guard settings.enabled else {
            lastDecision = "平滑滚动已关闭"
            return false
        }
        guard sample.deltaX != 0 || sample.deltaY != 0 else { return false }

        let driver = sourceBundleIDs[sample.sourcePID].flatMap { $0 }
            ?? resolvedBundleID(sample.sourcePID)
        let fromDriver = driver.map { Self.driverBundleIDs.contains($0) } ?? false
        // 触控板的滚动带相位/惯性/加速度累计，系统已经插过值，再插手会打架。
        // 但驱动补的假相位不算——那是鼠标。
        guard sample.isDiscreteMouse || settings.forceMouse || fromDriver else {
            lastDecision = "来自触控板（带相位），不接管"
            return false
        }

        let scale = settings.pointsPerLine
        // 报行数的鼠标：一行 ≈ 40pt（实测 NSScrollView 里 1 行 = 40pt）。
        // 报像素的鼠标：本身就已经是点，没有「行」可乘，只能按 40pt 为基准换算倍率——
        // 否则这个滑杆对它们完全不生效（拖到 20 和 80 一个手感）。
        let factor: Double
        switch sample.unit {
        case .lines:
            factor = scale
        case .points:
            factor = scale / SmoothScrollSettings.referencePointsPerLine
        }
        framer.push(x: sample.deltaX * factor,
                    y: sample.deltaY * factor,
                    flags: CGEventFlags(rawValue: sample.flags),
                    duration: settings.duration,
                    maxPending: settings.maxPending)

        let source = driver.map { $0.split(separator: ".").last.map(String.init) ?? $0 } ?? "滚轮"
        let amount = Int((sample.deltaY * factor).rounded())
        // 把单位写进诊断串：看不出滑杆有没有生效时，一眼能分清是「行」还是「像素」。
        let detail = sample.unit == .lines
            ? "\(Int(sample.deltaY)) 行"
            : "像素 ×\(String(format: "%.2f", factor))"
        lastDecision = "已接管：\(source) \(detail) → \(amount > 0 ? "+" : "")\(amount) 点"
        swallowedTicks += 1
        if ProcessInfo.processInfo.environment["BATON_SCROLL_DEBUG"] != nil {
            print("[consume] dy=\(sample.deltaY) factor=\(factor) unit=\(sample.unit) pid=\(sample.sourcePID)")
        }
        return true
    }

    /// 退出或关闭开关时把未释放的位移丢掉，不要留一个半程的手势。
    public func finishGesture() {
        framer.reset()
    }

    /// pid → bundle id，带缓存：每次滚动事件都查一遍 NSRunningApplication 太浪费。
    private func resolvedBundleID(_ pid: Int32) -> String? {
        guard pid > 0, pid != Int32(ProcessInfo.processInfo.processIdentifier) else { return nil }
        if let cached = sourceBundleIDs[pid] { return cached }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        if sourceBundleIDs.count > 64 { sourceBundleIDs.removeAll() }
        sourceBundleIDs[pid] = bundleID
        return bundleID
    }

    private func persist() {
        try? store?.save(settings)
    }
}

// MARK: - 逐帧投递

/// 独立于主线程的帧循环：主线程只负责「加位移」，定时器线程负责「算一帧、投一帧」。
/// 投递放在后台队列，避免和 App 自己的主线程工作抢时间导致帧间隔抖动。
final class ScrollFramer: @unchecked Sendable {
    private let lock = NSLock()

    private var engine = ScrollSmootherEngine()
    private var flags: CGEventFlags = []
    private var duration: Double = 0.32
    private var link: CADisplayLink?
    private var lastTick: CFAbsoluteTime = 0
    private var delivered = 0

    var postedFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    func push(x: Double, y: Double, flags: CGEventFlags,
              duration: Double, maxPending: Double) {
        lock.lock()
        self.flags = flags
        self.duration = duration
        engine.add(x: x, y: y, maxPending: maxPending)
        let needStart = link == nil
        lock.unlock()

        if needStart { start() }
    }

    func reset() {
        lock.lock()
        engine.reset()
        link?.invalidate()
        link = nil
        lock.unlock()
    }

    /// 帧循环跟着显示器刷新走，而不是自己开定时器。
    ///
    /// 固定 8ms/16ms 的定时器会和垂直同步打拍子：有时一帧里塞进两个事件、
    /// 有时一帧什么都没有，滚动就变成「一大步一小步」。实测改成 displayLink 之后
    /// 帧间隔抖动从 ~10ms 降到 1ms 以内。
    private func start() {
        lock.lock()
        defer { lock.unlock() }
        guard link == nil else { return }
        guard let screen = Self.screenUnderMouse() else { return }
        let newLink = screen.displayLink(target: self, selector: #selector(onFrame))
        newLink.add(to: .main, forMode: .common)
        lastTick = CFAbsoluteTimeGetCurrent()
        link = newLink
    }

    /// 帧率要跟着**鼠标所在那块屏**走：144Hz 的副屏上按 60Hz 投帧，
    /// 每三帧就有一帧是重复的，看起来反而比不平滑更顿。
    private static func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    @objc private func onFrame(_ displayLink: CADisplayLink) {
        // 用标称帧长，不用真实间隔：主线程偶尔卡一下时，
        // 按真实 dt 补偿会让下一帧一次吐出好几帧的量，看起来就是个「跳」
        tick(dt: displayLink.duration)
    }

    private func tick(dt step: Double) {
        lock.lock()
        let dt = min(max(step, 1.0 / 240.0), 1.0 / 30.0)

        let frame = engine.step(dt: dt, duration: duration)
        if frame.finished {
            link?.invalidate()
            link = nil
        }
        let flags = self.flags
        lock.unlock()

        guard frame.x != 0 || frame.y != 0 else { return }
        post(dx: frame.x, dy: frame.y, flags: flags)

        lock.lock()
        delivered += 1
        lock.unlock()
    }

    private func post(dx: Int, dy: Int, flags: CGEventFlags) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(clamping: dy),
                                  wheel2: Int32(clamping: dx),
                                  wheel3: 0) else {
            return
        }

        // AppKit 的 scrollingDeltaY 读的是 pointDelta；isContinuous 决定它按「像素」还是「行」解释
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: ScrollSmoother.magicTag)
        // 惯性相位必须清零：带 momentum 的事件会被 App 当成系统惯性，和我们的帧叠在一起
        event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: 0)
        // 新事件默认落在原点，靠位置做窗口命中时会滚错窗口
        event.location = CGEvent(source: nil)?.location ?? .zero
        event.flags = flags

        if ProcessInfo.processInfo.environment["BATON_SCROLL_DEBUG"] != nil {
            print(String(format: "[frame] dy=%d dx=%d loc=(%.0f,%.0f) front=%@",
                         dy, dx, event.location.x, event.location.y,
                         NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"))
        }

        event.post(tap: .cghidEventTap)
    }
}

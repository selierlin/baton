import AppKit
import CoreGraphics
import Foundation
import os

/// 把离散滚轮事件改写成「一串带相位的像素位移」再投回去。
///
/// 手感和 Mos 对齐，插值模型见 `ScrollSmootherEngine`：输入归一化 → 乘倍率 → 每帧
/// 只走剩余距离的一个固定比例 → 再过一道 5 点低通。
///
/// 实现的几个关键决定（对照 Mos 的 `ScrollCore` / `ScrollPoster`）：
/// 1. **不用 `isContinuous` 判断触控板**。不少鼠标驱动（含部分蓝牙鼠标、装了厂商驱动的）
///    会把滚轮事件标成连续事件，按 `isContinuous` 过滤会导致「完全没效果」。
///    真正的判据是 `phase` / `momentumPhase` / `scrollCount`：触控板必然带其中之一。
/// 2. **投递必须走 `.cghidEventTap`**。实测 `postToPid` 对 `NSScrollView` 无效——
///    事件进了进程但滚动视图不动，表现就是「拦截成功、画面不动」。
///    走 HID tap 要自己补两件东西：`location`（否则事件落在原点，按位置命中会滚错窗口）
///    和 `eventSourceUserData` 指纹（否则会被自己的 tap 再吞一遍，无限循环）。
/// 3. **每帧投的是小数**。Mos 也是把 `pointDelta` 写成 Double；取整会让慢速滚动出现
///    「0,0,1,0,0,1」这种一格格挪的台阶，是最容易被察觉的不丝滑。
/// 4. **按显示器刷新率逐帧投**，不是固定 8ms。8ms 在 60Hz 屏上是两帧并一帧，
///    测出来就是「一大步 + 一小步」的锯齿，看着发卡。
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

        // 两种单位不能套同一个倍率：
        //
        // - 报行数的鼠标：一格（1 行或 3 行）都归一到「一个基准格」再乘倍率，
        //   这是 Mos 的归一化，让不同鼠标一格的位移一致。
        // - 报像素的鼠标：它给的就是点，本来已经和屏幕 1:1。再乘 3.6 会直接快 3 倍，
        //   所以这里只按「倍率相对默认档的比值」做微调，默认档等于 1:1（和 0.1.x 一致）。
        let reference = SmoothScrollSettings().speed
        func points(_ raw: Double, _ unit: ScrollUnit) -> Double {
            guard raw != 0 else { return 0 }
            switch unit {
            case .lines:
                return (raw < 0 ? -1 : 1) * SmoothScrollSettings.referenceStep * settings.speed
            case .points:
                return raw * settings.speed / reference
            }
        }
        let tickY = points(sample.deltaY, sample.unit)
        framer.push(x: points(sample.deltaX, sample.unit),
                    y: tickY,
                    flags: CGEventFlags(rawValue: sample.flags),
                    trans: settings.trans,
                    deadZone: settings.deadZone)

        let source = driver.map { $0.split(separator: ".").last.map(String.init) ?? $0 } ?? "滚轮"
        // 诊断串写这一格实际走了多少点：滑杆有没有生效、单位认没认对，一眼能看出来
        let detail = sample.unit == .lines
            ? "\(Int(abs(sample.deltaY).rounded())) 行"
            : "\(Int(abs(sample.deltaY).rounded())) 像素"
        let amount = Int(tickY.rounded())
        lastDecision = "已接管：\(source) \(detail) → \(amount > 0 ? "+" : "")\(amount) 点"
        swallowedTicks += 1
        if ProcessInfo.processInfo.environment["BATON_SCROLL_DEBUG"] != nil {
            print("[consume] dy=\(sample.deltaY) unit=\(sample.unit) pid=\(sample.sourcePID) tick=\(tickY)")
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
    private var trans: Double = 0.085
    private var deadZone: Double = 1
    private var link: CADisplayLink?
    private var lastTick: CFAbsoluteTime = 0
    private var delivered = 0
    /// 还没攒够死区的位移，下一帧一起投
    private var carry = (x: 0.0, y: 0.0)

    var postedFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    func push(x: Double, y: Double, flags: CGEventFlags,
              trans: Double, deadZone: Double) {
        lock.lock()
        self.flags = flags
        self.trans = trans
        self.deadZone = deadZone
        engine.add(x: x, y: y)
        let needStart = link == nil
        lock.unlock()

        if needStart { start() }
    }

    func reset() {
        lock.lock()
        engine.reset()
        carry = (0, 0)
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

        // 比例是按「一帧 1/60 秒」定的。120Hz 屏上每帧还是吃同样比例的话，
        // 同样一段时间里就多吃一倍，滚动速度翻倍、尾巴只剩一半——换算成等效比例。
        let effective = 1 - pow(1 - trans, dt * 60)
        let frame = engine.step(trans: effective, dt: dt, deadZone: deadZone)
        if frame.finished {
            link?.invalidate()
            link = nil
        }
        let flags = self.flags
        let dead = deadZone
        // 低于死区的帧先攒着，不要就地丢掉：指数尾巴最后会连续几十帧都不足 1pt，
        // 一帧一帧丢等于把这一格的距离偷偷扣掉 8%（实测 3 格少走 11pt）。
        let dx = frame.x + carry.x
        let dy = frame.y + carry.y
        let leftover = frame.finished && abs(dx) + abs(dy) >= 0.3
        let shouldPost = abs(dx) > dead || abs(dy) > dead || leftover
        // 收尾时剩下的零点几磅一次补掉，不然永远发不出去
        carry = shouldPost ? (0, 0) : (dx, dy)
        if shouldPost { delivered += 1 }
        lock.unlock()

        guard shouldPost else { return }
        post(dx: dx, dy: dy, flags: flags)
    }

    private func post(dx: Double, dy: Double, flags: CGEventFlags) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(clamping: Int(dy.rounded())),
                                  wheel2: Int32(clamping: Int(dx.rounded())),
                                  wheel3: 0) else {
            return
        }

        // AppKit 的 scrollingDeltaY 读的是 pointDelta；isContinuous 决定它按「像素」还是「行」解释。
        // 这里必须写 Double：取整是慢速滚动出现台阶声/台阶感的直接原因。
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: ScrollSmoother.magicTag)
        // 惯性相位必须清零：带 momentum 的事件会被 App 当成系统惯性，和我们的帧叠在一起
        event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: 0)
        // 新事件默认落在原点，靠位置做窗口命中时会滚错窗口
        event.location = CGEvent(source: nil)?.location ?? .zero
        event.flags = flags

        if ProcessInfo.processInfo.environment["BATON_SCROLL_DEBUG"] != nil {
            print(String(format: "[frame] dy=%.2f dx=%.2f loc=(%.0f,%.0f)",
                         dy, dx, event.location.x, event.location.y))
        }

        event.post(tap: .cghidEventTap)
    }
}

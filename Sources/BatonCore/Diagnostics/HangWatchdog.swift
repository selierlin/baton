import Foundation

/// 主线程卡顿看门狗。
///
/// 用户说「卡住了」时，最糟的情况是日志直接断掉——看不出卡在哪、卡了多久。
/// 这里用后台队列每 2 秒给主线程塞一个空 block：只要主线程还能跑，计数就在涨；
/// 连续 8 秒不涨就写一条 `main.stall`，至少能把「什么时候开始卡、卡了多久」留在日志里。
///
/// 注意：模态循环（`runModal`）期间主队列照常被服务，所以「弹了个看不见的框」
/// 不会触发这里，那种情况靠 `ModalAlert` 的 open/close 配对来发现。
public final class HangWatchdog: @unchecked Sendable {
    public static let shared = HangWatchdog()

    private let queue = DispatchQueue(label: "com.selier.baton.watchdog", qos: .utility)
    private let lock = NSLock()
    private var beats = 0
    /// 正在等用户点按钮的模态框数量。`runModal` 会占用主队列，此时「主线程不动」
    /// 是正常的，不能报卡顿——否则每个开着没点的对话框都会刷一条 main.stall。
    private var modalDepth = 0
    private var timer: DispatchSourceTimer?
    private var lastSeen = -1
    private var stuckSince: Date?
    private var lastReport: Date?

    private let interval: TimeInterval = 2
    private let threshold: TimeInterval = 8
    private let repeatGap: TimeInterval = 30

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval)
            source.setEventHandler { [weak self] in self?.probe() }
            source.resume()
            timer = source
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func bump() {
        lock.lock()
        beats &+= 1
        lock.unlock()
    }

    private func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return beats
    }

    /// 模态框进出时调用：模态期间不算卡顿。
    public func modalEntered() {
        lock.lock()
        modalDepth += 1
        lock.unlock()
    }

    public func modalExited() {
        lock.lock()
        modalDepth = max(0, modalDepth - 1)
        lock.unlock()
    }

    private func probe() {
        lock.lock()
        let waiting = modalDepth > 0
        lock.unlock()
        if waiting {
            // 用户还没点按钮，主线程本来就该停着。等关掉之后重新基准，别记成 recovered
            lastSeen = -1
            stuckSince = nil
            DispatchQueue.main.async { [weak self] in self?.bump() }
            return
        }

        let current = value()
        if current == lastSeen {
            if stuckSince == nil {
                stuckSince = Date()
            } else if let since = stuckSince {
                let stalled = Date().timeIntervalSince(since)
                let cooled = lastReport.map { Date().timeIntervalSince($0) >= repeatGap } ?? true
                if stalled >= threshold, cooled {
                    lastReport = Date()
                    ActionLog.fail("main.stall", "seconds=\(Int(stalled)) beats=\(current)")
                }
            }
        } else {
            if stuckSince != nil {
                let recovered = Date().timeIntervalSince(stuckSince ?? Date())
                ActionLog.result("main.recovered", "seconds=\(Int(recovered))")
            }
            lastSeen = current
            stuckSince = nil
        }
        // 下一轮要看到这个 block 真的被执行过，计数才会涨
        DispatchQueue.main.async { [weak self] in self?.bump() }
    }
}

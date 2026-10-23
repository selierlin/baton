import XCTest
@testable import BatonCore

final class ScrollSmootherEngineTests: XCTestCase {
    private let frame = 1.0 / 120.0

    func testConsumesAllPendingWithinDuration() {
        var engine = ScrollSmootherEngine()
        engine.add(x: 0, y: 120, maxPending: 320)

        var total = 0
        var frames = 0
        while frames < 200 {
            let out = engine.step(dt: frame, duration: 0.18)
            total += out.y
            frames += 1
            if out.finished { break }
        }

        XCTAssertTrue(engine.isIdle)
        XCTAssertEqual(total, 120, accuracy: 2)
        // 3τ ≈ 0.18s ≈ 22 帧；留一倍余量
        XCTAssertLessThan(frames, 45)
    }

    func testDirectionIsPreserved() {
        var engine = ScrollSmootherEngine()
        engine.add(x: 0, y: -80, maxPending: 320)

        var total = 0
        for _ in 0..<100 {
            let out = engine.step(dt: frame, duration: 0.18)
            total += out.y
            if out.finished { break }
        }
        XCTAssertLessThan(total, 0)
        XCTAssertEqual(total, -80, accuracy: 2)
    }

    func testPendingIsClamped() {
        var engine = ScrollSmootherEngine()
        // 连滚 20 格，每格 40 pt = 800，超过上限 320
        for _ in 0..<20 {
            engine.add(x: 0, y: 40, maxPending: 320)
        }
        XCTAssertEqual(engine.pendingY, 320, accuracy: 0.001)
        let out = engine.step(dt: 0.05, duration: 0.18)
        XCTAssertLessThanOrEqual(out.y, 320)
    }

    func testStartsFastAndSlowsDown() {
        var fast = ScrollSmootherEngine()
        fast.add(x: 0, y: 200, maxPending: 400)
        let first = fast.step(dt: frame, duration: 0.18).y

        var slow = ScrollSmootherEngine()
        slow.add(x: 0, y: 200, maxPending: 400)
        var last = 0
        for _ in 0..<20 {
            let out = slow.step(dt: frame, duration: 0.18)
            if out.finished { break }
            last = out.y
        }

        XCTAssertGreaterThan(first, last)
    }

    func testHorizontalAxisIsIndependent() {
        var engine = ScrollSmootherEngine()
        engine.add(x: 60, y: 0, maxPending: 320)
        let out = engine.step(dt: frame, duration: 0.18)
        XCTAssertEqual(out.y, 0)
        XCTAssertGreaterThan(out.x, 0)
    }

    /// 老配置里的 0.18s 是旧默认值，读回来要升级成新默认，否则升级后手感没变化
    func testLegacyDurationIsMigrated() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-scroll-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SmoothScrollStore(directory: dir)
        var old = SmoothScrollSettings()
        old.duration = 0.18
        try store.save(old)

        XCTAssertEqual(store.load().duration, SmoothScrollSettings().duration, accuracy: 0.001)
        // 用户自己调过的值不能动
        var custom = SmoothScrollSettings()
        custom.duration = 0.22
        try store.save(custom)
        XCTAssertEqual(store.load().duration, 0.22, accuracy: 0.001)
    }

    /// 老版本 `scroll.json` 里没有 `forceMouse`：缺字段不能让整份配置解码失败，
    /// 否则用户调过的参数会被默认值顶掉。
    func testSettingsWithoutForceMouseDecode() throws {
        let json = #"{"enabled":true,"pointsPerLine":55,"duration":0.4,"maxPending":300}"#
        let settings = try JSONDecoder().decode(SmoothScrollSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.pointsPerLine, 55, accuracy: 0.001)
        XCTAssertEqual(settings.duration, 0.4, accuracy: 0.001)
        XCTAssertEqual(settings.maxPending, 300, accuracy: 0.001)
        XCTAssertFalse(settings.forceMouse)
    }

    func testSettingsRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-scroll-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SmoothScrollStore(directory: dir)
        var settings = SmoothScrollSettings()
        settings.enabled = false
        settings.pointsPerLine = 55
        try store.save(settings)

        XCTAssertEqual(store.load(), settings)
    }
}

@MainActor
final class ScrollSmootherFilterTests: XCTestCase {
    private func sample(deltaY: Double,
                        unit: ScrollUnit = .lines,
                        isContinuous: Bool = false,
                        phase: Int64 = 0,
                        momentum: Int64 = 0,
                        scrollCount: Int64 = 0) -> ScrollSample {
        ScrollSample(deltaX: 0,
                     deltaY: deltaY,
                     unit: unit,
                     isContinuous: isContinuous,
                     phase: phase,
                     momentum: momentum,
                     scrollCount: scrollCount,
                     timestamp: 0)
    }

    func testTrackpadIsPassedThrough() {
        let smoother = ScrollSmoother(store: nil)
        // 触控板靠相位/惯性/加速度累计判定，不靠 isContinuous
        XCTAssertFalse(smoother.consume(sample(deltaY: 3, isContinuous: true, phase: 2)))
        XCTAssertFalse(smoother.consume(sample(deltaY: 3, momentum: 1)))
        XCTAssertFalse(smoother.consume(sample(deltaY: 3, scrollCount: 4)))
        XCTAssertEqual(smoother.swallowedTicks, 0)
    }

    /// 装了厂商驱动的鼠标会把事件标成连续，这类事件必须照样平滑，否则用户就是「没效果」
    func testMouseReportingContinuousStillGetsSmoothed() {
        let smoother = ScrollSmoother(store: nil)
        XCTAssertTrue(smoother.consume(sample(deltaY: 1, isContinuous: true)))
        XCTAssertEqual(smoother.swallowedTicks, 1)
        smoother.finishGesture()
    }

    func testDisabledPassesThrough() {
        let smoother = ScrollSmoother(store: nil)
        smoother.setEnabled(false, persist: false)
        XCTAssertFalse(smoother.consume(sample(deltaY: 3)))
    }

    func testDiscreteWheelIsSwallowed() {
        let smoother = ScrollSmoother(store: nil)
        XCTAssertTrue(smoother.consume(sample(deltaY: 3)))
        XCTAssertEqual(smoother.swallowedTicks, 1)
        // 不让定时器跑起来，把残留清掉
        smoother.finishGesture()
    }

    func testZeroDeltaIsPassedThrough() {
        let smoother = ScrollSmoother(store: nil)
        XCTAssertFalse(smoother.consume(sample(deltaY: 0)))
    }

    /// 驱动把鼠标事件补上相位后会被误判成触控板——这是「开关打开却没效果」的典型原因，
    /// 兜底开关必须能强行接管，并把判断结果写进诊断文案。
    func testForceMouseOverridesTrackpadHeuristic() {
        let smoother = ScrollSmoother(store: nil)
        XCTAssertFalse(smoother.consume(sample(deltaY: 2, phase: 1)))
        XCTAssertEqual(smoother.lastDecision, "来自触控板（带相位），不接管")

        smoother.apply { $0.forceMouse = true }
        XCTAssertTrue(smoother.consume(sample(deltaY: 2, phase: 1)))
        XCTAssertEqual(smoother.swallowedTicks, 1)
        XCTAssertTrue(smoother.lastDecision?.hasPrefix("已接管") ?? false)
        smoother.finishGesture()
    }

    /// 报像素的滚轮（高分辨率滚轮、驱动重写的事件）没有「行」可乘。
    /// 之前这里 factor 恒为 1，滑杆对它完全无效——用户反馈「拖每行滚动没区别」就是这个。
    /// 现在按 40pt = 1.0 倍换算，滑杆对两种单位都生效。
    func testPixelUnitRespectsPointsPerLineAsMultiplier() {
        let smoother = ScrollSmoother(store: nil)
        XCTAssertTrue(smoother.consume(sample(deltaY: 100, unit: .points, isContinuous: true)))
        XCTAssertEqual(smoother.lastDecision, "已接管：滚轮 像素 ×1.00 → +100 点")
        smoother.finishGesture()

        smoother.apply { $0.pointsPerLine = 80 }
        XCTAssertTrue(smoother.consume(sample(deltaY: 100, unit: .points, isContinuous: true)))
        XCTAssertEqual(smoother.lastDecision, "已接管：滚轮 像素 ×2.00 → +200 点")
        smoother.finishGesture()

        smoother.apply { $0.pointsPerLine = 20 }
        XCTAssertTrue(smoother.consume(sample(deltaY: 100, unit: .points, isContinuous: true)))
        XCTAssertEqual(smoother.lastDecision, "已接管：滚轮 像素 ×0.50 → +50 点")
        smoother.finishGesture()
    }

    /// 离散事件的 delta 是行数，pointDelta 只是系统按 1 行=10pt 估的伴随值。
    /// 认错单位会把一格放大 10 倍——这是「滚起来飞掉」而不是「不丝滑」。
    func testDiscreteSampleUsesLinesNotPointDelta() {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                  wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0) else {
            return XCTFail("造不出滚动事件")
        }
        let sample = EventHub.sample(from: event)
        XCTAssertEqual(sample.unit, .lines)
        XCTAssertEqual(sample.deltaY, -3, accuracy: 0.001)
        XCTAssertTrue(sample.isDiscreteMouse)
    }

    func testPixelSampleUsesPointDelta() {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: -12, wheel2: 0, wheel3: 0) else {
            return XCTFail("造不出滚动事件")
        }
        let sample = EventHub.sample(from: event)
        XCTAssertEqual(sample.unit, .points)
        XCTAssertEqual(sample.deltaY, -12, accuracy: 0.5)
    }
}

import XCTest
@testable import BatonCore

/// 逐帧轨迹测试：对照 Mos 的模型验算，而不是「看起来对不对」。
final class ScrollSmootherEngineTests: XCTestCase {
    private let hz60 = 1.0 / 60.0

    /// 跑一段输入，返回逐帧投递的位移。默认死区取实际设置值 1pt
    private func trace(_ engine: inout ScrollSmootherEngine,
                       trans: Double,
                       frames: Int = 200,
                       deadZone: Double = 1.0) -> [Double] {
        var out: [Double] = []
        for _ in 0..<frames {
            let frame = engine.step(trans: trans, dt: hz60, deadZone: deadZone)
            out.append(frame.y)
            if frame.finished { break }
        }
        return out
    }

    /// Mos 的公式：1 - sqrt(duration / 5.2)
    func testTransMatchesMosFormula() {
        XCTAssertEqual(SmoothScrollSettings(speed: 3.6, duration: 4.35).trans, 0.0854, accuracy: 0.0005)
        XCTAssertEqual(SmoothScrollSettings(speed: 3.6, duration: 0.5).trans, 0.6899, accuracy: 0.001)
        // 拉到头也不能到 1，否则一帧吃完、等于没有平滑
        XCTAssertLessThan(SmoothScrollSettings(speed: 3.6, duration: 5.0).trans, 0.05)
    }

    func testOneTickTravelsItsDistance() {
        var engine = ScrollSmootherEngine()
        engine.add(x: 0, y: 90.7)

        let frames = trace(&engine, trans: SmoothScrollSettings().trans)
        let total = frames.reduce(0, +)
        // 死区 1pt 会吃掉最后不到 1pt 的尾量（Mos 同样如此），留 2pt 余量
        XCTAssertEqual(total, 90.7, accuracy: 2.0)
        XCTAssertTrue(engine.isIdle)
    }

    /// 关键回归：每帧必须是小数。
    /// 取整的旧实现在慢速滚动时会出现 0,0,1,0,0,1 的台阶，这是最容易被看出来的不丝滑。
    func testFramesAreFractionalNotRounded() {
        var engine = ScrollSmootherEngine()
        engine.add(x: 0, y: 90.7)

        let frames = trace(&engine, trans: SmoothScrollSettings().trans)
        let fractional = frames.filter { abs($0 - $0.rounded()) > 0.05 }
        XCTAssertGreaterThan(fractional.count, 8, "大部分帧应该带着小数，而不是整点跳")
    }

    /// 起手不能被抹掉：Mos 的低通只削峰，不该把第一段变成 0 之后又长时间不动
    func testMotionStartsWithinTwoFramesAndThenDecays() {
        var engine = ScrollSmootherEngine()
        engine.add(x: 0, y: 90.7)

        let frames = trace(&engine, trans: SmoothScrollSettings().trans)
        // 低通第一帧必然是 0（窗口只有两个零点），第二帧开始有位移
        XCTAssertLessThan(abs(frames[0]), 0.001)
        XCTAssertGreaterThan(frames[1], 0.5)

        // 峰值出现在第 4 帧左右：前几帧是低通的爬坡，之后单调衰减
        let peak = frames.max() ?? 0
        let peakIndex = frames.firstIndex(of: peak) ?? 0
        XCTAssertGreaterThanOrEqual(peakIndex, 3)
        XCTAssertLessThan(frames[peakIndex], 8, "峰值不该超过一格的一半，否则起手就是「窜」")
        XCTAssertLessThan(frames.last ?? 0, peak * 0.05)
    }

    /// 尾巴要够长：Mos 默认档在 60Hz 下大约 40 帧才停，旧实现 15 帧就停，
    /// 「滑一下就没了」是用户说不够丝滑的直接来源
    func testTailLastsLongEnough() {
        var engine = ScrollSmootherEngine()
        engine.add(x: 0, y: 90.7)

        let frames = trace(&engine, trans: SmoothScrollSettings().trans, frames: 200)
        XCTAssertGreaterThan(frames.count, 25)
        XCTAssertLessThan(frames.count, 90)
    }

    /// 同方向连滚要累加，不能每格重置（否则快速连滚的总位移比手滚的还少）
    func testSameDirectionAccumulates() {
        var engine = ScrollSmootherEngine()
        engine.add(x: 0, y: 90)
        _ = engine.step(trans: 0.0854, dt: hz60, deadZone: 1)
        engine.add(x: 0, y: 90)

        XCTAssertEqual(engine.target.y, 180, accuracy: 0.001)
    }

    /// 反向要立刻有劲：Mos 在反向时把当前位置清零，
    /// 不清的话往回滚第一下要先抵消没走完的正向位移，手感就是「没反应」
    func testReverseGetsFullResponse() {
        var engine = ScrollSmootherEngine()
        engine.add(x: 0, y: 90)
        for _ in 0..<4 {
            _ = engine.step(trans: 0.0854, dt: hz60, deadZone: 1)
        }
        engine.add(x: 0, y: -90)

        XCTAssertEqual(engine.target.y, -90, accuracy: 0.001)
        XCTAssertEqual(engine.current.y, 0, accuracy: 0.001)

        // 低通窗口里还压着正向的几帧，会先漏出一点余量（Mos 也是这样），
        // 但 8 帧（约 130ms）之内必须整体转向
        var out: [Double] = []
        for _ in 0..<8 {
            out.append(engine.step(trans: 0.0854, dt: hz60, deadZone: 1).y)
        }
        XCTAssertLessThan(out.reduce(0, +), 0, "反向 8 帧内合计必须为负，不能还在往前溜")
        XCTAssertLessThan(out.last ?? 0, 0)
    }

    func testHorizontalAxisIsIndependent() {
        var engine = ScrollSmootherEngine()
        engine.add(x: 60, y: 0)
        let out = engine.step(trans: 0.0854, dt: hz60, deadZone: 0.001)
        XCTAssertEqual(out.y, 0, accuracy: 0.0001)
    }

    func testIdleAfterSettling() {
        var engine = ScrollSmootherEngine()
        engine.add(x: 0, y: 10)
        _ = trace(&engine, trans: 0.0854)
        XCTAssertTrue(engine.isIdle)
        XCTAssertEqual(engine.residual.y, 0, accuracy: 0.001)
    }

    // MARK: - 配置

    /// 0.1.x 的 scroll.json：duration 是秒（0.4），新模型是 0.5–5.0 的档位。
    /// 按同一个键硬读会得到「一帧吃掉 76%」，滚起来像瞬移。
    func testLegacySettingsAreMigrated() throws {
        let json = #"{"enabled":true,"pointsPerLine":55,"duration":0.4,"maxPending":300}"#
        let settings = try JSONDecoder().decode(SmoothScrollSettings.self, from: Data(json.utf8))

        // 距离保持：55 点/行 × 3 行 → 一格还是 165 点
        XCTAssertEqual(settings.pointsPerTick, 165, accuracy: 0.01)
        // 时长回到新默认档，不能把 0.4 秒当成 0.4 档
        XCTAssertEqual(settings.duration, SmoothScrollSettings().duration, accuracy: 0.001)
        XCTAssertEqual(settings.trans, SmoothScrollSettings().trans, accuracy: 0.001)
    }

    /// 老默认 40 点/行 换算出来 120 点一格，和系统默认一样，也和新的默认倍率对得上
    func testUntouchedLegacySettingsKeepTheSameDistance() throws {
        let json = #"{"enabled":true,"pointsPerLine":40,"duration":0.3,"maxPending":320}"#
        let settings = try JSONDecoder().decode(SmoothScrollSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.pointsPerTick, 120, accuracy: 0.01)
        XCTAssertEqual(settings.pointsPerTick, SmoothScrollSettings().pointsPerTick, accuracy: 1.5)
    }

    func testSettingsRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-scroll-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SmoothScrollStore(directory: dir)
        var settings = SmoothScrollSettings()
        settings.enabled = false
        settings.speed = 1.8
        settings.duration = 3.2
        settings.deadZone = 0.5
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

    /// 一格 1 行和 3 行的两种鼠标，走的距离必须一样——这是 Mos 的归一化。
    /// 不归一化的话换个鼠标手感就变了。
    func testLineCountsAreNormalizedToOneTick() {
        let smoother = ScrollSmoother(store: nil)
        XCTAssertTrue(smoother.consume(sample(deltaY: 1)))
        let one = smoother.lastDecision
        smoother.finishGesture()

        XCTAssertTrue(smoother.consume(sample(deltaY: 3)))
        let three = smoother.lastDecision
        smoother.finishGesture()

        // 两种行数归一到同一格，诊断串里报的位移必须一样
        XCTAssertEqual(one?.split(separator: "→").last, three?.split(separator: "→").last)
        XCTAssertEqual(smoother.settings.pointsPerTick, 120.96, accuracy: 0.1)
    }

    /// 高分辨率滚轮报的是点，同样按「不低于基准格」处理，再乘倍率
    func testPixelUnitIsScaledBySpeed() {
        let smoother = ScrollSmoother(store: nil)
        XCTAssertTrue(smoother.consume(sample(deltaY: 100, unit: .points, isContinuous: true)))
        XCTAssertEqual(smoother.lastDecision, "已接管：滚轮 100 像素 → +100 点")
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

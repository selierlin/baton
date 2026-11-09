import CoreGraphics
import Foundation

/// 平滑滚动参数。照着 Mos 的三段式（归一化 → 倍率 → 比例逼近）复刻。
///
/// 只作用于**离散滚轮**事件。触控板/妙控板本来就是连续事件，系统自己会插值并带惯性，
/// 再插手只会变成双重平滑。
public struct SmoothScrollSettings: Codable, Sendable, Equatable {
    /// 「一格」的基准位移（pt）。比这小的滚轮事件会被抬到这个值再乘倍率。
    ///
    /// 各家鼠标报的行高不一样：同一台机器上罗技报 1 行、杂牌报 3 行，不归一化的话
    /// 换个鼠标手感就变了。Mos 也是这么干的（`step = 33.6`）。
    public static let referenceStep: Double = 33.6

    /// 平滑时长换算成每帧比例时的上界，对应公式里的 `5.0 + 0.2` 偏移。
    /// 加这个偏移是为了让滑杆拉到最右时比例接近 0 而不是正好 0（否则完全滚不动）。
    public static let durationCeiling: Double = 5.2

    public var enabled: Bool
    /// 每格位移倍率。一格实际走 `referenceStep * speed` 点。
    public var speed: Double
    /// 平滑时长（0.5–5.0），越大尾巴越长、越「飘」，越小越跟手。
    public var duration: Double
    /// 死区（pt）：小于它的帧不投，避免亚像素噪声让滚动条抖。
    public var deadZone: Double
    /// 无论来源一律按鼠标处理。
    ///
    /// 有些鼠标（厂商驱动重写过事件、远程桌面注入的事件）会带上相位字段，
    /// 被判定成触控板后整段跳过平滑——表现就是「开关打开但毫无效果」。
    /// 用户确认自己用的是滚轮鼠标时打开这一项兜底。
    public var forceMouse: Bool

    /// 一格滚多远，给界面显示用。
    public var pointsPerTick: Double { Self.referenceStep * speed }

    /// 每帧吃掉剩余距离的比例。
    ///
    /// Mos 的公式：`1 - sqrt(duration / 5.2)`，默认 4.35 档算出来是 0.0854，
    /// 60Hz 下 8.5%/帧，约 0.19s 的时间常数、0.6s 左右彻底停下。
    /// 这个「缓」正是丝滑的来源——比指数衰减的 15%/帧长得多的尾巴。
    public var trans: Double {
        let clamped = min(max(duration, 0.05), 5.0)
        return 1 - (clamped / Self.durationCeiling).squareRoot()
    }

    /// 默认倍率取 3.6：一格约 121pt，和系统默认（约 128pt）几乎一样。
    /// Mos 自己默认 2.70（90pt），比 macOS 的滚动手感慢一截，直接用会让人觉得「变迟钝了」。
    /// 复刻的是它的曲线，速度沿用用户原来那档。
    public init(enabled: Bool = true,
                speed: Double = 3.60,
                duration: Double = 4.35,
                deadZone: Double = 1.0,
                forceMouse: Bool = false) {
        self.enabled = enabled
        self.speed = speed
        self.duration = duration
        self.deadZone = deadZone
        self.forceMouse = forceMouse
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, speed, duration, deadZone, forceMouse
        // 老版本的字段，只为迁移时能认出来
        case pointsPerLine, maxPending
    }

    /// 手写解码：两件事不能丢。
    ///
    /// 1. 缺字段用默认值补，不能让整份配置解码失败——那样用户调好的参数会被默认值顶掉。
    /// 2. 0.1.x 的 `scroll.json` 里 `duration` 是**秒**（0.30），新模型里是 0.5–5.0 的档位。
    ///    直接按同一个键读会得到 `trans = 0.76`（一帧吃掉 76%），滚起来像瞬移。
    ///    所以靠老字段 `pointsPerLine` 认出旧结构，再把距离换算过去。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SmoothScrollSettings()

        if let legacyPerLine = try container.decodeIfPresent(Double.self, forKey: .pointsPerLine) {
            // 旧结构：pointsPerLine 是「一行多少点」，一格（通常 3 行）的距离 = pointsPerLine × 3。
            // 新结构里一格 = step × speed，把 speed 反解出来，距离保持不变——
            // 升级后手感只该变顺，不该变慢。
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
            speed = max(legacyPerLine, 1) * 3 / Self.referenceStep
            duration = fallback.duration
            deadZone = try container.decodeIfPresent(Double.self, forKey: .deadZone) ?? fallback.deadZone
            forceMouse = try container.decodeIfPresent(Bool.self, forKey: .forceMouse) ?? fallback.forceMouse
            return
        }

        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? fallback.speed
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? fallback.duration
        deadZone = try container.decodeIfPresent(Double.self, forKey: .deadZone) ?? fallback.deadZone
        forceMouse = try container.decodeIfPresent(Bool.self, forKey: .forceMouse) ?? fallback.forceMouse
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(speed, forKey: .speed)
        try container.encode(duration, forKey: .duration)
        try container.encode(deadZone, forKey: .deadZone)
        try container.encode(forceMouse, forKey: .forceMouse)
    }
}

public struct SmoothScrollStore: Sendable {
    public let url: URL

    public init(directory: URL? = nil) throws {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            dir = base.appendingPathComponent("Baton", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("scroll.json")
    }

    public func load() -> SmoothScrollSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(SmoothScrollSettings.self, from: data) else {
            return SmoothScrollSettings()
        }
        return settings
    }

    public func save(_ settings: SmoothScrollSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

/// 纯计算部分：把「一次滚轮位移」摊成若干帧。抽出来是为了能单测，
/// 也避免插值逻辑和 CGEvent 生命周期缠在一起。
///
/// 模型和 Mos 的 `ScrollPoster` 一致：维护一个「目标位置」和一个「已经走到哪」，
/// 每帧只走两者差值的一个固定比例。比例小，尾巴就长；比例大，跟手但生硬。
struct ScrollSmootherEngine {
    /// 目标位置（Mos 叫 buffer）。同方向连滚会一直累加。
    private(set) var target = (y: 0.0, x: 0.0)
    /// 已经投出去的位置（Mos 叫 current）。
    private(set) var current = (y: 0.0, x: 0.0)
    /// 上一格的符号，用来判断同向累加还是反向重置。
    private var last = (y: 0.0, x: 0.0)
    /// 输出低通。Mos 的 ScrollFilter，专门去掉起手那一下的抖动。
    private var filter = ScrollOutputFilter()

    var residual: (y: Double, x: Double) {
        (y: target.y - current.y, x: target.x - current.x)
    }

    var isIdle: Bool {
        abs(target.y - current.y) < 0.001 && abs(target.x - current.x) < 0.001
    }

    /// 收到一格输入。
    ///
    /// 同方向累加到目标上；反方向直接把目标换成新的、并把「已走位置」清零。
    /// 反向清零这一步很关键：不清的话反向的那格要先抵消掉还没走完的正向位移，
    /// 手感就是「往回滚第一下没反应」。
    mutating func add(x: Double, y: Double) {
        if y * last.y > 0 {
            target.y += y
        } else {
            target.y = y
            current.y = 0
        }
        if x * last.x > 0 {
            target.x += x
        } else {
            target.x = x
            current.x = 0
        }
        last = (y: y, x: x)
    }

    /// 返回本帧应投递的位移（小数，不再取整）。`finished` 表示已经收敛。
    ///
    /// - Parameter trans: 每帧逼近比例，由 `settings.trans` 给出（60Hz 基准）。
    /// - Parameter dt: 实际帧长。high refresh 屏幕上按 60Hz 基准折算，
    ///   否则 120Hz 屏每帧还是吃同样的比例，滚动速度会翻倍、尾巴只剩一半。
    mutating func step(trans: Double, dt: Double, deadZone: Double) -> (x: Double, y: Double, finished: Bool) {
        let frameY = (target.y - current.y) * trans
        let frameX = (target.x - current.x) * trans
        current.y += frameY
        current.x += frameX

        // 低通有 3 帧左右的延迟，收敛判断要等它一起停下来，否则尾巴会被硬截断
        let out = filter.fill(y: frameY, x: frameX)
        let remaining = max(abs(target.y - current.y), abs(target.x - current.x))
        let settled = remaining <= deadZone
            && abs(out.y) <= deadZone
            && abs(out.x) <= deadZone

        if settled { reset() }
        return (out.x, out.y, settled)
    }

    mutating func reset() {
        target = (0, 0)
        current = (0, 0)
        last = (0, 0)
        filter.reset()
    }
}

/// Mos 的 `ScrollFilter`：曲线峰值滤波。
///
/// 每次在「上一帧的输出」和「这一帧的输入」之间插 5 个点，只吐出第二个，
/// 相当于把一步拆成 0.23 / 0.5 / 0.77 / 1.0 四小步走完。
/// 单看是加了 3 帧延迟，实际效果是起手那一下被抹平——没有它，
/// 每格滚轮的第一帧就是最大值，看着像「顿一下再滑」。
struct ScrollOutputFilter {
    private var windowY: [Double] = [0, 0]
    private var windowX: [Double] = [0, 0]

    mutating func fill(y: Double, x: Double) -> (y: Double, x: Double) {
        windowY = Self.polish(windowY, with: y)
        windowX = Self.polish(windowX, with: x)
        return (windowY[0], windowX[0])
    }

    mutating func reset() {
        windowY = [0, 0]
        windowX = [0, 0]
    }

    private static func polish(_ window: [Double], with next: Double) -> [Double] {
        let first = window[1]
        let diff = next - first
        return [first, first + 0.23 * diff, first + 0.5 * diff, first + 0.77 * diff, next]
    }
}

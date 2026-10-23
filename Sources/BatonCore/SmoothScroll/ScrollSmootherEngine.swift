import CoreGraphics
import Foundation

/// 平滑滚动参数。
///
/// 只作用于**离散滚轮**事件（`isContinuous == 0`）。触控板/妙控板本来就是连续事件，
/// 系统自己会插值并带惯性，再插手只会变成双重平滑。
public struct SmoothScrollSettings: Codable, Sendable, Equatable {
    /// 手感基准：40 pt 视为「1.0 倍」。
    ///
    /// 报行数的鼠标（`unit == .lines`）直接拿 `pointsPerLine` 当每行点数；
    /// 报像素的鼠标（高分辨率滚轮、驱动重写过的事件）没有「行」的概念，
    /// 只能拿这个基准把 `pointsPerLine` 换算成倍率，否则滑杆对它完全无效。
    public static let referencePointsPerLine: Double = 40

    public var enabled: Bool
    /// 一格滚轮折算的位移（点）。传统鼠标一格约等于系统 3 行 ≈ 40 pt。
    public var pointsPerLine: Double
    /// 一次输入完全释放所需时间（秒）。越长尾巴越软，也越容易「跟不上手」。
    public var duration: Double
    /// 积压上限（点）。快速连滚时不封顶会越拖越远。
    public var maxPending: Double
    /// 无论来源一律按鼠标处理。
    ///
    /// 有些鼠标（厂商驱动重写过事件、远程桌面注入的事件）会带上相位字段，
    /// 被判定成触控板后整段跳过平滑——表现就是「开关打开但毫无效果」。
    /// 用户确认自己用的是滚轮鼠标时打开这一项兜底。
    public var forceMouse: Bool

    public init(enabled: Bool = true,
                pointsPerLine: Double = 40,
                duration: Double = 0.30,
                maxPending: Double = 320,
                forceMouse: Bool = false) {
        self.enabled = enabled
        self.pointsPerLine = pointsPerLine
        self.duration = duration
        self.maxPending = maxPending
        self.forceMouse = forceMouse
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, pointsPerLine, duration, maxPending, forceMouse
    }

    /// 手写解码：老版本 `scroll.json` 里没有 `forceMouse`，
    /// 用默认值补上，否则整个配置解码失败会退回默认值、把用户调好的参数丢掉。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SmoothScrollSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        pointsPerLine = try container.decodeIfPresent(Double.self, forKey: .pointsPerLine) ?? fallback.pointsPerLine
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? fallback.duration
        maxPending = try container.decodeIfPresent(Double.self, forKey: .maxPending) ?? fallback.maxPending
        forceMouse = try container.decodeIfPresent(Bool.self, forKey: .forceMouse) ?? fallback.forceMouse
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
              var settings = try? JSONDecoder().decode(SmoothScrollSettings.self, from: data) else {
            return SmoothScrollSettings()
        }
        // 0.18s 是早期版本的默认值：那个时长只有十来帧，尾巴还是 1pt 一格地爬，
        // 手感就是「不丝滑」。没动过这一项的老配置顺手升到新默认，并写回去
        // （否则每次启动都要重新迁一遍，用户在界面上会看到反复跳回 0.30）。
        if abs(settings.duration - 0.18) < 0.001 {
            settings.duration = SmoothScrollSettings().duration
            try? save(settings)
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
struct ScrollSmootherEngine {
    private(set) var pendingX = 0.0
    private(set) var pendingY = 0.0
    private var carryX = 0.0
    private var carryY = 0.0

    var isIdle: Bool {
        abs(pendingX) < 0.5 && abs(pendingY) < 0.5
    }

    mutating func add(x: Double, y: Double, maxPending: Double) {
        pendingX = Self.clamp(pendingX + x, limit: maxPending)
        pendingY = Self.clamp(pendingY + y, limit: maxPending)
    }

    /// 返回本帧应投递的整数位移。`finished` 表示已无剩余位移。
    mutating func step(dt: Double, duration: Double) -> (x: Int, y: Int, finished: Bool) {
        guard !isIdle else {
            reset()
            return (0, 0, true)
        }

        // 指数衰减：3τ 内释放 95%，尾段自然变慢，不需要额外的缓动曲线
        let tau = max(duration / 3.0, 0.01)
        let alpha = 1 - exp(-max(dt, 0.001) / tau)

        let dx = Self.consume(&pendingX, &carryX, alpha: alpha)
        let dy = Self.consume(&pendingY, &carryY, alpha: alpha)

        if abs(pendingX) < 0.05 { pendingX = 0 }
        if abs(pendingY) < 0.05 { pendingY = 0 }

        let finished = pendingX == 0 && pendingY == 0
        if finished { reset() }
        return (dx, dy, finished)
    }

    mutating func reset() {
        pendingX = 0
        pendingY = 0
        carryX = 0
        carryY = 0
    }

    private static func consume(_ pending: inout Double, _ carry: inout Double, alpha: Double) -> Int {
        guard pending != 0 else { return 0 }
        // 尾段不足 2pt 时一次吐完：指数衰减永远逼近 0，
        // 靠 1pt 保底会拖出十几帧「一格一格挪」的尾巴，看着反而更卡
        if abs(pending) <= 2 {
            let out = Int(pending.rounded())
            pending = 0
            carry = 0
            return out
        }
        let step = pending * alpha
        pending -= step
        carry += step
        // Int(_:) 向零截断，负方向也是对的
        let out = Int(carry)
        carry -= Double(out)
        return out
    }

    private static func clamp(_ value: Double, limit: Double) -> Double {
        min(max(value, -limit), limit)
    }
}

import CoreGraphics
import Foundation

/// 尺子读数单位。像素是「真实像素」，其余都按屏幕倍率换算成物理尺寸。
///
/// 换算链：像素 ÷ 倍率 = 点（1pt = 1/72 inch）= 物理尺寸。
/// 注意不能拿 `NSScreen.backingScaleFactor` 代替 `scale`：多屏、降采样抓帧时
/// 两者并不相等，尺子读数的「点」必须以当前这张位图为准。
public enum RulerUnit: String, CaseIterable, Codable, Sendable {
    case pixel
    case point
    case centimeter
    case inch

    public var title: String {
        switch self {
        case .pixel: return "像素 px"
        case .point: return "点 pt"
        case .centimeter: return "厘米 cm"
        case .inch: return "英寸 inch"
        }
    }

    public var suffix: String {
        switch self {
        case .pixel: return "px"
        case .point: return "pt"
        case .centimeter: return "cm"
        case .inch: return "in"
        }
    }

    /// 一位小数的单位（cm/inch），像素和点要整数。
    public var usesDecimals: Bool {
        self == .centimeter || self == .inch
    }

    /// 像素值 → 该单位下的数值。
    public func value(pixels: Double, pixelsPerPoint: Double) -> Double {
        guard pixelsPerPoint > 0 else { return pixels }
        let points = pixels / pixelsPerPoint
        switch self {
        case .pixel: return pixels
        case .point: return points
        case .centimeter: return points * 2.54 / 72
        case .inch: return points / 72
        }
    }

    /// 与 `value(pixels:pixelsPerPoint:)` 互逆，供测试与「输入数值改尺寸」这类后续功能用。
    public func pixels(from value: Double, pixelsPerPoint: Double) -> Double {
        guard pixelsPerPoint > 0 else { return value }
        switch self {
        case .pixel: return value
        case .point: return value * pixelsPerPoint
        case .centimeter: return value / 2.54 * 72 * pixelsPerPoint
        case .inch: return value * 72 * pixelsPerPoint
        }
    }
}

/// 取色结果的写法。
public enum RulerColorFormat: String, CaseIterable, Codable, Sendable {
    case hex
    case rgb
    case hsl

    public var title: String {
        switch self {
        case .hex: return "HEX（#RRGGBB）"
        case .rgb: return "RGB（rgb(r, g, b)）"
        case .hsl: return "HSL（hsl(h, s%, l%)）"
        }
    }
}

/// 尺子的测量线颜色。只给四种高对比色，够用又不至于让用户去调色板。
public enum RulerAccent: String, CaseIterable, Codable, Sendable {
    case red
    case blue
    case green
    case yellow

    public var title: String {
        switch self {
        case .red: return "红"
        case .blue: return "蓝"
        case .green: return "绿"
        case .yellow: return "黄"
        }
    }

    /// sRGB 分量（0–1）。视图层自己转 `NSColor`，模型不依赖 AppKit。
    public var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .red: return (1.00, 0.23, 0.19)
        case .blue: return (0.00, 0.48, 1.00)
        case .green: return (0.20, 0.78, 0.35)
        case .yellow: return (1.00, 0.80, 0.00)
        }
    }
}

public struct RulerSettings: Codable, Sendable, Equatable {
    public var unit: RulerUnit
    public var colorFormat: RulerColorFormat
    /// 关掉后 ⌥ 不再做边缘吸附（有人觉得吸附反而不好对像素）。
    public var snapEnabled: Bool
    public var accent: RulerAccent
    /// 测量线宽（视图点）。
    public var lineWidth: Double

    public static let minLineWidth: Double = 1
    public static let maxLineWidth: Double = 4

    public init(unit: RulerUnit = .pixel,
                colorFormat: RulerColorFormat = .hex,
                snapEnabled: Bool = true,
                accent: RulerAccent = .red,
                lineWidth: Double = 1) {
        self.unit = unit
        self.colorFormat = colorFormat
        self.snapEnabled = snapEnabled
        self.accent = accent
        self.lineWidth = lineWidth
    }

    /// 手写解码：以后加字段时老配置不会整份失效。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unit = (try? container.decodeIfPresent(RulerUnit.self, forKey: .unit)) ?? .pixel
        colorFormat = (try? container.decodeIfPresent(RulerColorFormat.self, forKey: .colorFormat)) ?? .hex
        snapEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .snapEnabled)) ?? true
        accent = (try? container.decodeIfPresent(RulerAccent.self, forKey: .accent)) ?? .red
        let width = (try? container.decodeIfPresent(Double.self, forKey: .lineWidth)) ?? 1
        lineWidth = min(max(width, Self.minLineWidth), Self.maxLineWidth)
    }
}

/// `~/Library/Application Support/Baton/ruler.json`。
@MainActor
public final class RulerSettingsStore {
    public private(set) var settings: RulerSettings

    private let url: URL
    private var observers: [(RulerSettings) -> Void] = []

    public init(url: URL? = nil) {
        let target: URL
        if let url {
            target = url
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true))
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            target = base.appendingPathComponent("Baton", isDirectory: true)
                .appendingPathComponent("ruler.json")
        }
        self.url = target

        if let data = try? Data(contentsOf: target),
           let decoded = try? JSONDecoder().decode(RulerSettings.self, from: data) {
            settings = decoded
        } else {
            settings = RulerSettings()
        }
    }

    /// 设置页改完调用：落盘 + 通知还开着的尺子立刻换读数单位。
    public func update(_ mutate: (inout RulerSettings) -> Void) {
        var next = settings
        mutate(&next)
        next.lineWidth = min(max(next.lineWidth, RulerSettings.minLineWidth),
                             RulerSettings.maxLineWidth)
        guard next != settings else { return }
        settings = next
        save()
        for observer in observers { observer(next) }
    }

    public func addObserver(_ observer: @escaping (RulerSettings) -> Void) {
        observers.append(observer)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

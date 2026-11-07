import Foundation

/// 输入法规则与记忆。规则是显式的、用户配的；记忆是自动积累的「这个 App 上次用哪个源」。
public struct InputSourceSettings: Codable, Sendable, Equatable {
    /// 总开关。关掉后不切换，但仍会记录（下次打开能直接用）
    public var enabled: Bool
    /// bundle id → 输入源 ID。显式规则优先于记忆
    public var rules: [String: String]
    /// bundle id → 上次离开该 App 时用的输入源 ID
    public var memory: [String: String]
    /// 完全不接管的 App：不套规则、不记记忆。适合那些自己管输入法的编辑器/终端
    public var ignored: Set<String>
    /// 切到前台 App 后延迟多少毫秒再切输入源。0 表示立即。
    /// Electron / JetBrains 这类 App 在激活瞬间切源，首个按键可能落在旧源上
    public var switchDelayMs: Int
    /// 浏览器地址栏用哪个源。nil = 不管地址栏。
    /// 敲网址是纯 ASCII 动作，中文输入法会让 `github` 先变成候选词，删了重打很烦。
    public var addressBarSourceID: String?

    public init(enabled: Bool = true,
                rules: [String: String] = [:],
                memory: [String: String] = [:],
                ignored: Set<String> = [],
                switchDelayMs: Int = 0,
                addressBarSourceID: String? = nil) {
        self.enabled = enabled
        self.rules = rules
        self.memory = memory
        self.ignored = ignored
        self.switchDelayMs = switchDelayMs
        self.addressBarSourceID = addressBarSourceID
    }

    // 旧版本只写了 enabled/rules/memory 三个键；缺省字段要能补默认值，不能让整份配置解码失败。
    private enum CodingKeys: String, CodingKey {
        case enabled, rules, memory, ignored, switchDelayMs, addressBarSourceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        rules = try container.decodeIfPresent([String: String].self, forKey: .rules) ?? [:]
        memory = try container.decodeIfPresent([String: String].self, forKey: .memory) ?? [:]
        ignored = Set(try container.decodeIfPresent([String].self, forKey: .ignored) ?? [])
        switchDelayMs = try container.decodeIfPresent(Int.self, forKey: .switchDelayMs) ?? 0
        addressBarSourceID = try container.decodeIfPresent(String.self, forKey: .addressBarSourceID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(rules, forKey: .rules)
        try container.encode(memory, forKey: .memory)
        // Set 本身无序，排一下序让 JSON 每次写出来都一样，diff 才看得出真正改了什么
        try container.encode(ignored.sorted(), forKey: .ignored)
        try container.encode(switchDelayMs, forKey: .switchDelayMs)
        try container.encodeIfPresent(addressBarSourceID, forKey: .addressBarSourceID)
    }
}

public enum InputSourceResolver {
    /// 目标输入源。nil 表示「不干预」——没规则也没记忆时保持当前源，
    /// 这比强行切回默认源更不容易和用户手动切换打架。
    ///
    /// 优先级：忽略 > 地址栏 > App 规则 > 记忆。地址栏排在最前是因为它比「这个 App 该用什么」
    /// 更具体：在 Chrome 里敲网址和在 Chrome 里写文档，期望的源本来就不同。
    public static func target(for key: String,
                              settings: InputSourceSettings,
                              inAddressBar: Bool = false) -> String? {
        // 忽略是最高优先级：连记忆都不参考，完全交给用户自己
        guard !settings.ignored.contains(key) else { return nil }
        if inAddressBar, let bar = settings.addressBarSourceID, !bar.isEmpty {
            return bar
        }
        if let rule = settings.rules[key], !rule.isEmpty {
            return rule
        }
        if let remembered = settings.memory[key], !remembered.isEmpty {
            return remembered
        }
        return nil
    }

    /// 这个 App 是否值得记一笔。忽略的 App 不记，避免列表里堆一堆没用的条目。
    public static func shouldRemember(_ key: String, settings: InputSourceSettings) -> Bool {
        !settings.ignored.contains(key)
    }
}

/// 设置持久化。规则量很小，一个 JSON 文件足够，也方便直接看。
public struct InputSourceStore: Sendable {
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
        url = dir.appendingPathComponent("input-source.json")
    }

    public func load() -> InputSourceSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(InputSourceSettings.self, from: data) else {
            return InputSourceSettings()
        }
        return settings
    }

    public func save(_ settings: InputSourceSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

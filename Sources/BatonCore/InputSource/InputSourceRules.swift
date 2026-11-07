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
    /// 网站规则：可以整站一个源，也可以只在某个输入框（按 placeholder 关键字）里换
    public var siteRules: [SiteRule]
    /// 自动学习：在同一个网站的同一个输入框里重复用同一个源，攒够次数自动建规则
    public var learningEnabled: Bool
    /// 还没攒够次数的组合
    public var learnCandidates: [SiteRuleCandidate]
    /// 输入源 ID → 显示名。系统只给「当前装着的」源名字，卸载后就查不到了，
    /// 所以顺手存一份：换掉输入法时，失效提示才能说「搜狗拼音」而不是一串 bundle id。
    /// 只保留仍在用的和配置里引用到的，不会无限长。
    public var sourceNames: [String: String]

    public init(enabled: Bool = true,
                rules: [String: String] = [:],
                memory: [String: String] = [:],
                ignored: Set<String> = [],
                switchDelayMs: Int = 0,
                addressBarSourceID: String? = nil,
                siteRules: [SiteRule] = [],
                learningEnabled: Bool = true,
                learnCandidates: [SiteRuleCandidate] = [],
                sourceNames: [String: String] = [:]) {
        self.enabled = enabled
        self.rules = rules
        self.memory = memory
        self.ignored = ignored
        self.switchDelayMs = switchDelayMs
        self.addressBarSourceID = addressBarSourceID
        self.siteRules = siteRules
        self.learningEnabled = learningEnabled
        self.learnCandidates = learnCandidates
        self.sourceNames = sourceNames
    }

    // 旧版本只写了 enabled/rules/memory 三个键；缺省字段要能补默认值，不能让整份配置解码失败。
    private enum CodingKeys: String, CodingKey {
        case enabled, rules, memory, ignored, switchDelayMs, addressBarSourceID, siteRules
        case learningEnabled, learnCandidates, sourceNames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        rules = try container.decodeIfPresent([String: String].self, forKey: .rules) ?? [:]
        memory = try container.decodeIfPresent([String: String].self, forKey: .memory) ?? [:]
        ignored = Set(try container.decodeIfPresent([String].self, forKey: .ignored) ?? [])
        switchDelayMs = try container.decodeIfPresent(Int.self, forKey: .switchDelayMs) ?? 0
        addressBarSourceID = try container.decodeIfPresent(String.self, forKey: .addressBarSourceID)
        siteRules = try container.decodeIfPresent([SiteRule].self, forKey: .siteRules) ?? []
        // 默认开着：自动学习是这个功能的默认形态，用户没关就是想要
        learningEnabled = try container.decodeIfPresent(Bool.self, forKey: .learningEnabled) ?? true
        learnCandidates = try container.decodeIfPresent([SiteRuleCandidate].self, forKey: .learnCandidates) ?? []
        sourceNames = try container.decodeIfPresent([String: String].self, forKey: .sourceNames) ?? [:]
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
        // 空数组不写，配置文件保持干净
        if !siteRules.isEmpty {
            try container.encode(siteRules, forKey: .siteRules)
        }
        // 开着是常态，只有关掉时才写一行 false
        if !learningEnabled {
            try container.encode(false, forKey: .learningEnabled)
        }
        if !learnCandidates.isEmpty {
            try container.encode(learnCandidates, forKey: .learnCandidates)
        }
        if !sourceNames.isEmpty {
            try container.encode(sourceNames, forKey: .sourceNames)
        }
    }
}

/// 一条配了、但当前系统里找不到的输入源。
///
/// 只描述「有多少处在引用它」，不持有配置本身：迁移时按 sourceID 原值批量替换，
/// 用户不点迁移就什么都不动。
public struct MissingSource: Sendable, Equatable, Identifiable {
    public let sourceID: String
    /// 从名字缓存里取的。真查不到就退回 ID，至少不是空白
    public let name: String
    /// 引用了它的 App 数（规则和记忆里同一个 App 只算一次）
    public let appCount: Int
    public let siteRuleCount: Int
    public let candidateCount: Int
    public let addressBar: Bool

    public init(sourceID: String,
                name: String,
                appCount: Int,
                siteRuleCount: Int,
                candidateCount: Int,
                addressBar: Bool) {
        self.sourceID = sourceID
        self.name = name
        self.appCount = appCount
        self.siteRuleCount = siteRuleCount
        self.candidateCount = candidateCount
        self.addressBar = addressBar
    }

    public var id: String { sourceID }
    public var total: Int { appCount + siteRuleCount + candidateCount + (addressBar ? 1 : 0) }

    /// 「2 个 App、1 条网站规则」这种给人看的明细
    public var breakdown: String {
        var parts: [String] = []
        if appCount > 0 { parts.append("\(appCount) 个 App") }
        if siteRuleCount > 0 { parts.append("\(siteRuleCount) 条网站规则") }
        if candidateCount > 0 { parts.append("\(candidateCount) 条学习记录") }
        if addressBar { parts.append("地址栏") }
        return parts.isEmpty ? "没有引用" : parts.joined(separator: "、")
    }
}

/// 一次迁移改了多少处。用来在界面上回一句「已迁移 4 处」，也方便测试断言。
public struct MigrationSummary: Sendable, Equatable {
    public let apps: Int
    public let siteRules: Int
    public let candidates: Int
    public let addressBar: Bool

    public init(apps: Int = 0, siteRules: Int = 0, candidates: Int = 0, addressBar: Bool = false) {
        self.apps = apps
        self.siteRules = siteRules
        self.candidates = candidates
        self.addressBar = addressBar
    }

    public static let none = MigrationSummary()
    public var total: Int { apps + siteRules + candidates + (addressBar ? 1 : 0) }
    public var isEmpty: Bool { total == 0 }
}

public enum InputSourceResolver {
    /// 目标输入源。nil 表示「不干预」——没规则也没记忆时保持当前源，
    /// 这比强行切回默认源更不容易和用户手动切换打架。
    ///
    /// 优先级：忽略 > 地址栏 > 网站规则 > App 规则 > 记忆。
    /// 前三者都比「这个 App 该用什么」更具体：同样是 Chrome，敲网址、在 GitHub 写评论、
    /// 在中文站写内容，期望的源本来就不同。
    public static func target(for key: String,
                              settings: InputSourceSettings,
                              inAddressBar: Bool = false,
                              host: String? = nil,
                              fieldLabel: String? = nil) -> String? {
        // 忽略是最高优先级：连记忆都不参考，完全交给用户自己
        guard !settings.ignored.contains(key) else { return nil }
        if inAddressBar, let bar = settings.addressBarSourceID, !bar.isEmpty {
            return bar
        }
        if let site = SiteRuleMatcher.match(host: host, label: fieldLabel, rules: settings.siteRules),
           !site.sourceID.isEmpty {
            return site.sourceID
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

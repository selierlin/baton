import Foundation

/// 输入法规则与记忆。规则是显式的、用户配的；记忆是自动积累的「这个 App 上次用哪个源」。
public struct InputSourceSettings: Codable, Sendable, Equatable {
    /// 总开关。关掉后不切换，但仍会记录（下次打开能直接用）
    public var enabled: Bool
    /// bundle id → 输入源 ID。显式规则优先于记忆
    public var rules: [String: String]
    /// bundle id → 上次离开该 App 时用的输入源 ID
    public var memory: [String: String]

    public init(enabled: Bool = true, rules: [String: String] = [:], memory: [String: String] = [:]) {
        self.enabled = enabled
        self.rules = rules
        self.memory = memory
    }
}

public enum InputSourceResolver {
    /// 目标输入源。nil 表示「不干预」——没规则也没记忆时保持当前源，
    /// 这比强行切回默认源更不容易和用户手动切换打架。
    public static func target(for key: String, settings: InputSourceSettings) -> String? {
        if let rule = settings.rules[key], !rule.isEmpty {
            return rule
        }
        if let remembered = settings.memory[key], !remembered.isEmpty {
            return remembered
        }
        return nil
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

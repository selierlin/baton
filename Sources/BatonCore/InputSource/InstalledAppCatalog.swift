import AppKit

/// 本机 App 清单，给「按 App 配置输入法」用。
///
/// 不做「先添加再配置」：用户想的是某个具体 App，直接搜名字最快。
/// 扫一次缓存住，后续打开设置页不再碰磁盘。
@MainActor
final class InstalledAppCatalog {
    struct Entry: Hashable {
        let bundleID: String
        let name: String
        let url: URL
    }

    static let shared = InstalledAppCatalog()

    private var cache: [Entry]?

    var all: [Entry] {
        if let cache { return cache }
        let entries = Self.scan()
        cache = entries
        return entries
    }

    /// 应用目录 + 运行中的 App。后者兜住开发版、外接盘、Homebrew 之外的位置。
    private static func scan() -> [Entry] {
        var result: [Entry] = []
        var seen = Set<String>()
        let fm = FileManager.default

        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]

        for root in roots {
            guard let children = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for child in children where child.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(child)
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier,
                      seen.insert(id).inserted else { continue }
                result.append(Entry(bundleID: id, name: displayName(of: path), url: URL(fileURLWithPath: path)))
            }
        }

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier,
                  let url = app.bundleURL,
                  seen.insert(id).inserted else { continue }
            result.append(Entry(bundleID: id, name: app.localizedName ?? displayName(of: url.path), url: url))
        }

        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func displayName(of path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

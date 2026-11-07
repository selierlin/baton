import AppKit

/// 取来源 App 的图标。
///
/// 新记录带 bundle id，直接查；v3 之前的老记录只有名字，
/// 退化成扫一遍应用目录建名字索引（只建一次，之后走缓存）。
@MainActor
final class AppIconProvider {
    static let shared = AppIconProvider()

    private var icons: [String: NSImage] = [:]
    private var nameIndex: [String: URL]?

    /// 找不到 App 时返回 nil，调用方只用画文字，不要占位图。
    func icon(bundleID: String?, appName: String?, pointSize: CGFloat) -> NSImage? {
        guard let url = applicationURL(bundleID: bundleID, appName: appName) else { return nil }
        let key = "\(url.path)@\(pointSize)"
        if let cached = icons[key] { return cached }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: pointSize, height: pointSize)
        icons[key] = icon
        return icon
    }

    private func applicationURL(bundleID: String?, appName: String?) -> URL? {
        if let bundleID, !bundleID.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        guard let appName, !appName.isEmpty else { return nil }
        if nameIndex == nil { nameIndex = Self.buildNameIndex() }
        return nameIndex?[appName]
    }

    /// Finder 里显示的 App 名基本等于 `localizedName`，拿它跟库里存的 sourceApp 对齐。
    private static let searchRoots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
    ]

    private static func buildNameIndex() -> [String: URL] {
        var index: [String: URL] = [:]
        let fm = FileManager.default
        for root in searchRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(entry)
                let url = URL(fileURLWithPath: path)
                let display = fm.displayName(atPath: path)
                if index[display] == nil { index[display] = url }
                let plain = (entry as NSString).deletingPathExtension
                if index[plain] == nil { index[plain] = url }
            }
        }
        return index
    }
}

import Foundation

/// 剪贴板的可调项。放 UserDefaults 而不是 json 文件：
/// 三项都是标量，改完立即生效，不需要迁移。
public struct ClipboardPrefs: Sendable {
    public static let shared = ClipboardPrefs()

    private enum Key {
        static let maxItems = "clipboard.maxItems"
        static let maxBytes = "clipboard.maxBytes"
        static let ocrTitles = "clipboard.ocrTitles"
    }

    public static let maxItemsChoices = [200, 500, 800, 1500, 3000]
    public static let maxBytesChoices = [
        200 * 1024 * 1024,
        500 * 1024 * 1024,
        1024 * 1024 * 1024,
        2048 * 1024 * 1024,
    ]

    public init() {}

    public var maxItems: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Key.maxItems)
            return value > 0 ? value : 800
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Key.maxItems) }
    }

    public var maxBytes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Key.maxBytes)
            return value > 0 ? value : 500 * 1024 * 1024
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Key.maxBytes) }
    }

    /// 图片入库后用 OCR 前两行当标题，让图里的字也能被搜到。
    public var ocrTitles: Bool {
        get {
            if UserDefaults.standard.object(forKey: Key.ocrTitles) == nil { return true }
            return UserDefaults.standard.bool(forKey: Key.ocrTitles)
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Key.ocrTitles) }
    }
}

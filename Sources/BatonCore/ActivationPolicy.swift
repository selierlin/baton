import AppKit

/// 在 `.accessory` 与 `.regular` 之间切换。
///
/// agent App 没有 Dock 图标，窗口默认拿不到键盘焦点；需要输入的窗（设置、翻译输入框）
/// 必须在打开期间切 `.regular`。用计数而不是布尔，避免两个窗同时在时互相切回。
@MainActor
public final class ActivationPolicyController {
    /// 全局唯一：设置窗、标注器、模态提示可能同时要求 `.regular`，
    /// 各用各的计数会出现「A 还没关，B 收尾时把策略切回 accessory」。
    public static let shared = ActivationPolicyController()

    private let app: NSApplication
    private var regularHolds = 0

    public init(app: NSApplication = .shared) {
        self.app = app
    }

    public var isRegular: Bool { regularHolds > 0 }

    public func enterRegular() {
        regularHolds += 1
        guard regularHolds == 1 else { return }
        app.setActivationPolicy(.regular)
        app.activate()
    }

    public func leaveRegular() {
        guard regularHolds > 0 else { return }
        regularHolds -= 1
        guard regularHolds == 0 else { return }
        app.setActivationPolicy(.accessory)
    }

    /// 已经持有 regular 时，只把 App 重新拉到前台。
    ///
    /// 设置窗被别的 App 盖住后再从菜单打开，窗口一直都在，走的不是 `enterRegular`；
    /// 没人再调一次 activate 的话，窗口就永远压在别人底下（看起来像「点了没反应」）。
    public func focus() {
        guard regularHolds > 0 else { return }
        app.activate(ignoringOtherApps: true)
    }

    public func withRegular<T>(_ body: @MainActor () async -> T) async -> T {
        enterRegular()
        defer { leaveRegular() }
        return await body()
    }
}

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

    public func withRegular<T>(_ body: () async -> T) async -> T {
        enterRegular()
        defer { leaveRegular() }
        return await body()
    }
}

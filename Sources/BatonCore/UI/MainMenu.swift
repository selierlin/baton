import AppKit

/// 菜单栏 App 也要有一份主菜单——不是为了显示，是为了**快捷键**。
///
/// ⌘V / ⌘C / ⌘X / ⌘A 不是 NSTextView 自己处理的，它们是「编辑」菜单上的
/// key equivalent：没有主菜单，设置页里的输入框就完全粘不进去，只能一个字一个字敲。
///
/// `.accessory` 下这份菜单栏平时不显示；打开设置（切 `.regular`）时它才出现，
/// 顺便让菜单栏不是一片空白。
@MainActor
public enum MainMenu {
    public static func install() {
        let main = NSMenu()
        main.addItem(appMenu())
        main.addItem(editMenu())
        // `NSApp` 在 NSApplication.shared 还没建起来时是 nil（swift test 里就是这样）
        NSApplication.shared.mainMenu = main
    }

    private static func appMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Baton")
        menu.addItem(withTitle: "关于 Baton",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "隐藏 Baton",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        menu.addItem(withTitle: "隐藏其他",
                     action: #selector(NSApplication.hideOtherApplications(_:)),
                     keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Baton",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    /// 只放文本编辑真正用得上的四个。
    ///
    /// 没放「撤销 / 重做」：标注画布的 ⌘Z 走的是自己的 `keyDown`，菜单项会把按键截走；
    /// 同理没放 ⌘W / ⌘P——画布里它们分别是「取消」和「贴图」。
    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "编辑")
        menu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        menu.addItem(withTitle: "复制", action: Selector(("copy:")), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        item.submenu = menu
        return item
    }
}

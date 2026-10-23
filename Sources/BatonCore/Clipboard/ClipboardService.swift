import AppKit
import os

/// 剪贴板服务：监听 → 入库 → 面板 → 回写。
///
/// 回写的两个约束：
/// 1. 写自己的剪贴板会让 `changeCount` +1，必须 `noteSelfPasteboardWrite()`，否则历史会自我繁殖。
/// 2. 粘贴到前台要先把焦点还给之前的 App，再合成 ⌘V。
@MainActor
public final class ClipboardService {
    public let store: ClipboardStore

    private let hub: EventHub
    private let log = Logger(subsystem: "com.selier.baton", category: "clipboard")
    private var panel: ClipboardPanelController?
    private var task: Task<Void, Never>?
    private var previousApp: NSRunningApplication?

    public init(store: ClipboardStore, hub: EventHub) {
        self.store = store
        self.hub = hub
    }

    public func start() {
        guard task == nil else { return }

        if panel == nil {
            let panel = ClipboardPanelController(store: store)
            panel.onCommit = { [weak self] item, paste in
                self?.commit(item, paste: paste)
            }
            self.panel = panel
        }

        task = Task { [weak self] in
            guard let self else { return }
            for await event in hub.events(buffering: 32) {
                switch event {
                case .clipboardChanged:
                    await capturePasteboard()
                case .scroll, .frontAppChanged:
                    break
                }
            }
        }

        collectGarbage()
    }

    public func stop() {
        task?.cancel()
        task = nil
        panel?.hide()
    }

    public func showHistory() {
        // 面板一出现 Baton 就成了前台，必须提前记住该把焦点还给谁
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        if panel == nil { start() }
        panel?.show()
        log.debug("剪贴板面板打开")
    }

    public func hideHistory() {
        panel?.hide()
    }

    // MARK: - 采集

    /// 采集。剪贴板数据由源进程懒提供，刚变更时偶尔读到「有类型但长度为 0」，
    /// 读不到就短暂重试；这种空读不改变 changeCount，不重试这条就永久丢了。
    private func capturePasteboard() async {
        let pasteboard = NSPasteboard.general
        let sourceApp = currentSourceApp()
        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard !PasteboardReader.isSecret(types: types) else { return }

        var snapshot: PasteboardSnapshot?
        for attempt in 0..<3 {
            snapshot = PasteboardReader.read(pasteboard, sourceApp: sourceApp)
            if snapshot != nil { break }
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        guard let snapshot else { return }

        let draft = ClipDraft(
            kind: snapshot.kind,
            contentHash: snapshot.contentHash,
            text: snapshot.text,
            pngData: snapshot.pngData,
            pixelWidth: snapshot.pixelWidth,
            pixelHeight: snapshot.pixelHeight,
            byteSize: snapshot.byteSize,
            sourceApp: sourceApp,
            meta: snapshot.filePaths
        )

        do {
            let result = try store.insert(draft)
            if !result.deduplicated {
                let removed = try store.trim()
                if removed > 0 { collectGarbage() }
            }
        } catch {
            log.error("剪贴板入库失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 采集时的前台 App。事件总线缓存的 frontApp 只在 App 激活时更新，
    /// 复制动作本身不激活 App，所以这里现查更准；面板开着时前台是 Baton 自己，回退到缓存。
    private func currentSourceApp() -> String? {
        let front = NSWorkspace.shared.frontmostApplication
        if let name = front?.localizedName,
           front?.processIdentifier != NSRunningApplication.current.processIdentifier {
            return name
        }
        return hub.frontApp?.name
    }

    // MARK: - 回写

    private func commit(_ item: ClipItem, paste: Bool) {
        write(item)
        try? store.touch(id: item.id)

        guard paste else {
            restoreFocus()
            return
        }

        restoreFocus()
        // 等焦点真正回到目标 App 再按键，否则 ⌘V 会打到 Baton 自己
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            Self.synthesizePaste()
        }
    }

    private func write(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.clipKind {
        case .text, .color:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            if let path = item.blobPath,
               let image = NSImage(contentsOf: store.blobURL(forRelativePath: path)) {
                pasteboard.writeObjects([image])
            }
        case .file:
            let paths = (item.meta ?? "").split(separator: "\n").map(String.init)
            let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
            if !urls.isEmpty {
                pasteboard.writeObjects(urls)
            }
        }

        hub.noteSelfPasteboardWrite()
    }

    private func restoreFocus() {
        guard let app = previousApp, app.processIdentifier != NSRunningApplication.current.processIdentifier else {
            return
        }
        app.activate()
        previousApp = nil
    }

    private static func synthesizePaste() {
        guard CGPreflightPostEventAccess() else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCodeV: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - 维护

    private func collectGarbage() {
        do {
            let removed = try store.collectOrphanBlobs()
            if removed > 0 { log.info("回收 \(removed) 个孤儿 blob") }
        } catch {
            log.error("blob 回收失败：\(String(describing: error), privacy: .public)")
        }
    }
}

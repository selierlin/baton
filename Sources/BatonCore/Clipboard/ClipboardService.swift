import AppKit
import Carbon.HIToolbox
import ImageIO
import os

public extension Notification.Name {
    /// 历史有增删改（采集、清空、OCR 回填标题），面板据此重读。
    static let batonClipboardDidChange = Notification.Name("com.selier.baton.clipboardDidChange")
}

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
    private var ocrTasks: [String: Task<Void, Never>] = [:]

    public init(store: ClipboardStore, hub: EventHub) {
        self.store = store
        self.hub = hub
    }

    public func start() {
        guard task == nil else { return }

        if panel == nil {
            let panel = ClipboardPanelController(store: store)
            panel.onCommit = { [weak self] item, paste, plainText in
                self?.commit(item, paste: paste, plainText: plainText)
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
        ocrTasks.values.forEach { $0.cancel() }
        ocrTasks.removeAll()
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
            pngData: snapshot.imageData,
            imageExt: snapshot.imageExt,
            pixelWidth: snapshot.pixelWidth,
            pixelHeight: snapshot.pixelHeight,
            byteSize: snapshot.byteSize,
            sourceApp: sourceApp,
            meta: snapshot.filePaths,
            contents: snapshot.contents
        )

        do {
            let result = try store.insert(draft)
            if !result.deduplicated {
                let removed = try store.trim()
                if removed > 0 { collectGarbage() }
                if snapshot.kind == .image {
                    scheduleImageTitle(item: result.item)
                }
            }
            NotificationCenter.default.post(name: .batonClipboardDidChange, object: nil)
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

    // MARK: - 图片标题

    /// 图片只靠「图片 1920×1080」在列表里等于全都长一样，用 OCR 前两行当标题。
    /// 失败就保留尺寸摘要，不影响使用。
    private func scheduleImageTitle(item: ClipItem) {
        guard let path = item.blobPath,
              ClipboardPrefs.shared.ocrTitles,
              ocrTasks[item.id] == nil else { return }
        let url = store.blobURL(forRelativePath: path)

        ocrTasks[item.id] = Task { [weak self] in
            defer { self?.ocrTasks[item.id] = nil }
            guard let text = await Self.recognizeTitle(at: url), !Task.isCancelled else { return }
            guard let self else { return }
            do {
                try self.store.updateText(id: item.id, text: text)
                NotificationCenter.default.post(name: .batonClipboardDidChange, object: nil)
                self.log.debug("图片标题回填：\(text.prefix(30), privacy: .public)")
            } catch {
                self.log.error("图片标题回填失败：\(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func recognizeTitle(at url: URL) async -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let transport: any OCRTransport = SubprocessOCRTransport()
        guard let result = try? await transport.recognize(OCRRequest(image: image)),
              !result.isEmpty else { return nil }

        let lines = result.lines
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(2)
        let title = lines.joined(separator: " ")
        return title.isEmpty ? nil : String(title.prefix(120))
    }

    // MARK: - 回写

    private func commit(_ item: ClipItem, paste: Bool, plainText: Bool) {
        write(item, plainText: plainText)
        try? store.touch(id: item.id)

        guard paste else {
            restoreFocus()
            return
        }

        restoreFocus()
        // 等焦点真正回到目标 App 再按键，否则 ⌘V 会打到 Baton 自己
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            Self.synthesizePaste()
        }
    }

    private func write(_ item: ClipItem, plainText: Bool) {
        let pasteboard = NSPasteboard.general
        var contents = (try? store.contents(for: item.id)) ?? []
        if plainText { contents = ClipType.plainTextOnly(contents) }

        pasteboard.clearContents()

        if contents.isEmpty {
            // 升级前的老记录（理论上迁移已补齐，兜底一次）
            switch item.clipKind {
            case .text, .color:
                pasteboard.setString(item.text ?? "", forType: .string)
            case .image:
                if let path = item.blobPath,
                   let data = try? Data(contentsOf: store.blobURL(forRelativePath: path)) {
                    pasteboard.setData(data, forType: .png)
                }
            case .file:
                let urls = (item.meta ?? "").split(separator: "\n")
                    .map { URL(fileURLWithPath: String($0)) as NSURL }
                if !urls.isEmpty { pasteboard.writeObjects(urls) }
            }
        } else {
            var fileItems: [NSPasteboardItem] = []
            for content in contents {
                let data = content.value ?? content.blobPath.flatMap {
                    try? Data(contentsOf: store.blobURL(forRelativePath: $0))
                }
                guard let data else { continue }

                if content.type == ClipType.fileURL {
                    // 多文件必须靠 writeObjects 才能一起粘出去
                    let pasteItem = NSPasteboardItem()
                    pasteItem.setData(data, forType: .fileURL)
                    fileItems.append(pasteItem)
                } else {
                    pasteboard.setData(data, forType: NSPasteboard.PasteboardType(content.type))
                }
            }
            if !fileItems.isEmpty {
                pasteboard.writeObjects(fileItems)
            }
        }

        hub.noteSelfPasteboardWrite()
    }

    private func restoreFocus() {
        guard let app = previousApp,
              app.processIdentifier != NSRunningApplication.current.processIdentifier else {
            previousApp = nil
            return
        }
        previousApp = nil
        // macOS 14 起，后台 App 直接激活别的 App 经常被系统忽略，焦点会留在
        // Baton 自己这个已经没有窗口的进程上，合成出来的 ⌘V 就没人接。
        // 先把自己藏起来，让系统把前台交还，再显式激活兜底。
        NSApp.hide(nil)
        if !app.activate(options: [.activateIgnoringOtherApps]) {
            ActionLog.app("clip.restoreFocus", "activate-failed app=\(app.localizedName ?? "?")")
        }
    }

    private static func synthesizePaste() {
        guard CGPreflightPostEventAccess() else {
            ActionLog.app("clip.paste", "no-post-event-access")
            NSSound.beep()
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        // 粘贴期间屏蔽本地键盘事件，避免回灌自己
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let keyCode = KeyboardLayout.keyCode(for: "v")
        var flags: CGEventFlags = .maskCommand
        // 左右修饰键标记，Chromium 系靠它区分
        flags.insert(CGEventFlags(rawValue: 0x000008))

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cgSessionEventTap)
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

/// 按当前键盘布局找字符对应的键码。
///
/// 写死 0x09 只对 QWERTY 成立：Dvorak、「Dvorak - QWERTY ⌘」这类布局里 v 不在那个位置，
/// 合成的 ⌘V 会粘出别的东西。
enum KeyboardLayout {
    static func keyCode(for character: Character, fallback: CGKeyCode = 0x09) -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return fallback
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let target = String(character).lowercased()

        return data.withUnsafeBytes { buffer -> CGKeyCode in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return fallback
            }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout,
                    UInt16(code),
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeys,
                    chars.count,
                    &length,
                    &chars
                )
                guard status == noErr, length > 0 else { continue }
                if String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return CGKeyCode(code)
                }
            }
            return fallback
        }
    }
}

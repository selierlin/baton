import AppKit
import Foundation

/// 剪贴板历史浮窗：搜索 + 类型筛选 + 列表 + 预览。
///
/// 不切 `.regular`：accessory App 的窗口同样可以成为 key window，切策略反而会让菜单栏闪。
@MainActor
public final class ClipboardPanelController: NSObject {
    /// (条目, 是否直接粘贴到前台, 是否只粘纯文本)
    public var onCommit: ((ClipItem, Bool, Bool) -> Void)?

    private let store: ClipboardStore
    private var items: [ClipHit] = []
    private var filter: ClipKind?

    private let panel: KeyablePanel
    private let searchField = NSSearchField()
    private let filterControl = NSSegmentedControl(
        labels: ["全部", "文字", "图片", "文件", "颜色"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let preview = ClipPreviewView()
    private let countLabel = NSTextField(labelWithString: "")
    private let thumbnails = ThumbnailCache()
    private var keyMonitor: Any?

    private static let panelSize = NSSize(width: 580, height: 640)
    private static let rowHeight: CGFloat = 48
    private static let previewHeight: CGFloat = 168
    private static let frameKey = "clipboard.panelOrigin"

    public init(store: ClipboardStore) {
        self.store = store
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildUI()
        reload(query: "")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appResignedActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyChanged),
            name: .batonClipboardDidChange,
            object: nil
        )
    }

    public var isVisible: Bool { panel.isVisible }

    public func show() {
        searchField.stringValue = ""
        filterControl.selectedSegment = 0
        filter = nil
        reload(query: "")
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        // 即使 NSApp.activate() 没被系统采纳，也先把窗口显示出来（只是可能不是 key）
        panel.orderFrontRegardless()
        panel.makeFirstResponder(searchField)
        selectRow(0)
        installKeyMonitor()
    }

    public func hide() {
        saveOrigin()
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    @objc private func appResignedActive() {
        if panel.isVisible { hide() }
    }

    @objc private func historyChanged() {
        guard panel.isVisible else { return }
        let selected = selectedIndex
        reload(query: searchField.stringValue)
        if let selected { selectRow(selected) }
    }

    // MARK: - UI

    private func buildUI() {
        panel.isFloatingPanel = true
        panel.level = .floating
        // 不用 hidesOnDeactivate：激活被系统拒绝时窗口会立刻消失（实测 accessory App
        // 从非用户手势路径打开会这样）。改成自己监听 resignActive。
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let background = PanelBackgroundView()
        background.wantsLayer = true

        searchField.placeholderString = "搜索剪贴板历史"
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false

        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.segmentStyle = .rounded
        filterControl.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(copyOnly)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        preview.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "↵ 复制   ⌘↵ 粘贴   ⌥↵ 纯文本   ⌫ 删除   ⌘1-9 直选")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        for view in [searchField, filterControl, scroll, emptyLabel, separator, preview, countLabel, hint] as [NSView] {
            background.addSubview(view)
        }
        panel.contentView = background

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),

            filterControl.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            filterControl.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            filterControl.trailingAnchor.constraint(lessThanOrEqualTo: searchField.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -6),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.bottomAnchor.constraint(equalTo: preview.topAnchor, constant: -8),

            preview.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            preview.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            preview.heightAnchor.constraint(equalToConstant: Self.previewHeight),
            preview.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),

            countLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            countLabel.centerYAnchor.constraint(equalTo: hint.centerYAnchor),

            hint.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            hint.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
        ])
    }

    private func positionPanel() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.frameKey) != nil {
            let point = NSPointFromString(defaults.string(forKey: Self.frameKey) ?? "")
            if point != .zero, isOnAnyScreen(point) {
                panel.setFrameOrigin(point)
                return
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - Self.panelSize.width / 2,
            y: visible.maxY - Self.panelSize.height - 80
        ))
    }

    private func isOnAnyScreen(_ point: NSPoint) -> Bool {
        NSScreen.screens.contains { screen in
            let frame = screen.visibleFrame
            return point.x >= frame.minX - 40 && point.x <= frame.maxX - 120
                && point.y >= frame.minY - 40 && point.y <= frame.maxY - 120
        }
    }

    private func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.frameKey)
    }

    // MARK: - 数据

    private func reload(query: String) {
        do {
            items = try store.searchHits(query, kind: filter, limit: store.maxItems)
        } catch {
            items = []
            NSLog("[Baton] 剪贴板查询失败：\(error)")
        }
        tableView.reloadData()
        emptyLabel.stringValue = query.isEmpty && filter == nil ? "还没有剪贴板记录" : "没有匹配的记录"
        emptyLabel.isHidden = !items.isEmpty
        countLabel.stringValue = items.isEmpty ? "" : "共 \(items.count) 条"
        if items.isEmpty {
            tableView.deselectAll(nil)
            preview.show(nil, store: store)
        } else if selectedIndex == nil {
            selectRow(0)
        }
    }

    private func selectRow(_ index: Int) {
        guard !items.isEmpty else { return }
        let clamped = min(max(index, 0), items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
        preview.show(items[clamped].item, store: store)
    }

    private var selectedIndex: Int? {
        let row = tableView.selectedRow
        return row >= 0 && row < items.count ? row : nil
    }

    // MARK: - 动作

    private func commit(paste: Bool, plainText: Bool) {
        guard let index = selectedIndex else { return }
        let item = items[index].item
        hide()
        onCommit?(item, paste, plainText)
    }

    private func deleteSelected() {
        guard let index = selectedIndex else { return }
        let item = items[index].item
        do {
            try store.delete(id: item.id)
            reload(query: searchField.stringValue)
            selectRow(min(index, items.count - 1))
        } catch {
            NSLog("[Baton] 删除剪贴板记录失败：\(error)")
        }
    }

    @objc private func copyOnly() {
        commit(paste: false, plainText: false)
    }

    @objc private func filterChanged() {
        let kinds: [ClipKind?] = [nil, .text, .image, .file, .color]
        let index = filterControl.selectedSegment
        filter = index >= 0 && index < kinds.count ? kinds[index] : nil
        reload(query: searchField.stringValue)
        selectRow(0)
    }

    // MARK: - 键位

    /// 搜索框会吃掉 ⌘1-9，必须用本地监听先拦。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.modifierFlags.contains(.command),
               let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
               (1...9).contains(digit), digit <= self.items.count {
                self.selectRow(digit - 1)
                self.commit(paste: true, plainText: false)
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func handle(command selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            selectRow((selectedIndex ?? 0) - 1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            selectRow((selectedIndex ?? -1) + 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let flags = NSEvent.modifierFlags
            commit(paste: flags.contains(.command) || flags.contains(.option),
                   plainText: flags.contains(.option))
            return true
        case #selector(NSResponder.deleteBackward(_:)),
             #selector(NSResponder.deleteForward(_:)):
            // 搜索框有字时让搜索框自己删字
            guard searchField.stringValue.isEmpty else { return false }
            deleteSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }
}

extension ClipboardPanelController: NSSearchFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        reload(query: searchField.stringValue)
        selectRow(0)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        handle(command: commandSelector)
    }
}

extension ClipboardPanelController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("clip-row")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ClipRowCell) ?? {
            let cell = ClipRowCell()
            cell.identifier = identifier
            return cell
        }()
        let hit = items[row]
        cell.configure(hit: hit, index: row + 1,
                       thumbnail: thumbnails.image(for: hit.item, store: store, size: 32))
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let index = selectedIndex else { return }
        tableView.scrollRowToVisible(index)
        preview.show(items[index].item, store: store)
    }
}

// MARK: - 行视图

private final class ClipRowCell: NSTableCellView {
    private let indexLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        indexLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        indexLabel.textColor = .tertiaryLabelColor
        indexLabel.alignment = .right
        indexLabel.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [indexLabel, iconView, titleLabel, subtitleLabel] as [NSView] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            indexLabel.widthAnchor.constraint(equalToConstant: 14),
            indexLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            iconView.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(hit: ClipHit, index: Int, thumbnail: NSImage?) {
        let item = hit.item
        indexLabel.stringValue = index <= 9 ? "\(index)" : ""
        iconView.image = thumbnail ?? Self.symbol(for: item)
        titleLabel.attributedStringValue = Self.title(for: item, ranges: hit.ranges)
        subtitleLabel.stringValue = Self.subtitle(for: item)
    }

    private static func symbol(for item: ClipItem) -> NSImage? {
        let name: String
        switch item.clipKind {
        case .text: name = "text.alignleft"
        case .image: name = "photo"
        case .file: name = "folder"
        case .color: name = "paintpalette"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private static func title(for item: ClipItem, ranges: [Range<String.Index>]) -> NSAttributedString {
        let raw = item.text ?? ""
        let singleLine = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        let cut = String(singleLine.prefix(300))
        let attributed = NSMutableAttributedString(string: cut, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
        ])
        // 命中的词加底色，比只截断更容易扫到
        for range in ranges where range.upperBound <= cut.endIndex {
            attributed.addAttribute(.backgroundColor,
                                    value: NSColor.findHighlightColor,
                                    range: NSRange(range, in: cut))
        }
        return attributed
    }

    private static func subtitle(for item: ClipItem) -> String {
        var parts: [String] = [item.clipKind.title]
        switch item.clipKind {
        case .text:
            parts = ["\(item.text?.count ?? 0) 字"]
        case .image:
            if let bytes = item.byteSize {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
        case .file:
            let count = (item.meta ?? "").split(separator: "\n").count
            parts.append("\(count) 个")
        case .color:
            parts.append(item.text ?? "")
        }
        if let app = item.sourceApp, !app.isEmpty {
            parts.append(app)
        }
        parts.append(Self.relativeTime(item.sortTime))
        return parts.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relativeTime(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        if Date().timeIntervalSince(date) < 60 { return "刚刚" }
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 预览

@MainActor
private final class ClipPreviewView: NSView {
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private let swatch = NSView()
    private let hint = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 6
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false

        for view in [textScroll, imageView, swatch, hint] as [NSView] { addSubview(view) }

        NSLayoutConstraint.activate([
            textScroll.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            textScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            textScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            swatch.centerXAnchor.constraint(equalTo: centerXAnchor),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            swatch.widthAnchor.constraint(equalToConstant: 72),
            swatch.heightAnchor.constraint(equalToConstant: 72),

            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        show(nil, store: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: ClipItem?, store: ClipboardStore?) {
        textScroll.isHidden = true
        imageView.isHidden = true
        swatch.isHidden = true
        hint.isHidden = false

        guard let item else {
            hint.stringValue = "选中一条记录预览"
            return
        }

        switch item.clipKind {
        case .text:
            hint.isHidden = true
            textScroll.isHidden = false
            textView.font = .systemFont(ofSize: 12)
            let text = String((item.text ?? "").prefix(20_000))
            textView.string = text.isEmpty ? "（空）" : text

        case .image:
            hint.isHidden = true
            imageView.isHidden = false
            imageView.image = nil
            if let path = item.blobPath, let store {
                let url = store.blobURL(forRelativePath: path)
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 720,
                    ]
                    if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                        imageView.image = NSImage(cgImage: cg,
                                                  size: NSSize(width: cg.width, height: cg.height))
                    }
                }
            }

        case .file:
            hint.isHidden = true
            textScroll.isHidden = false
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let paths = (item.meta ?? "").split(separator: "\n").joined(separator: "\n")
            textView.string = paths.isEmpty ? "（路径缺失）" : paths

        case .color:
            let hex = item.text ?? "#000000"
            hint.stringValue = hex
            swatch.isHidden = false
            swatch.layer?.backgroundColor = NSColor(hexString: hex)?.cgColor
                ?? NSColor.black.cgColor
        }
    }
}

// MARK: - 缩略图与颜色

/// borderless 窗口默认不能成为 key window，搜索框就收不到输入。
/// 不用 vibrancy：`.behindWindow` 会让历史列表透出后面的窗口文字，搜索时很难读。
/// 纯色底 + 细分隔线，深浅色都跟随系统。
@MainActor
private final class ThumbnailCache {
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 120
    }

    func image(for item: ClipItem, store: ClipboardStore, size: CGFloat) -> NSImage? {
        guard item.clipKind == .image, let path = item.blobPath else { return nil }
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let url = store.blobURL(forRelativePath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(size * 2),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        cache.setObject(image, forKey: key)
        return image
    }
}

private extension NSColor {
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}

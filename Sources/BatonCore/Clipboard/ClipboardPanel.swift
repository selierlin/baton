import AppKit
import Foundation

/// 剪贴板历史浮窗。AppKit 实现：搜索框 + 列表 + 键盘操作。
/// 不切 `.regular`：accessory App 的窗口同样可以成为 key window，切策略反而会让菜单栏闪。
@MainActor
public final class ClipboardPanelController: NSObject {
    public var onCommit: ((ClipItem, Bool) -> Void)?

    private let store: ClipboardStore
    private var items: [ClipItem] = []
    private let panel: KeyablePanel
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "没有匹配的记录")
    private let thumbnails = ThumbnailCache()

    private static let rowHeight: CGFloat = 48
    private static let panelSize = NSSize(width: 460, height: 520)

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
    }

    public var isVisible: Bool { panel.isVisible }

    public func show() {
        reload(query: "")
        searchField.stringValue = ""
        positionOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        // 即使 NSApp.activate() 没被系统采纳，也先把窗口显示出来（只是可能不是 key）
        panel.orderFrontRegardless()
        panel.makeFirstResponder(searchField)
        selectRow(0)
    }

    public func hide() {
        panel.orderOut(nil)
    }

    @objc private func appResignedActive() {
        if panel.isVisible { hide() }
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

        let hint = NSTextField(labelWithString: "↵ 复制    ⌘↵ 粘贴到前台    ⎋ 关闭")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        for view in [searchField, scroll, emptyLabel, hint] as [NSView] {
            background.addSubview(view)
        }
        panel.contentView = background

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            hint.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
        ])
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visible.midX - Self.panelSize.width / 2,
            y: visible.maxY - Self.panelSize.height - 80
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - 数据

    private func reload(query: String) {
        do {
            items = try store.search(query)
        } catch {
            items = []
            NSLog("[Baton] 剪贴板查询失败：\(error)")
        }
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        if items.isEmpty {
            tableView.deselectAll(nil)
        }
    }

    private func selectRow(_ index: Int) {
        guard !items.isEmpty else { return }
        let clamped = min(max(index, 0), items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    private var selectedIndex: Int? {
        let row = tableView.selectedRow
        return row >= 0 && row < items.count ? row : nil
    }

    // MARK: - 动作

    private func commit(paste: Bool) {
        guard let index = selectedIndex else { return }
        let item = items[index]
        hide()
        onCommit?(item, paste)
    }

    @objc private func copyOnly() {
        commit(paste: false)
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
            let paste = NSEvent.modifierFlags.contains(.command)
            commit(paste: paste)
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
        let item = items[row]
        cell.configure(item: item, thumbnail: thumbnails.image(for: item, store: store, size: 32))
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        // 选中态由系统绘制，这里只保证滚动可见
        if let index = selectedIndex {
            tableView.scrollRowToVisible(index)
        }
    }
}

// MARK: - 行视图

private final class ClipRowCell: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

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

        for view in [iconView, titleLabel, subtitleLabel] as [NSView] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: -17),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(item: ClipItem, thumbnail: NSImage?) {
        iconView.image = thumbnail ?? symbol(for: item)
        titleLabel.stringValue = Self.title(for: item)
        subtitleLabel.stringValue = Self.subtitle(for: item)
    }

    private func symbol(for item: ClipItem) -> NSImage? {
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

    private static func title(for item: ClipItem) -> String {
        let raw = item.text ?? ""
        let singleLine = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(singleLine.prefix(200))
    }

    private static func subtitle(for item: ClipItem) -> String {
        var parts: [String] = []
        switch item.clipKind {
        case .text:
            parts.append("\(item.text?.count ?? 0) 字")
        case .image:
            parts.append("图片")
        case .file:
            parts.append("文件")
        case .color:
            parts.append("颜色")
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

// MARK: - 面板与缩略图

/// borderless 窗口默认不能成为 key window，搜索框就收不到输入。
/// 不用 vibrancy：`.behindWindow` 会让历史列表透出后面的窗口文字，搜索时很难读。
/// 纯色底 + 细分隔线，深浅色都跟随系统。
@MainActor
private final class ThumbnailCache {
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 80
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

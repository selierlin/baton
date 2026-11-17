import AppKit
import Foundation

/// 剪贴板历史浮窗：搜索 + 类型筛选 + 列表 + 预览。
///
/// 不切 `.regular`：accessory App 的窗口同样可以成为 key window，切策略反而会让菜单栏闪。
@MainActor
public final class ClipboardPanelController: NSObject {
    /// (条目, 是否直接粘贴到前台, 是否只粘纯文本)
    public var onCommit: ((ClipItem, Bool, Bool) -> Void)?
    /// 多选后回车：把这批条目做成粘贴栈，逐条粘
    public var onCommitStack: (([ClipItem]) -> Void)?

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
    private let tableView = ClipboardTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let preview = ClipPreviewView()
    private let previewColumn = NSView()
    private let listColumn = NSView()
    private var previewConstraints: [NSLayoutConstraint] = []
    private var previewVisible = false
    private let countLabel = NSTextField(labelWithString: "")
    private let thumbnails = ThumbnailCache()
    private var keyMonitor: Any?
    /// 多选的点选先后。`selectedRowIndexes` 只给升序行号，粘不出手的顺序。
    private var selectionOrder = SelectionOrder()

    private static let listWidth: CGFloat = 580
    private static let previewWidth: CGFloat = 360
    private static let panelHeight: CGFloat = 640
    private static let rowHeight: CGFloat = 32
    private static let frameKey = "clipboard.panelOrigin"

    public init(store: ClipboardStore) {
        self.store = store
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: Self.listWidth, height: Self.panelHeight)),
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
        // 每次打开都收着预览，窗口窄一点，不挡屏幕
        setPreviewVisible(false, animated: false)
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
        removeKeyMonitor()
        setPreviewVisible(false, animated: false)
        saveOrigin()
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
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        // 双击直接粘，和回车同义：用户按完快捷键习惯性双击某条，
        // 落到 copyOnly 上只会塞进剪贴板不粘贴，看起来像「双击没反应」。
        tableView.doubleAction = #selector(doubleClickPastes)
        // 键盘动作平时靠搜索框的 doCommandBy 传下来；用鼠标点过列表之后焦点在表格上，
        // 那条路就断了（回车不粘、Esc 不关、⌫ 不删、Tab 不预览），这里接回同一条
        tableView.onCommand = { [weak self] selector in
            self?.handle(command: selector) ?? false
        }

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
        preview.onCopyColor = { [weak self] in self?.copySelectedColor() }

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "↵ 粘贴 · ⌥↵ 纯文本 · ⇧↵ 复制 · ←→ 筛选 · Tab 预览 · ⌘多选连粘")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        // 列表与预览分两栏：预览是右侧抽屉，收起时窗口只有 listWidth 宽，
        // 640 的高度全给列表，能看到 16 条左右。
        // 抽屉收起时必须把 previewColumn 整个摘掉：isHidden 在 AppKit 里不影响
        // Auto Layout，隐藏的预览还会撑出最小宽度，窗口收不回 580。
        listColumn.translatesAutoresizingMaskIntoConstraints = false

        previewColumn.translatesAutoresizingMaskIntoConstraints = false
        previewColumn.addSubview(preview)

        for view in [searchField, filterControl, scroll, emptyLabel, separator, countLabel, hint] as [NSView] {
            listColumn.addSubview(view)
        }
        background.addSubview(listColumn)
        panel.contentView = background

        // 窗口宽度只由 listWidth 决定，提示文字不许反过来撑宽窗口
        for label in [countLabel, hint] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        hint.lineBreakMode = .byTruncatingTail

        NSLayoutConstraint.activate([
            listColumn.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            listColumn.topAnchor.constraint(equalTo: background.topAnchor),
            listColumn.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            listColumn.widthAnchor.constraint(equalToConstant: Self.listWidth),

            preview.topAnchor.constraint(equalTo: previewColumn.topAnchor),
            preview.leadingAnchor.constraint(equalTo: previewColumn.leadingAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: previewColumn.trailingAnchor, constant: -12),
            preview.bottomAnchor.constraint(equalTo: previewColumn.bottomAnchor),

            searchField.topAnchor.constraint(equalTo: listColumn.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor, constant: -12),

            filterControl.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            filterControl.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            filterControl.trailingAnchor.constraint(lessThanOrEqualTo: searchField.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -6),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor, constant: -12),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),

            countLabel.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor, constant: 14),
            countLabel.centerYAnchor.constraint(equalTo: hint.centerYAnchor),

            hint.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor, constant: -14),
            hint.bottomAnchor.constraint(equalTo: listColumn.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - 预览抽屉

    /// 展开/收起右侧预览。窗口向右长，左边不动；右边顶到屏幕就往左长。
    func togglePreview() {
        setPreviewVisible(!previewVisible, animated: true)
    }

    private func setPreviewVisible(_ visible: Bool, animated: Bool) {
        let changed = previewVisible != visible
        previewVisible = visible

        if visible {
            if previewColumn.superview == nil, let host = listColumn.superview {
                host.addSubview(previewColumn)
                previewConstraints = [
                    previewColumn.leadingAnchor.constraint(equalTo: listColumn.trailingAnchor),
                    previewColumn.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    previewColumn.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
                    previewColumn.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12),
                ]
                NSLayoutConstraint.activate(previewConstraints)
            }
        } else if previewColumn.superview != nil {
            NSLayoutConstraint.deactivate(previewConstraints)
            previewConstraints = []
            previewColumn.removeFromSuperview()
        }

        // 目标宽度每次都设：窗口可能被内容最小宽度撑大过，收起时要能收回来。
        // 同时按屏幕可用区域收敛，展开不许顶出屏幕（窄屏就压窄抽屉）。
        var frame = panel.frame
        if let screen = (panel.screen ?? NSScreen.main)?.visibleFrame {
            let width = visible
                ? PanelGeometry.width(list: Self.listWidth, drawer: Self.previewWidth, screen: screen)
                : Self.listWidth
            frame.size.width = width
            if visible {
                // 只在展开时挪位置；收起保持左边不动，窗口才不会来回跳
                frame.origin.x = PanelGeometry.originX(current: frame.minX, width: width, screen: screen)
            }
        } else {
            frame.size.width = Self.listWidth + (visible ? Self.previewWidth : 0)
        }
        if animated, changed {
            panel.setFrame(frame, display: true, animate: true)
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func positionPanel() {
        guard let screen = targetScreen()?.visibleFrame else { return }
        var saved: CGPoint?
        // 早先版本可能存过 {0, 0}（那时是「没位置」的占位），别把它当成真位置
        if let raw = UserDefaults.standard.string(forKey: Self.frameKey) {
            let point = NSPointFromString(raw)
            saved = point == .zero ? nil : point
        }
        panel.setFrameOrigin(PanelGeometry.launchOrigin(saved: saved,
                                                         size: panel.frame.size,
                                                         screen: screen))
    }

    /// 呼出在哪块屏：指针所在的那块。
    ///
    /// 不用 `NSScreen.main` —— 它指「含菜单栏或 key window 的屏」，双屏下经常不是
    /// 用户正在看的那块；也不用前台 App 的焦点窗口，Baton 是常驻 App，触发时
    /// 前台可能刚被系统换成别的进程，会把面板扔到没人在看的屏上。
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
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
        // 列表换了内容，行号对应的条目也换了，旧的先后顺序不能留
        selectionOrder.reset()
        tableView.reloadData()
        selectionOrder.sync(with: tableView.selectedRowIndexes)
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

    /// ⇧↑↓ 扩/缩选区。多选是粘贴栈的入口，纯键盘也要能用。
    private func extendSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        var set = tableView.selectedRowIndexes
        guard !set.isEmpty else {
            selectRow(0)
            return
        }
        if delta > 0 {
            guard let next = set.max().map({ $0 + 1 }), next < items.count else { return }
            set.insert(next)
        } else {
            guard set.count > 1, let last = set.max() else { return }
            set.remove(last)
        }
        tableView.selectRowIndexes(set, byExtendingSelection: false)
        if let row = set.max() {
            tableView.scrollRowToVisible(row)
            if row < items.count { preview.show(items[row].item, store: store) }
        }
    }

    // MARK: - 动作

    /// 预览区的「复制色值」：复制归一化后的 hex，和预览里显示的那串一致。
    ///
    /// 不写回原始 contents（`rgb(...)` 之类）是刻意的：按钮紧挨着 hex 文本，
    /// 复制出别的东西会让人以为点错了。直接写剪贴板，入库时会按颜色去重，不会多一条。
    private func copySelectedColor() {
        guard let index = selectedIndex, index < items.count else { return }
        let item = items[index].item
        guard item.clipKind == .color, let hex = item.text else { return }
        hide()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
    }

    private func commit(paste: Bool, plainText: Bool) {
        // 多选时回车 = 建粘贴栈：之后每按一次 ⌘V 自动换下一条
        let picked = pickedStackItems()
        if picked.count > 1 {
            hide()
            onCommitStack?(picked)
            return
        }
        guard let index = selectedIndex else { return }
        let item = items[index].item
        hide()
        onCommit?(item, paste, plainText)
    }

    /// 多选条目，按点选先后排好。
    ///
    /// 直接拿 `selectedRowIndexes` 会得到升序行号（列表是新的在上），
    /// 粘出来跟点选顺序对不上，所以以 `selectionOrder` 为准；
    /// 万一有行没记上（程序化改选区），按行号补在队尾兜底。
    private func pickedStackItems() -> [ClipItem] {
        let selected = tableView.selectedRowIndexes
        guard selected.count > 1 else { return [] }
        var ordered = selectionOrder.rows.filter { selected.contains($0) }
        for row in selected where !ordered.contains(row) { ordered.append(row) }
        return ordered.compactMap { row in row < items.count ? items[row].item : nil }
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

    /// 双击 = 回车：粘到前台 App。
    ///
    /// 双击前那一下单击已经把选中行换成目标行，这里不用再看点击位置。
    /// 多选状态下仍走 commit 的粘贴栈分支，和回车一致。
    @objc private func doubleClickPastes() {
        commit(paste: true, plainText: NSEvent.modifierFlags.contains(.option))
    }

    @objc private func filterChanged() {
        filter = Self.filterKinds[max(0, min(filterControl.selectedSegment, Self.filterKinds.count - 1))]
        reload(query: searchField.stringValue)
        selectRow(0)
    }

    /// 左右键切换筛选段。到头就停住，不循环——循环容易在两端来回跳。
    private func stepFilter(_ delta: Int) {
        let next = filterControl.selectedSegment + delta
        guard next >= 0, next < Self.filterKinds.count else { return }
        filterControl.selectedSegment = next
        filterChanged()
    }

    private static let filterKinds: [ClipKind?] = [nil, .text, .image, .file, .color]

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
            if NSEvent.modifierFlags.contains(.shift) {
                extendSelection(by: -1)
            } else {
                selectRow((selectedIndex ?? 0) - 1)
            }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if NSEvent.modifierFlags.contains(.shift) {
                extendSelection(by: 1)
            } else {
                selectRow((selectedIndex ?? -1) + 1)
            }
            return true
        // 文本框里 ⇧↑↓ 走的是 *AndModifySelection:，不是 moveUp/moveDown
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            extendSelection(by: -1)
            return true
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            extendSelection(by: 1)
            return true
        case #selector(NSResponder.selectAll(_:)):
            guard !items.isEmpty else { return true }
            tableView.selectRowIndexes(IndexSet(integersIn: 0..<items.count), byExtendingSelection: false)
            if let last = items.last { preview.show(last.item, store: store) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let flags = NSEvent.modifierFlags
            // 回车默认直接粘到前台 App（和 Maccy / Raycast 一致）；
            // ⇧↵ 才是「只复制不粘贴」，⌥↵ 粘纯文本。
            if flags.contains(.shift) {
                commit(paste: false, plainText: false)
            } else {
                commit(paste: true, plainText: flags.contains(.option))
            }
            return true
        case #selector(NSResponder.moveLeft(_:)),
             #selector(NSResponder.moveRight(_:)):
            // 搜索框有字时左右键归光标，空的时候才切类型筛选
            guard searchField.stringValue.isEmpty else { return false }
            stepFilter(selector == #selector(NSResponder.moveLeft(_:)) ? -1 : 1)
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab 用来开合右侧预览，比 ⌃Space 稳（那个被输入法占着）
            togglePreview()
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
                       thumbnail: thumbnails.image(for: hit.item, store: store, size: 20),
                       order: orderBadge(for: row))
        return cell
    }

    /// 多选时行尾那个序号＝第几个粘，单选时不显示。
    private func orderBadge(for row: Int) -> Int? {
        guard tableView.selectedRowIndexes.count > 1,
              let index = selectionOrder.rows.firstIndex(of: row) else { return nil }
        return index + 1
    }

    private func refreshOrderBadges() {
        for row in 0..<items.count {
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipRowCell
            cell?.setOrder(orderBadge(for: row))
        }
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        selectionOrder.sync(with: tableView.selectedRowIndexes)
        refreshOrderBadges()
        guard let index = selectedIndex else { return }
        tableView.scrollRowToVisible(index)
        preview.show(items[index].item, store: store)
    }
}

// MARK: - 列表

/// 列表自己的键盘处理。
///
/// 面板里所有动作都写在 `handle(command:)`，但入口只有搜索框的 `doCommandBy`。
/// 鼠标点一下行，第一响应者就变成表格，回车/ Esc / Tab / ⌫ 再也没人接 ——
/// 多选连粘这条路上，用户正是先点选再按回车，所以一定会踩到。
/// 上下键仍交给 NSTableView 自己处理（原生扩选、滚动都正常）。
final class ClipboardTableView: NSTableView {
    var onCommand: ((Selector) -> Bool)?

    private static let commands: [UInt16: Selector] = [
        36: #selector(NSResponder.insertNewline(_:)),   // Return
        76: #selector(NSResponder.insertNewline(_:)),   // 小键盘 Enter
        48: #selector(NSResponder.insertTab(_:)),
        51: #selector(NSResponder.deleteBackward(_:)),
        117: #selector(NSResponder.deleteForward(_:)),
        53: #selector(NSResponder.cancelOperation(_:)),
        123: #selector(NSResponder.moveLeft(_:)),
        124: #selector(NSResponder.moveRight(_:)),
    ]

    override func keyDown(with event: NSEvent) {
        // 带 ⌘ 的组合留给系统（⌘A 全选、⌘C 等），别抢
        if !event.modifierFlags.contains(.command),
           let command = Self.commands[event.keyCode],
           onCommand?(command) == true {
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - 行视图

private final class ClipRowCell: NSTableCellView {
    private let indexLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    /// 多选时的「第几个粘」角标
    private let orderBadge = OrderBadge()

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
        // 标题先被压缩，时间固定给足
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .right
        timeLabel.maximumNumberOfLines = 1
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        orderBadge.translatesAutoresizingMaskIntoConstraints = false
        orderBadge.setContentHuggingPriority(.required, for: .horizontal)
        orderBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [indexLabel, iconView, titleLabel, timeLabel, orderBadge] as [NSView] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            indexLabel.widthAnchor.constraint(equalToConstant: 14),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconView.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: orderBadge.leadingAnchor, constant: -8),

            orderBadge.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -8),
            orderBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            orderBadge.heightAnchor.constraint(equalToConstant: 14),

            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(hit: ClipHit, index: Int, thumbnail: NSImage?, order: Int?) {
        let item = hit.item
        indexLabel.stringValue = index <= 9 ? "\(index)" : ""
        iconView.image = thumbnail ?? Self.colorSwatch(for: item) ?? Self.symbol(for: item)
        // 路径的文件名在末尾，尾部截断会把最有用的部分切掉，改成中间截断
        titleLabel.lineBreakMode = item.clipKind == .file ? .byTruncatingMiddle : .byTruncatingTail
        titleLabel.attributedStringValue = Self.title(for: item, ranges: hit.ranges)
        timeLabel.stringValue = Self.relativeTime(item.sortTime)
        setOrder(order)
    }

    /// 多选时显示「第几个粘」，单选时收起（宽度收到 0，不占位）。
    func setOrder(_ order: Int?) {
        orderBadge.order = order
    }

    /// 颜色条目直接画一块色，比统一画调色板图标好认。
    private static func colorSwatch(for item: ClipItem) -> NSImage? {
        guard item.clipKind == .color,
              let hex = item.text,
              let color = NSColor(hexString: hex) else { return nil }
        let box = NSRect(x: 1, y: 1, width: 18, height: 18)
        return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            color.setFill()
            path.fill()
            // 白色/深色色块在深浅底色上都可能糊掉，描一圈分隔线兜底
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
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
            .foregroundColor: NSColor.labelColor,
        ])
        // 命中的词加底色，比只截断更容易扫到。
        // 底色是固定亮黄，深色模式下 labelColor 是白的，黄底白字几乎看不见，
        // 所以高亮区间必须显式压成黑字。
        // ranges 基于原文，展示串去掉了换行又截断过，索引不能直接复用，
        // 只取命中的词在展示串里重新定位。
        let keywords = Set(ranges.map { String(raw[$0]) }.filter { !$0.isEmpty })
        for keyword in keywords {
            var start = cut.startIndex
            while let found = cut.range(of: keyword, options: .caseInsensitive, range: start..<cut.endIndex) {
                attributed.addAttributes([
                    .backgroundColor: NSColor.findHighlightColor,
                    .foregroundColor: NSColor.black,
                ], range: NSRange(found, in: cut))
                start = found.upperBound
            }
        }
        return attributed
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

/// 多选连粘时行尾的「第几个粘」小圆标。
///
/// 用 `labelColor` / `textBackgroundColor` 这对反转色而不是强调色：行被选中时
/// 背景本身就是强调色，强调色的小标贴上去会糊成一片。
private final class OrderBadge: NSView {
    var order: Int? {
        didSet {
            isHidden = order == nil
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let order else { return NSSize(width: 0, height: 14) }
        return NSSize(width: order >= 10 ? 20 : 15, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let order else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        NSColor.labelColor.setFill()
        path.fill()

        let text = "\(order)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.textBackgroundColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                              y: bounds.midY - size.height / 2),
                  withAttributes: attrs)
    }
}

// MARK: - 预览

/// 预览区顶部的一行元信息。列表行只保留时间，其余都挪到这里，
/// 换来更密的行高（同屏能多看一半条目）。
private func clipDetailParts(for item: ClipItem) -> [String] {
    var parts: [String] = [item.clipKind.title]
    switch item.clipKind {
    case .text:
        parts.append("\(item.text?.count ?? 0) 字")
    case .image:
        if let width = item.pixelWidth, let height = item.pixelHeight {
            parts.append("\(width)×\(height)")
        }
        if let bytes = item.byteSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
    case .file:
        let count = (item.meta ?? "").split(separator: "\n").count
        parts.append("\(count) 个文件")
    case .color:
        break
    }
    return parts
}

@MainActor
private final class ClipPreviewView: NSView {
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private let swatch = NSView()
    private let hint = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "复制色值", target: nil, action: nil)
    private let metaLabel = NSTextField(labelWithString: "")
    /// 颜色预览里的「复制色值」：面板会把选中的颜色条目按普通复制提交
    var onCopyColor: (() -> Void)?

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

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyColorValue)
        copyButton.toolTip = "复制 #RRGGBB"
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.isHidden = true

        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [textScroll, imageView, swatch, hint, copyButton, metaLabel] as [NSView] { addSubview(view) }

        NSLayoutConstraint.activate([
            metaLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            textScroll.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 4),
            textScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            textScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            imageView.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 4),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            swatch.centerXAnchor.constraint(equalTo: centerXAnchor),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            swatch.widthAnchor.constraint(equalToConstant: 72),
            swatch.heightAnchor.constraint(equalToConstant: 72),

            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            copyButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            copyButton.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
        ])
        show(nil, store: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 元信息行：`文字 · 32 字 · [Chrome 图标] Google Chrome`。
    /// 图标做成文本附件，跟着应用名一起排版，不用另起一个视图对齐。
    private static func metaText(for item: ClipItem) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = NSMutableAttributedString(
            string: clipDetailParts(for: item).joined(separator: " · "),
            attributes: attributes
        )

        guard let app = item.sourceApp, !app.isEmpty else { return text }
        text.append(NSAttributedString(string: " · ", attributes: attributes))
        if let icon = AppIconProvider.shared.icon(bundleID: item.sourceBundleID,
                                                  appName: app,
                                                  pointSize: 13) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            // 底边压到基线以下，跟 11pt 文字视觉居中
            attachment.bounds = CGRect(x: 0, y: -2.5, width: 13, height: 13)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " \(app)", attributes: attributes))
        } else {
            // 查不到图标（App 已卸载、来源是 loginwindow 之类）时保留文字说明
            text.append(NSAttributedString(string: "来自 \(app)", attributes: attributes))
        }
        return text
    }

    func show(_ item: ClipItem?, store: ClipboardStore?) {
        textScroll.isHidden = true
        imageView.isHidden = true
        swatch.isHidden = true
        copyButton.isHidden = true
        hint.isHidden = false

        guard let item else {
            metaLabel.stringValue = ""
            hint.stringValue = "选中一条记录预览"
            return
        }
        metaLabel.attributedStringValue = Self.metaText(for: item)

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
            hint.isHidden = false
            swatch.isHidden = false
            copyButton.isHidden = false
            swatch.layer?.backgroundColor = NSColor(hexString: hex)?.cgColor
                ?? NSColor.black.cgColor
        }
    }

    @objc private func copyColorValue() {
        onCopyColor?()
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

import AppKit

/// 设置里的「历史」页：看清占了多少地方、调上限，然后按时间或整体清掉。
///
/// 贴图钉住的条目会被跳过——它们还挂在屏幕上，删了贴图会空掉。
@MainActor
final class HistorySettingsPage: NSView {
    /// 清完之后通知外面（面板若开着要重读列表）
    var onChange: (() -> Void)?

    private let store: ClipboardStore?
    private let usageLabel = NSTextField(labelWithString: "—")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let itemsPopup = NSPopUpButton()
    private let bytesPopup = NSPopUpButton()
    private let ocrToggle = NSButton(checkboxWithTitle: "用 OCR 给图片生成标题（图里的字也能搜到）",
                                     target: nil, action: nil)

    init(store: ClipboardStore?) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        usageLabel.font = .systemFont(ofSize: 12)
        usageLabel.textColor = .secondaryLabelColor
        usageLabel.maximumNumberOfLines = 2

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.maximumNumberOfLines = 2

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        itemsPopup.addItems(withTitles: ClipboardPrefs.maxItemsChoices.map { "\($0) 条" })
        itemsPopup.target = self
        itemsPopup.action = #selector(limitsChanged)

        bytesPopup.addItems(withTitles: ClipboardPrefs.maxBytesChoices.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        })
        bytesPopup.target = self
        bytesPopup.action = #selector(limitsChanged)

        ocrToggle.target = self
        ocrToggle.action = #selector(ocrChanged)
        ocrToggle.state = ClipboardPrefs.shared.ocrTitles ? .on : .off

        let cleanOld = NSButton(title: "清理 30 天前", target: self, action: #selector(cleanOld))
        cleanOld.bezelStyle = .rounded

        let cleanAll = NSButton(title: "清空历史…", target: self, action: #selector(cleanAll))
        cleanAll.bezelStyle = .rounded

        let buttons = NSStackView(views: [cleanOld, cleanAll, statusLabel])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        SettingsLayout.install([
            SettingsLayout.section("占用", [
                SettingsLayout.plain(usageLabel),
                SettingsLayout.plain(detailLabel),
                SettingsLayout.plain(buttons),
            ]),
            SettingsLayout.section("上限", [
                SettingsLayout.row("最多保留", detail: "超出后按最旧记录裁剪，钉在屏幕上的贴图不动。",
                                   control: itemsPopup),
                SettingsLayout.row("总占用上限", detail: "图片和富文本都算在内。",
                                   control: bytesPopup),
            ]),
            SettingsLayout.section("图片", [
                SettingsLayout.plain(ocrToggle),
            ]),
        ], in: self)

        reload()
    }

    func reload() {
        statusLabel.stringValue = ""
        guard let store else {
            usageLabel.stringValue = "剪贴板历史没有启用"
            detailLabel.stringValue = ""
            return
        }
        guard let usage = try? store.usage() else {
            usageLabel.stringValue = "读取历史统计失败"
            return
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: Int64(usage.bytes))
        usageLabel.stringValue = "共 \(usage.count) 条，合计 \(size)"
        usageLabel.sizeToFit()

        let textBytes = usage.kindBytes[ClipKind.text.rawValue] ?? 0
        let imageBytes = usage.kindBytes[ClipKind.image.rawValue] ?? 0
        let fileBytes = usage.kindBytes[ClipKind.file.rawValue] ?? 0
        var detail = "文字 \(formatter.string(fromByteCount: Int64(textBytes)))"
            + " · 图片 \(formatter.string(fromByteCount: Int64(imageBytes)))"
        if fileBytes > 0 {
            detail += " · 文件 \(formatter.string(fromByteCount: Int64(fileBytes)))"
        }
        if usage.pinnedCount > 0 {
            detail += "\n\(usage.pinnedCount) 张贴图钉在屏幕上，不会被清理。"
        }
        detailLabel.stringValue = detail

        if let index = ClipboardPrefs.maxItemsChoices.firstIndex(of: ClipboardPrefs.shared.maxItems) {
            itemsPopup.selectItem(at: index)
        }
        if let index = ClipboardPrefs.maxBytesChoices.firstIndex(of: ClipboardPrefs.shared.maxBytes) {
            bytesPopup.selectItem(at: index)
        }
    }

    // MARK: - 动作

    @objc private func limitsChanged() {
        ClipboardPrefs.shared.maxItems = ClipboardPrefs.maxItemsChoices[max(0, itemsPopup.indexOfSelectedItem)]
        ClipboardPrefs.shared.maxBytes = ClipboardPrefs.maxBytesChoices[max(0, bytesPopup.indexOfSelectedItem)]

        guard let store else { return }
        do {
            let removed = try store.trim()
            reload()
            statusLabel.stringValue = removed > 0 ? "已按新上限清理 \(removed) 条" : "已生效"
            onChange?()
        } catch {
            statusLabel.stringValue = "应用失败：\(error.localizedDescription)"
        }
    }

    @objc private func ocrChanged() {
        ClipboardPrefs.shared.ocrTitles = ocrToggle.state == .on
        statusLabel.stringValue = ocrToggle.state == .on ? "之后复制的图片会识别标题" : "已关闭图片标题识别"
    }

    @objc private func cleanOld() {
        guard let store else { return }
        do {
            let removed = try store.deleteOlderThan(days: 30)
            reload()
            // reload 会清空提示，所以要放在它后面写
            statusLabel.stringValue = removed > 0 ? "已清理 \(removed) 条" : "30 天内没有可清理的记录"
            NotificationCenter.default.post(name: .batonClipboardDidChange, object: nil)
            onChange?()
        } catch {
            statusLabel.stringValue = "清理失败：\(error.localizedDescription)"
        }
    }

    @objc private func cleanAll() {
        guard let store else { return }
        Task { [weak self] in
            guard let self else { return }
            let confirmed = await ModalAlert.confirm(title: "清空剪贴板历史？",
                                                     message: "文字、图片、文件记录都会被删除，无法恢复。钉在屏幕上的贴图不受影响。",
                                                     confirm: "清空",
                                                     name: "history.clear",
                                                     above: self.window)
            guard confirmed else { return }
            self.performClear(store)
        }
    }

    private func performClear(_ store: ClipboardStore) {
        do {
            let removed = try store.deleteAllUnpinned()
            reload()
            statusLabel.stringValue = removed > 0 ? "已清空 \(removed) 条" : "历史已经是空的"
            ActionLog.result("history.clear", "removed=\(removed)")
            NotificationCenter.default.post(name: .batonClipboardDidChange, object: nil)
            onChange?()
        } catch {
            statusLabel.stringValue = "清空失败：\(error.localizedDescription)"
            ActionLog.fail("history.clear", "reason=\(error.localizedDescription)")
        }
    }
}

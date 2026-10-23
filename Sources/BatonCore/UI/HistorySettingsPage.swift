import AppKit

/// 设置里的「历史」页：看清占了多少地方，然后按时间或整体清掉。
///
/// 贴图钉住的条目会被跳过——它们还挂在屏幕上，删了贴图会空掉。
@MainActor
final class HistorySettingsPage: NSView {
    /// 清完之后通知外面（面板若开着要重读列表）
    var onChange: (() -> Void)?

    private let store: ClipboardStore?
    private let usageLabel = NSTextField(labelWithString: "—")
    private let statusLabel = NSTextField(labelWithString: "")

    init(store: ClipboardStore?) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 350))
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        usageLabel.font = .systemFont(ofSize: 12)
        usageLabel.textColor = .secondaryLabelColor
        usageLabel.maximumNumberOfLines = 2

        let cleanOld = NSButton(title: "清理 30 天前", target: self, action: #selector(cleanOld))
        cleanOld.bezelStyle = .rounded

        let cleanAll = NSButton(title: "清空历史…", target: self, action: #selector(cleanAll))
        cleanAll.bezelStyle = .rounded

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let buttons = NSStackView(views: [cleanOld, cleanAll, statusLabel])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let hint = NSTextField(labelWithString: "最多保留 800 条，超出后自动删最旧的；钉在屏幕上的贴图不会被清理。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.maximumNumberOfLines = 2

        SettingsLayout.install([
            SettingsLayout.section("占用", [
                SettingsLayout.plain(usageLabel),
                SettingsLayout.plain(buttons),
            ]),
            SettingsLayout.plain(hint),
        ], in: self)
    }

    func reload() {
        statusLabel.stringValue = ""
        guard let store else {
            usageLabel.stringValue = "剪贴板历史没有启用"
            return
        }
        guard let usage = try? store.usage() else {
            usageLabel.stringValue = "读取历史统计失败"
            return
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(usage.bytes), countStyle: .file)
        var text = "共 \(usage.count) 条记录，其中图片 \(usage.imageCount) 条，合计 \(size)。"
        if usage.pinnedCount > 0 {
            text += "\n\(usage.pinnedCount) 张贴图钉在屏幕上，不会被清理。"
        }
        usageLabel.stringValue = text
        usageLabel.sizeToFit()
    }

    @objc private func cleanOld() {
        guard let store else { return }
        do {
            let removed = try store.deleteOlderThan(days: 30)
            reload()
            // reload 会清空提示，所以要放在它后面写
            statusLabel.stringValue = removed > 0 ? "已清理 \(removed) 条" : "30 天内没有可清理的记录"
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
            onChange?()
        } catch {
            statusLabel.stringValue = "清空失败：\(error.localizedDescription)"
            ActionLog.fail("history.clear", "reason=\(error.localizedDescription)")
        }
    }
}

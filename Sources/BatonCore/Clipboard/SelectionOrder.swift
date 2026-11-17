import Foundation

/// 多选粘贴栈的顺序。
///
/// `NSTableView.selectedRowIndexes` 是 `IndexSet`，天生按行号升序，
/// 记不住「先点第 3 条、再点第 1 条」这种先后。粘贴栈恰恰要按手的顺序粘，
/// 所以这里跟着选区变化增量维护一份序列。
struct SelectionOrder {
    /// 按点选先后排列的行号。
    private(set) var rows: [Int] = []

    /// 把选区变化并进来：取消选中的行剔除，新选中的行追加到队尾。
    mutating func sync(with selection: IndexSet) {
        rows.removeAll { !selection.contains($0) }
        let added = selection.filter { !rows.contains($0) }
        guard !added.isEmpty else { return }
        rows.append(contentsOf: Self.sequence(added, after: rows.last))
    }

    mutating func reset() {
        rows.removeAll()
    }

    /// 新选中的行按「扩张方向」排：⇧ 往下拉是升序，往上拉是降序，
    /// 这样连选出来的栈跟视线扫过的顺序一致。没有锚点（首次框选、⌘A）时按行号升序。
    private static func sequence(_ added: [Int], after anchor: Int?) -> [Int] {
        guard added.count > 1, let anchor else { return added.sorted() }
        if added.contains(anchor + 1) { return added.sorted() }
        if added.contains(anchor - 1) { return added.sorted(by: >) }
        return added.sorted()
    }
}

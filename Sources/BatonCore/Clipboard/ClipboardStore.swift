import CoreGraphics
import Foundation
import GRDB

public enum ClipKind: Int, Sendable, CaseIterable {
    case text = 1
    case image = 2
    case file = 3
    case color = 4

    public var title: String {
        switch self {
        case .text: return "文字"
        case .image: return "图片"
        case .file: return "文件"
        case .color: return "颜色"
        }
    }
}

public struct ClipItem: Sendable, Codable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "item"

    public var id: String
    public var kind: Int
    public var createdAt: Double
    public var lastUsedAt: Double?
    public var sourceApp: String?
    public var contentHash: String
    public var text: String?
    public var blobPath: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var scale: Double?
    public var byteSize: Int?
    public var meta: String?

    public var clipKind: ClipKind { ClipKind(rawValue: kind) ?? .text }

    /// 列表里显示的时间：用过的时间优先
    public var sortTime: Double { lastUsedAt ?? createdAt }
}

/// 一条待写入的内容。hash 由 PasteboardReader 算好，store 只负责去重与落库。
///
/// `contents` 为空时按旧字段（text / pngData / meta）合成一份，方便贴图这类调用方。
public struct ClipDraft: Sendable {
    public var kind: ClipKind
    public var contentHash: String
    public var text: String?
    public var pngData: Data?
    public var imageExt: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var byteSize: Int
    public var sourceApp: String?
    public var meta: String?
    public var contents: [ClipContent]

    public init(
        kind: ClipKind,
        contentHash: String,
        text: String? = nil,
        pngData: Data? = nil,
        imageExt: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        byteSize: Int = 0,
        sourceApp: String? = nil,
        meta: String? = nil,
        contents: [ClipContent] = []
    ) {
        self.kind = kind
        self.contentHash = contentHash
        self.text = text
        self.pngData = pngData
        self.imageExt = imageExt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteSize = byteSize
        self.sourceApp = sourceApp
        self.meta = meta
        self.contents = contents
    }
}

public struct ClipInsertResult: Sendable {
    public let item: ClipItem
    /// 已存在同内容，只把时间提到了最前
    public let deduplicated: Bool
}

/// 一条搜索结果：条目 + 命中区间（列表里做高亮）。
public struct ClipHit: Sendable {
    public let item: ClipItem
    public let ranges: [Range<String.Index>]

    public init(item: ClipItem, ranges: [Range<String.Index>]) {
        self.item = item
        self.ranges = ranges
    }
}

public final class ClipboardStore: Sendable {
    private let db: BatonDatabase
    private let maxItemsOverride: Int?
    private let maxBytesOverride: Int?

    /// 条数上限。传了就用传的（单测），没传读设置，改完立即生效。
    public var maxItems: Int { maxItemsOverride ?? ClipboardPrefs.shared.maxItems }
    /// 图片与富文本都算在内，超过后按最旧裁剪（钉住的除外）
    public var maxBytes: Int { maxBytesOverride ?? ClipboardPrefs.shared.maxBytes }

    public init(directory: URL? = nil, maxItems: Int? = nil, maxBytes: Int? = nil) throws {
        self.db = try BatonDatabase(directory: directory)
        self.maxItemsOverride = maxItems
        self.maxBytesOverride = maxBytes
    }

    /// 与其他 store 共用同一条数据库连接（贴图要往同一个库里写 item）。
    public init(database: BatonDatabase,
                maxItems: Int? = nil,
                maxBytes: Int? = nil) {
        self.db = database
        self.maxItemsOverride = maxItems
        self.maxBytesOverride = maxBytes
    }

    public var database: BatonDatabase { db }

    private static let columns = """
        id, kind, createdAt, lastUsedAt, sourceApp, contentHash, text, blobPath,
        pixelWidth, pixelHeight, scale, byteSize, meta
        """

    // MARK: - 写入

    public func insert(_ draft: ClipDraft, now: Double = Date().timeIntervalSince1970) throws -> ClipInsertResult {
        try db.dbQueue.write { conn in
            if let existing = try ClipItem.fetchOne(
                conn,
                sql: "SELECT \(Self.columns) FROM item WHERE contentHash = ?",
                arguments: [draft.contentHash]
            ) {
                try conn.execute(
                    sql: "UPDATE item SET lastUsedAt = ? WHERE id = ?",
                    arguments: [now, existing.id]
                )
                var touched = existing
                touched.lastUsedAt = now
                return ClipInsertResult(item: touched, deduplicated: true)
            }

            var contents = draft.contents
            if contents.isEmpty {
                contents = Self.legacyContents(draft)
            }

            var blobPath: String?
            var resolved: [ClipContent] = []
            resolved.reserveCapacity(contents.count)
            for var content in contents {
                if content.blobPath == nil,
                   ClipType.isImage(content.type),
                   let data = content.value {
                    let ext = draft.imageExt ?? ClipType.imageExt(for: content.type) ?? "png"
                    let path = try db.writeBlob(data, hash: draft.contentHash, ext: ext)
                    blobPath = path
                    content.value = nil
                    content.blobPath = path
                }
                resolved.append(content)
            }

            let item = ClipItem(
                id: UUID().uuidString,
                kind: draft.kind.rawValue,
                createdAt: now,
                lastUsedAt: nil,
                sourceApp: draft.sourceApp,
                contentHash: draft.contentHash,
                text: draft.text,
                blobPath: blobPath,
                pixelWidth: draft.pixelWidth,
                pixelHeight: draft.pixelHeight,
                scale: nil,
                byteSize: draft.byteSize,
                meta: draft.meta
            )
            try item.insert(conn)
            // 必须马上取 rowid：后面插 item_content 会把 lastInsertedRowID 顶掉，
            // FTS 就写到 item_content 的 rowid 上了，搜索自然命不中。
            let itemRowID = conn.lastInsertedRowID

            for (index, content) in resolved.enumerated() {
                try conn.execute(sql: """
                    INSERT INTO item_content (itemID, type, ordinal, value, blobPath)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [item.id, content.type, index, content.value, content.blobPath])
            }

            try Self.indexFTS(conn, rowid: itemRowID, text: item.text)
            return ClipInsertResult(item: item, deduplicated: false)
        }
    }

    /// 调用方没给 contents 时，把旧字段翻译成一份表示。
    private static func legacyContents(_ draft: ClipDraft) -> [ClipContent] {
        switch draft.kind {
        case .image:
            guard let png = draft.pngData else { return [] }
            return [ClipContent(type: "public.png", value: png)]
        case .file:
            return (draft.meta ?? "")
                .split(separator: "\n")
                .map { path in
                    ClipContent(type: ClipType.fileURL,
                                value: URL(fileURLWithPath: String(path)).dataRepresentation)
                }
        case .text, .color:
            guard let text = draft.text else { return [] }
            return [ClipContent(type: ClipType.string, value: Data(text.utf8))]
        }
    }

    private static func indexFTS(_ db: Database, rowid: Int64, text: String?) throws {
        guard let text, !text.isEmpty else { return }
        try db.execute(sql: "INSERT INTO item_fts(rowid, text) VALUES (?, ?)", arguments: [rowid, text])
    }

    /// 图片 OCR 等异步回填标题后要一起更新索引。
    public func updateText(id: String, text: String) throws {
        try db.dbQueue.write { conn in
            try conn.execute(sql: "UPDATE item SET text = ? WHERE id = ?", arguments: [text, id])
            guard let rowid = try Int64.fetchOne(conn, sql: "SELECT rowid FROM item WHERE id = ?",
                                                 arguments: [id]) else { return }
            try conn.execute(sql: "DELETE FROM item_fts WHERE rowid = ?", arguments: [rowid])
            try Self.indexFTS(conn, rowid: rowid, text: text)
        }
    }

    // MARK: - 查询

    public func recent(limit: Int = 200) throws -> [ClipItem] {
        try db.dbQueue.read { conn in
            try ClipItem.fetchAll(
                conn,
                sql: """
                    SELECT \(Self.columns) FROM item
                    ORDER BY COALESCE(lastUsedAt, createdAt) DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
        }
    }

    /// 原始表示，供回写用。图片那条的 `value` 为空、`blobPath` 有值。
    public func contents(for itemID: String) throws -> [ClipContent] {
        try db.dbQueue.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT type, ordinal, value, blobPath FROM item_content
                WHERE itemID = ? ORDER BY ordinal, id
                """, arguments: [itemID])
            return rows.map { row in
                ClipContent(type: row["type"], value: row["value"], blobPath: row["blobPath"])
            }
        }
    }

    /// ≥3 字符走 FTS5 trigram，<3 字符（中文两字词）降级 LIKE。
    public func search(_ keyword: String, kind: ClipKind? = nil, limit: Int = 200) throws -> [ClipItem] {
        try searchHits(keyword, kind: kind, limit: limit).map(\.item)
    }

    public func searchHits(_ keyword: String, kind: ClipKind? = nil, limit: Int = 200) throws -> [ClipHit] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let items: [ClipItem]
        if trimmed.isEmpty {
            items = try listRecent(kind: kind, limit: limit)
        } else if trimmed.count >= 3 {
            let matches = try ftsSearch(trimmed, kind: kind, limit: limit)
            items = matches.isEmpty ? try likeSearch(trimmed, kind: kind, limit: limit) : matches
        } else {
            items = try likeSearch(trimmed, kind: kind, limit: limit)
        }
        return items.map { ClipHit(item: $0, ranges: Self.ranges(of: trimmed, in: $0.text ?? "")) }
    }

    private func listRecent(kind: ClipKind?, limit: Int) throws -> [ClipItem] {
        try db.dbQueue.read { conn in
            let filter = kind.map { _ in "WHERE kind = ?" } ?? ""
            var arguments: [(any DatabaseValueConvertible)?] = []
            if let kind { arguments.append(kind.rawValue) }
            arguments.append(limit)
            return try ClipItem.fetchAll(
                conn,
                sql: """
                    SELECT \(Self.columns) FROM item
                    \(filter)
                    ORDER BY COALESCE(lastUsedAt, createdAt) DESC
                    LIMIT ?
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    private func ftsSearch(_ keyword: String, kind: ClipKind?, limit: Int) throws -> [ClipItem] {
        try db.dbQueue.read { conn in
            let filter = kind.map { _ in "AND kind = ?" } ?? ""
            var arguments: [(any DatabaseValueConvertible)?] = [Self.ftsPhrase(keyword)]
            if let kind { arguments.append(kind.rawValue) }
            arguments.append(limit)
            return try ClipItem.fetchAll(
                conn,
                sql: """
                    SELECT \(Self.columns) FROM item
                    WHERE rowid IN (SELECT rowid FROM item_fts WHERE item_fts MATCH ?)
                    \(filter)
                    ORDER BY COALESCE(lastUsedAt, createdAt) DESC
                    LIMIT ?
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    private func likeSearch(_ keyword: String, kind: ClipKind?, limit: Int) throws -> [ClipItem] {
        let escaped = keyword
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try db.dbQueue.read { conn in
            let filter = kind.map { _ in "AND kind = ?" } ?? ""
            var arguments: [(any DatabaseValueConvertible)?] = ["%\(escaped)%"]
            if let kind { arguments.append(kind.rawValue) }
            arguments.append(limit)
            return try ClipItem.fetchAll(
                conn,
                sql: """
                    SELECT \(Self.columns) FROM item
                    WHERE text LIKE ? ESCAPE '\\'
                    \(filter)
                    ORDER BY COALESCE(lastUsedAt, createdAt) DESC
                    LIMIT ?
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    /// 命中区间用于高亮。只做大小写不敏感的字面匹配，正则命中的位置交给列表自己截断。
    static func ranges(of keyword: String, in text: String, limit: Int = 32) -> [Range<String.Index>] {
        guard !keyword.isEmpty, !text.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while result.count < limit, searchStart < text.endIndex,
              let found = text.range(of: keyword, options: .caseInsensitive,
                                     range: searchStart..<text.endIndex) {
            result.append(found)
            searchStart = found.upperBound
        }
        return result
    }

    /// FTS5 语法字符很多，整体加双引号当短语，内部引号翻倍。
    static func ftsPhrase(_ keyword: String) -> String {
        "\"" + keyword.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func item(id: String) throws -> ClipItem? {
        try db.dbQueue.read { conn in
            try ClipItem.fetchOne(conn, sql: "SELECT \(Self.columns) FROM item WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - 维护

    public func touch(id: String, now: Double = Date().timeIntervalSince1970) throws {
        try db.dbQueue.write { conn in
            try conn.execute(sql: "UPDATE item SET lastUsedAt = ? WHERE id = ?", arguments: [now, id])
        }
    }

    public func delete(id: String) throws {
        try db.dbQueue.write { conn in
            try Self.delete(conn, ids: [id])
        }
        try db.collectOrphanBlobs()
    }

    /// 按条数与总字节裁剪，被钉住（贴图挂在屏幕上）的条目不能删。
    @discardableResult
    public func trim() throws -> Int {
        try db.dbQueue.write { conn in
            let candidates = try Row.fetchAll(conn, sql: """
                SELECT id, COALESCE(byteSize, 0) AS byteSize FROM item
                WHERE id NOT IN (SELECT itemID FROM pin_instance)
                ORDER BY COALESCE(lastUsedAt, createdAt) ASC
                """)

            let totalBytes = try Int.fetchOne(conn, sql: "SELECT COALESCE(SUM(byteSize), 0) FROM item") ?? 0
            let totalCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? 0
            // 条数按「含钉住的总数」算：设置页写的是「最多保留 N 条」，用户按这个理解
            let overflow = max(0, totalCount - maxItems)

            var doomed = Array(candidates.prefix(overflow).map { $0["id"] as String })
            var bytes = totalBytes - candidates.prefix(overflow).reduce(0) { $0 + ($1["byteSize"] as Int) }

            if maxBytes > 0 {
                for row in candidates.dropFirst(doomed.count) where bytes > maxBytes {
                    doomed.append(row["id"])
                    bytes -= row["byteSize"]
                }
            }

            guard !doomed.isEmpty else { return 0 }
            try Self.delete(conn, ids: doomed)
            return doomed.count
        }
        // 注意：trim 不在这里做 blob GC，调用方在批量结束后统一 GC，避免每删一条扫一次目录
    }

    public func collectOrphanBlobs() throws -> Int {
        try db.collectOrphanBlobs()
    }

    private static func delete(_ conn: Database, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let marks = databaseQuestionMarks(count: ids.count)
        let arguments = StatementArguments(ids)
        let rowids = try Int64.fetchAll(conn, sql: "SELECT rowid FROM item WHERE id IN (\(marks))",
                                        arguments: arguments)
        try conn.execute(sql: "DELETE FROM item WHERE id IN (\(marks))", arguments: arguments)
        try conn.execute(sql: "DELETE FROM item_content WHERE itemID IN (\(marks))", arguments: arguments)
        if !rowids.isEmpty {
            try conn.execute(
                sql: "DELETE FROM item_fts WHERE rowid IN (\(databaseQuestionMarks(count: rowids.count)))",
                arguments: StatementArguments(rowids)
            )
        }
    }

    // MARK: - 占用与清理

    public struct Usage: Sendable, Equatable {
        public let count: Int
        public let imageCount: Int
        public let bytes: Int
        public let pinnedCount: Int
        /// 按 kind 拆开的字节数，设置页要分「文字 / 图片 / 文件」显示
        public let kindBytes: [Int: Int]

        public init(count: Int, imageCount: Int, bytes: Int, pinnedCount: Int,
                    kindBytes: [Int: Int] = [:]) {
            self.count = count
            self.imageCount = imageCount
            self.bytes = bytes
            self.pinnedCount = pinnedCount
            self.kindBytes = kindBytes
        }
    }

    public func usage() throws -> Usage {
        try db.dbQueue.read { conn in
            let count = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? 0
            let images = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item WHERE kind = ?",
                                          arguments: [ClipKind.image.rawValue]) ?? 0
            let bytes = try Int.fetchOne(conn, sql: "SELECT COALESCE(SUM(byteSize), 0) FROM item") ?? 0
            let pinned = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM pin_instance") ?? 0
            var byKind: [Int: Int] = [:]
            let rows = try Row.fetchAll(conn, sql: """
                SELECT kind, COALESCE(SUM(byteSize), 0) AS bytes FROM item GROUP BY kind
                """)
            for row in rows {
                byKind[row["kind"]] = row["bytes"]
            }
            return Usage(count: count, imageCount: images, bytes: bytes, pinnedCount: pinned, kindBytes: byKind)
        }
    }

    /// 删掉「最后使用时间」早于 `days` 天前的记录。钉住的永远不动——贴图还挂在屏幕上。
    @discardableResult
    public func deleteOlderThan(days: Int, now: Double = Date().timeIntervalSince1970) throws -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now - Double(days) * 86_400
        return try deleteUnpinned(condition: "COALESCE(lastUsedAt, createdAt) < ?",
                                  arguments: [cutoff])
    }

    /// 清空历史，但保留钉住的条目。
    @discardableResult
    public func deleteAllUnpinned() throws -> Int {
        try deleteUnpinned(condition: nil, arguments: [])
    }

    private func deleteUnpinned(condition: String?,
                                arguments: StatementArguments) throws -> Int {
        let deleted = try db.dbQueue.write { conn -> Int in
            let filter = condition.map { "\($0) AND " } ?? ""
            let doomed = try String.fetchAll(conn, sql: """
                SELECT id FROM item
                WHERE \(filter)id NOT IN (SELECT itemID FROM pin_instance)
                """, arguments: arguments)
            guard !doomed.isEmpty else { return 0 }
            try Self.delete(conn, ids: doomed)
            return doomed.count
        }
        // 批量删完再统一扫一次 blob 目录，别每删一条扫一次
        try db.collectOrphanBlobs()
        return deleted
    }

    public func blobURL(forRelativePath path: String) -> URL {
        db.blobURL(forRelativePath: path)
    }

    /// 钉一次。同一 item 可以钉多处，所以是 (item, instance) 一对多。
    @discardableResult
    public func pin(
        itemID: String,
        frame: CGRect,
        screenUUID: String? = nil,
        now: Double = Date().timeIntervalSince1970
    ) throws -> String {
        let id = UUID().uuidString
        let json = """
            {"x":\(frame.origin.x),"y":\(frame.origin.y),"w":\(frame.width),"h":\(frame.height)}
            """
        try db.dbQueue.write { conn in
            let zOrder = try Int.fetchOne(conn, sql: "SELECT COALESCE(MAX(zOrder), 0) + 1 FROM pin_instance") ?? 1
            try conn.execute(sql: """
                INSERT INTO pin_instance (id, itemID, frame, screenUUID, zOrder, opacity, createdAt)
                VALUES (?, ?, ?, ?, ?, 1.0, ?)
                """, arguments: [id, itemID, json, screenUUID, zOrder, now])
        }
        return id
    }

    /// 删除后重建索引，用于修复或首次启用 FTS。
    public func rebuildSearchIndex() throws {
        try db.dbQueue.write { conn in
            try conn.execute(sql: "DELETE FROM item_fts")
            let rows = try Row.fetchAll(conn, sql: "SELECT rowid, text FROM item WHERE text IS NOT NULL AND text <> ''")
            for row in rows {
                try conn.execute(
                    sql: "INSERT INTO item_fts(rowid, text) VALUES (?, ?)",
                    arguments: [row["rowid"] as Int64, row["text"] as String]
                )
            }
        }
    }
}

private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: max(count, 1)).joined(separator: ",")
}

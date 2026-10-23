import CoreGraphics
import Foundation
import GRDB

public enum ClipKind: Int, Sendable {
    case text = 1
    case image = 2
    case file = 3
    case color = 4
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
public struct ClipDraft: Sendable {
    public var kind: ClipKind
    public var contentHash: String
    public var text: String?
    public var pngData: Data?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var byteSize: Int
    public var sourceApp: String?
    public var meta: String?

    public init(
        kind: ClipKind,
        contentHash: String,
        text: String? = nil,
        pngData: Data? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        byteSize: Int = 0,
        sourceApp: String? = nil,
        meta: String? = nil
    ) {
        self.kind = kind
        self.contentHash = contentHash
        self.text = text
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteSize = byteSize
        self.sourceApp = sourceApp
        self.meta = meta
    }
}

public struct ClipInsertResult: Sendable {
    public let item: ClipItem
    /// 已存在同内容，只把时间提到了最前
    public let deduplicated: Bool
}

public final class ClipboardStore: Sendable {
    private let db: BatonDatabase
    public let maxItems: Int

    public init(directory: URL? = nil, maxItems: Int = 800) throws {
        self.db = try BatonDatabase(directory: directory)
        self.maxItems = maxItems
    }

    /// 与其他 store 共用同一条数据库连接（贴图要往同一个库里写 item）。
    public init(database: BatonDatabase, maxItems: Int = 800) {
        self.db = database
        self.maxItems = maxItems
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

            var blobPath: String?
            if let png = draft.pngData {
                blobPath = try db.writeBlob(png, hash: draft.contentHash)
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
            try Self.indexFTS(conn, rowid: conn.lastInsertedRowID, text: item.text)
            return ClipInsertResult(item: item, deduplicated: false)
        }
    }

    private static func indexFTS(_ db: Database, rowid: Int64, text: String?) throws {
        guard let text, !text.isEmpty else { return }
        try db.execute(sql: "INSERT INTO item_fts(rowid, text) VALUES (?, ?)", arguments: [rowid, text])
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

    /// ≥3 字符走 FTS5 trigram，<3 字符（中文两字词）降级 LIKE。
    public func search(_ keyword: String, limit: Int = 200) throws -> [ClipItem] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try recent(limit: limit) }

        if trimmed.count >= 3 {
            let matches = try db.dbQueue.read { conn in
                try ClipItem.fetchAll(
                    conn,
                    sql: """
                        SELECT \(Self.columns) FROM item
                        WHERE rowid IN (SELECT rowid FROM item_fts WHERE item_fts MATCH ?)
                        ORDER BY COALESCE(lastUsedAt, createdAt) DESC
                        LIMIT ?
                        """,
                    arguments: [Self.ftsPhrase(trimmed), limit]
                )
            }
            if !matches.isEmpty { return matches }
        }
        return try likeSearch(trimmed, limit: limit)
    }

    private func likeSearch(_ keyword: String, limit: Int) throws -> [ClipItem] {
        let escaped = keyword
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try db.dbQueue.read { conn in
            try ClipItem.fetchAll(
                conn,
                sql: """
                    SELECT \(Self.columns) FROM item
                    WHERE text LIKE ? ESCAPE '\\'
                    ORDER BY COALESCE(lastUsedAt, createdAt) DESC
                    LIMIT ?
                    """,
                arguments: ["%\(escaped)%", limit]
            )
        }
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
            let rowid = try Int64.fetchOne(conn, sql: "SELECT rowid FROM item WHERE id = ?", arguments: [id])
            try conn.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [id])
            if let rowid {
                try conn.execute(sql: "DELETE FROM item_fts WHERE rowid = ?", arguments: [rowid])
            }
        }
        try db.collectOrphanBlobs()
    }

    /// 按条数裁剪，但被钉住的 item 不能删（pin_instance 有外键，硬删会失败或带走贴图）。
    @discardableResult
    public func trim() throws -> Int {
        try db.dbQueue.write { conn in
            let total = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? 0
            let overflow = total - maxItems
            guard overflow > 0 else { return 0 }

            let doomed = try String.fetchAll(conn, sql: """
                SELECT id FROM item
                WHERE id NOT IN (SELECT itemID FROM pin_instance)
                ORDER BY COALESCE(lastUsedAt, createdAt) ASC
                LIMIT ?
                """, arguments: [overflow])
            guard !doomed.isEmpty else { return 0 }

            let rowids = try Int64.fetchAll(conn, sql: """
                SELECT rowid FROM item WHERE id IN (\(databaseQuestionMarks(count: doomed.count)))
                """, arguments: StatementArguments(doomed))
            try conn.execute(
                sql: "DELETE FROM item WHERE id IN (\(databaseQuestionMarks(count: doomed.count)))",
                arguments: StatementArguments(doomed)
            )
            try conn.execute(
                sql: "DELETE FROM item_fts WHERE rowid IN (\(databaseQuestionMarks(count: rowids.count)))",
                arguments: StatementArguments(rowids)
            )
            return doomed.count
        }
        // 注意：trim 不在这里做 blob GC，调用方在批量结束后统一 GC，避免每删一条扫一次目录
    }

    public func collectOrphanBlobs() throws -> Int {
        try db.collectOrphanBlobs()
    }

    // MARK: - 占用与清理

    public struct Usage: Sendable, Equatable {
        public let count: Int
        public let imageCount: Int
        public let bytes: Int
        public let pinnedCount: Int

        public init(count: Int, imageCount: Int, bytes: Int, pinnedCount: Int) {
            self.count = count
            self.imageCount = imageCount
            self.bytes = bytes
            self.pinnedCount = pinnedCount
        }
    }

    public func usage() throws -> Usage {
        try db.dbQueue.read { conn in
            let count = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? 0
            let images = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item WHERE kind = ?",
                                          arguments: [ClipKind.image.rawValue]) ?? 0
            let bytes = try Int.fetchOne(conn, sql: "SELECT COALESCE(SUM(byteSize), 0) FROM item") ?? 0
            let pinned = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM pin_instance") ?? 0
            return Usage(count: count, imageCount: images, bytes: bytes, pinnedCount: pinned)
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

            let rowids = try Int64.fetchAll(conn, sql: """
                SELECT rowid FROM item WHERE id IN (\(databaseQuestionMarks(count: doomed.count)))
                """, arguments: StatementArguments(doomed))
            try conn.execute(
                sql: "DELETE FROM item WHERE id IN (\(databaseQuestionMarks(count: doomed.count)))",
                arguments: StatementArguments(doomed)
            )
            if !rowids.isEmpty {
                try conn.execute(
                    sql: "DELETE FROM item_fts WHERE rowid IN (\(databaseQuestionMarks(count: rowids.count)))",
                    arguments: StatementArguments(rowids)
                )
            }
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

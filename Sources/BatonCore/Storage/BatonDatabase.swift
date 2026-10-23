import Foundation
import GRDB

/// 单库 + 内容寻址 blob 目录。
///
/// 布局：
/// ```
/// ~/Library/Application Support/Baton/
/// ├── baton.sqlite
/// └── blobs/<sha256>.png
/// ```
public final class BatonDatabase: Sendable {
    public let directory: URL
    public let blobDirectory: URL
    let dbQueue: DatabaseQueue

    /// - Parameter directory: 传 nil 用默认位置；测试可传临时目录。
    public init(directory: URL? = nil) throws {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            dir = base.appendingPathComponent("Baton", isDirectory: true)
        }

        self.directory = dir
        self.blobDirectory = dir.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)

        var config = Configuration()
        config.prepareDatabase { db in
            // WAL 让读写不互相阻塞；剪贴板写入与面板搜索会并发
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("baton.sqlite").path, configuration: config)

        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE item (
                  id            TEXT PRIMARY KEY,
                  kind          INTEGER NOT NULL,
                  createdAt     REAL NOT NULL,
                  lastUsedAt    REAL,
                  sourceApp     TEXT,
                  contentHash   TEXT NOT NULL,
                  text          TEXT,
                  blobPath      TEXT,
                  pixelWidth    INTEGER,
                  pixelHeight   INTEGER,
                  scale         REAL,
                  byteSize      INTEGER,
                  meta          TEXT
                )
                """)
            try db.execute(sql: "CREATE UNIQUE INDEX idx_item_hash ON item(contentHash)")
            try db.execute(sql: "CREATE INDEX idx_item_time ON item(createdAt DESC)")

            try db.execute(sql: """
                CREATE TABLE pin_instance (
                  id          TEXT PRIMARY KEY,
                  itemID      TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                  frame       TEXT NOT NULL,
                  screenUUID  TEXT,
                  zOrder      INTEGER NOT NULL DEFAULT 0,
                  opacity     REAL NOT NULL DEFAULT 1.0,
                  createdAt   REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_pin_item ON pin_instance(itemID)")

            try db.execute(sql: """
                CREATE TABLE translate_record (
                  id TEXT PRIMARY KEY,
                  createdAt REAL,
                  sourceText TEXT,
                  resultText TEXT,
                  fromLang TEXT,
                  toLang TEXT,
                  provider TEXT,
                  model TEXT,
                  sourceItemID TEXT
                )
                """)

            // trigram 只对 >= 3 字符有效；两字查询在 ClipboardStore 里降级为 LIKE
            try db.execute(sql: "CREATE VIRTUAL TABLE item_fts USING fts5(text, tokenize='trigram')")
        }

        return migrator
    }

    // MARK: - blob

    public func blobURL(forRelativePath path: String) -> URL {
        directory.appendingPathComponent(path)
    }

    public func writeBlob(_ data: Data, hash: String) throws -> String {
        let relative = "blobs/\(hash).png"
        let url = directory.appendingPathComponent(relative)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return relative
    }

    /// 孤儿回收：不做引用计数，直接删掉没有被任何 item 指向的文件。
    @discardableResult
    public func collectOrphanBlobs() throws -> Int {
        let referenced = try dbQueue.read { db in
            try String.fetchSet(db, sql: "SELECT blobPath FROM item WHERE blobPath IS NOT NULL")
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: blobDirectory,
            includingPropertiesForKeys: nil
        )
        var removed = 0
        for file in files where !referenced.contains("blobs/\(file.lastPathComponent)") {
            try FileManager.default.removeItem(at: file)
            removed += 1
        }
        return removed
    }
}

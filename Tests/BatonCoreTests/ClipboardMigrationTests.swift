import Foundation
import GRDB
import XCTest
@testable import BatonCore

/// 老库（只有 item 一张表、一条记录一种类型）升级到 v2 后，
/// 历史记录必须还能原样粘回去——迁移写错就是几百条记录变纯文本/图片丢失。
final class ClipboardMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testV1RowsAreBackfilledWithOriginalTypes() throws {
        try makeV1Database()

        let store = try ClipboardStore(directory: directory)

        let text = try store.contents(for: "text-item")
        XCTAssertEqual(text.map(\.type), [ClipType.string])
        XCTAssertEqual(text.first?.value.flatMap { String(data: $0, encoding: .utf8) }, "历史文本")

        let image = try store.contents(for: "image-item")
        XCTAssertEqual(image.map(\.type), ["public.png"])
        XCTAssertEqual(image.first?.blobPath, "blobs/abc.png")

        let files = try store.contents(for: "file-item")
        XCTAssertEqual(files.map(\.type), [ClipType.fileURL, ClipType.fileURL])
        XCTAssertEqual(files.count, 2, "多文件要拆成两条 file-url")

        // 迁移后写入仍然正常
        let result = try store.insert(ClipDraft(kind: .text, contentHash: "new",
                                                text: "新记录", byteSize: 3))
        XCTAssertEqual(try store.contents(for: result.item.id).map(\.type), [ClipType.string])
    }

    /// 用和线上完全一致的 v1 DDL 建库，这样 v2 迁移走的是真实路径。
    private func makeV1Database() throws {
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("baton.sqlite").path)

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
            try db.execute(sql: "CREATE VIRTUAL TABLE item_fts USING fts5(text, tokenize='trigram')")
        }
        try migrator.migrate(queue)

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO item (id, kind, createdAt, contentHash, text, byteSize)
                VALUES ('text-item', 1, 100, 'h1', '历史文本', 12)
                """)
            try db.execute(sql: """
                INSERT INTO item (id, kind, createdAt, contentHash, blobPath, pixelWidth, pixelHeight, byteSize)
                VALUES ('image-item', 2, 200, 'h2', 'blobs/abc.png', 10, 10, 100)
                """)
            try db.execute(sql: """
                INSERT INTO item (id, kind, createdAt, contentHash, text, meta, byteSize)
                VALUES ('file-item', 3, 300, 'h3', 'a.txt, b.txt', '/tmp/a.txt\n/tmp/b.txt', 20)
                """)
        }
        try queue.close()
    }
}

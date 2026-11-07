import Foundation
import GRDB
import XCTest
@testable import BatonCore

final class ClipboardStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore(maxItems: Int? = nil, maxBytes: Int? = nil) throws -> ClipboardStore {
        try ClipboardStore(directory: directory, maxItems: maxItems, maxBytes: maxBytes)
    }

    func testInsertAndDeduplicate() throws {
        let store = try makeStore()
        let draft = ClipDraft(kind: .text, contentHash: "h1", text: "hello", byteSize: 5)

        let first = try store.insert(draft, now: 100)
        XCTAssertFalse(first.deduplicated)

        let second = try store.insert(draft, now: 200)
        XCTAssertTrue(second.deduplicated)
        XCTAssertEqual(first.item.id, second.item.id)
        XCTAssertEqual(try store.recent().count, 1)
        XCTAssertEqual(try store.recent().first?.lastUsedAt, 200)
    }

    func testSearchUsesFTSForThreeCharacters() throws {
        let store = try makeStore()
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "a", text: "剪贴板历史", byteSize: 5))
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "b", text: "翻译结果", byteSize: 4))

        XCTAssertEqual(try store.search("剪贴板").count, 1)
        XCTAssertEqual(try store.search("历史").count, 1)
    }

    func testSearchFallsBackToLikeForTwoChineseCharacters() throws {
        let store = try makeStore()
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "a", text: "剪贴板历史", byteSize: 5))

        // trigram 对两字词零命中，必须降级 LIKE，否则「贴板」搜不到
        XCTAssertEqual(try store.search("贴板").map(\.text), ["剪贴板历史"])
    }

    func testSearchEscapesLikeWildcards() throws {
        let store = try makeStore()
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "a", text: "100% done", byteSize: 8))
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "b", text: "1000 done", byteSize: 8))

        XCTAssertEqual(try store.search("0%").count, 1)
    }

    func testTrimKeepsPinnedItems() throws {
        let store = try makeStore(maxItems: 2)
        let pinned = try store.insert(ClipDraft(kind: .text, contentHash: "p", text: "pinned", byteSize: 6), now: 1)
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "n1", text: "n1", byteSize: 2), now: 2)
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "n2", text: "n2", byteSize: 2), now: 3)
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "n3", text: "n3", byteSize: 2), now: 4)

        try store.pin(itemID: pinned.item.id, frame: CGRect(x: 0, y: 0, width: 100, height: 100), now: 10)
        let removed = try store.trim()
        XCTAssertEqual(removed, 2)

        let remaining = try store.recent().map(\.text)
        XCTAssertTrue(remaining.contains("pinned"), "被钉住的条目不能被裁剪删掉")
        XCTAssertEqual(remaining.count, 2)
    }

    func testImageBlobWrittenAndCollected() throws {
        let store = try makeStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let result = try store.insert(ClipDraft(
            kind: .image,
            contentHash: "imghash",
            text: "图片 10×10",
            pngData: png,
            pixelWidth: 10,
            pixelHeight: 10,
            byteSize: png.count
        ))

        let path = try XCTUnwrap(result.item.blobPath)
        let url = store.blobURL(forRelativePath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try store.delete(id: result.item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "删条目后孤儿 GC 应清掉 blob")
    }

    func testUsageCountsImagesAndBytes() throws {
        let store = try makeStore()
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "t", text: "hi", byteSize: 12))
        _ = try store.insert(ClipDraft(kind: .image, contentHash: "i", text: "图片",
                                       pngData: Data([0x89, 0x50]), pixelWidth: 1, pixelHeight: 1,
                                       byteSize: 88))

        let usage = try store.usage()
        XCTAssertEqual(usage.count, 2)
        XCTAssertEqual(usage.imageCount, 1)
        XCTAssertEqual(usage.bytes, 100)
        XCTAssertEqual(usage.pinnedCount, 0)
    }

    func testDeleteOlderThanKeepsRecentAndPinned() throws {
        let store = try makeStore()
        let day: Double = 86_400
        let pinned = try store.insert(ClipDraft(kind: .text, contentHash: "p", text: "pinned", byteSize: 6),
                                      now: 1_000 * day)
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "old", text: "old", byteSize: 3),
                             now: 1_000 * day)
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "new", text: "new", byteSize: 3),
                             now: 1_100 * day)
        try store.pin(itemID: pinned.item.id, frame: CGRect(x: 0, y: 0, width: 10, height: 10), now: 1_000 * day)

        // 以 1100 天为「现在」，删 30 天前的：只有 old 该走，pinned 留着
        let removed = try store.deleteOlderThan(days: 30, now: 1_100 * day)
        XCTAssertEqual(removed, 1)

        let remaining = Set(try store.recent().map(\.text))
        XCTAssertEqual(remaining, ["pinned", "new"])
        XCTAssertEqual(try store.usage().pinnedCount, 1)
    }

    func testDeleteAllUnpinnedKeepsPins() throws {
        let store = try makeStore()
        let pinned = try store.insert(ClipDraft(kind: .text, contentHash: "p", text: "pinned", byteSize: 6))
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "a", text: "a", byteSize: 1))
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "b", text: "b", byteSize: 1))
        try store.pin(itemID: pinned.item.id, frame: CGRect(x: 0, y: 0, width: 10, height: 10))

        XCTAssertEqual(try store.deleteAllUnpinned(), 2)
        XCTAssertEqual(try store.recent().map(\.text), ["pinned"])
        XCTAssertEqual(try store.deleteAllUnpinned(), 0, "只剩钉住的条目时不该再删")
    }

    /// 批量清理要顺带清掉 FTS 行，否则删掉的词还能被搜到。
    func testBulkDeleteRemovesSearchIndex() throws {
        let store = try makeStore()
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "a", text: "剪贴板历史", byteSize: 5),
                             now: 0)
        XCTAssertEqual(try store.search("剪贴板").count, 1)

        XCTAssertEqual(try store.deleteAllUnpinned(), 1)
        XCTAssertTrue(try store.search("剪贴板").isEmpty)
    }

    func testInsertKeepsEveryRepresentation() throws {
        let store = try makeStore()
        let contents = [
            ClipContent(type: ClipType.string, value: Data("加粗".utf8)),
            ClipContent(type: ClipType.html, value: Data("<b>加粗</b>".utf8)),
            ClipContent(type: ClipType.rtf, value: Data("{\\rtf1 加粗}".utf8)),
        ]
        let result = try store.insert(ClipDraft(kind: .text, contentHash: "rich", text: "加粗",
                                                byteSize: 12, contents: contents))

        let stored = try store.contents(for: result.item.id)
        XCTAssertEqual(stored.map(\.type), [ClipType.string, ClipType.html, ClipType.rtf],
                       "顺序也要保住，回写时按录入顺序还原")
        XCTAssertEqual(stored.first?.value, Data("加粗".utf8))
    }

    func testImageKeepsOriginalExtension() throws {
        let store = try makeStore()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let result = try store.insert(ClipDraft(
            kind: .image,
            contentHash: "jpghash",
            text: "图片 1×1",
            imageExt: "jpg",
            pixelWidth: 1,
            pixelHeight: 1,
            byteSize: jpeg.count,
            contents: [ClipContent(type: "public.jpeg", value: jpeg)]
        ))

        let path = try XCTUnwrap(result.item.blobPath)
        XCTAssertTrue(path.hasSuffix(".jpg"), "JPEG 不该被写成 .png")
        let stored = try store.contents(for: result.item.id)
        XCTAssertEqual(stored.first?.type, "public.jpeg")
        XCTAssertEqual(stored.first?.blobPath, path)
    }

    func testByteCapTrimsOldest() throws {
        let store = try makeStore(maxItems: 100, maxBytes: 100)
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "t1", text: "1", byteSize: 60), now: 1)
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "t2", text: "2", byteSize: 60), now: 2)
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "t3", text: "3", byteSize: 60), now: 3)

        XCTAssertEqual(try store.trim(), 2, "超出 100 字节要删到装得下")
        XCTAssertEqual(try store.recent().map(\.text), ["3"])
        XCTAssertLessThanOrEqual(try store.usage().bytes, 100)
    }

    func testSearchFiltersByKind() throws {
        let store = try makeStore()
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "t", text: "报告", byteSize: 6))
        _ = try store.insert(ClipDraft(kind: .image, contentHash: "i", text: "报告 图", byteSize: 6,
                                       contents: [ClipContent(type: "public.png",
                                                              value: Data([0x89, 0x50]))]))

        XCTAssertEqual(try store.search("报告").count, 2)
        XCTAssertEqual(try store.search("报告", kind: .image).map(\.kind), [ClipKind.image.rawValue])
        XCTAssertEqual(try store.search("", kind: .text).count, 1, "空关键词 + 筛选也要生效")
    }

    func testSearchHitsCarryHighlightRanges() throws {
        let store = try makeStore()
        _ = try store.insert(ClipDraft(kind: .text, contentHash: "a", text: "剪贴板 剪贴", byteSize: 10))

        let hits = try store.searchHits("剪贴")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.ranges.count, 2)
    }

    /// 带 contents 的条目必须把 FTS 行写在 item 自己的 rowid 上。
    /// 曾经在 item_content 插完之后才取 lastInsertedRowID，FTS 落到 content 的
    /// rowid，搜 "7474" 就查不到 "1237474"（被别的命中结果挡住了 LIKE 兜底）。
    func testFTSRowUsesItemRowID() throws {
        let store = try makeStore()
        let item = try store.insert(
            ClipDraft(kind: .text, contentHash: "fts-rowid", text: "1237474", byteSize: 7,
                      contents: [ClipContent(type: ClipType.string, value: Data("1237474".utf8))]),
            now: 100
        ).item

        let queue = try DatabaseQueue(path: directory.appendingPathComponent("baton.sqlite").path)
        let missing = try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM item i
                WHERE i.text IS NOT NULL AND i.text <> ''
                  AND NOT EXISTS (SELECT 1 FROM item_fts f WHERE f.rowid = i.rowid)
                """) ?? -1
        }
        XCTAssertEqual(missing, 0, "有文本的 item 都要有同 rowid 的 FTS 行")

        // 4 字符走 FTS 分支，必须直接命中，不能靠 LIKE 兜底
        XCTAssertEqual(try store.search("7474").map(\.id), [item.id])
    }
}

final class PasteboardSecretFilterTests: XCTestCase {
    func testConcealedAndTransientTypes() {
        XCTAssertTrue(PasteboardReader.isSecret(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(PasteboardReader.isSecret(types: ["org.nspasteboard.TransientType"]))
        XCTAssertTrue(PasteboardReader.isSecret(types: ["org.nspasteboard.AutoGeneratedType"]))
    }

    func testPasswordManagerTypes() {
        XCTAssertTrue(PasteboardReader.isSecret(types: ["com.agilebits.onepassword"]))
        XCTAssertTrue(PasteboardReader.isSecret(types: ["com.bitwarden.item"]))
    }

    func testNormalTextIsNotSecret() {
        XCTAssertFalse(PasteboardReader.isSecret(types: ["public.utf8-plain-text", "public.html"]))
    }

    func testFTSPhraseQuoting() {
        XCTAssertEqual(ClipboardStore.ftsPhrase("a\"b"), "\"a\"\"b\"")
    }
}

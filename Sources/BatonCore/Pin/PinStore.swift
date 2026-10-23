import CoreGraphics
import Foundation
import GRDB
import ImageIO

public struct PinRecord: Sendable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pin_instance"

    public var id: String
    public var itemID: String
    /// CGRect 的 JSON。存 Cocoa 屏幕坐标（左下原点），恢复时能直接拿来 setFrame。
    public var frame: String
    public var screenUUID: String?
    public var zOrder: Int
    public var opacity: Double
    public var createdAt: Double
}

public struct StoredPin: Sendable {
    public let id: String
    /// 位图来源：显示按窗口像素取，导出才回原图。
    public let source: PinImageSource
    /// 原图倍率；窗口尺寸 = 像素 ÷ 这个值
    public let scale: CGFloat
    public let frame: CGRect
    public let opacity: Double

    /// 原图，按需从 blob 解码。
    public var image: CGImage? { source.full() }
}

/// 贴图落库：一张图一个 `item`，每钉一次一条 `pin_instance`。
///
/// 同一张图钉两处 → 两条 pin_instance 指向同一条 item，blob 只有一份。
/// `ClipboardStore.trim()` 已经排除被 pin 引用的 item，历史裁剪不会误删贴在屏幕上的图。
public final class PinStore: Sendable {
    private let clipboard: ClipboardStore
    private let db: BatonDatabase

    public init(clipboard: ClipboardStore) {
        self.clipboard = clipboard
        self.db = clipboard.database
    }

    @discardableResult
    public func save(image: CGImage, scale: CGFloat, frame: CGRect,
                     screenUUID: String?, opacity: Double = 1) throws -> String {
        guard let png = Self.pngData(image) else { throw PinStoreError.encodeFailed }
        let hash = PasteboardReader.sha256(png)
        let draft = ClipDraft(kind: .image,
                              contentHash: hash,
                              text: "贴图 \(image.width)×\(image.height)",
                              pngData: png,
                              pixelWidth: image.width,
                              pixelHeight: image.height,
                              byteSize: png.count,
                              sourceApp: "Baton")
        let item = try clipboard.insert(draft).item

        // scale 记在 item 上：同一张图钉两次倍率必然相同
        try db.dbQueue.write { conn in
            try conn.execute(sql: "UPDATE item SET scale = ? WHERE id = ?",
                             arguments: [Double(scale), item.id])
        }

        let record = PinRecord(id: UUID().uuidString,
                               itemID: item.id,
                               frame: Self.encode(frame),
                               screenUUID: screenUUID,
                               zOrder: try nextZOrder(),
                               opacity: opacity,
                               createdAt: Date().timeIntervalSince1970)
        try db.dbQueue.write { conn in
            try record.insert(conn)
        }
        return record.id
    }

    public func updateFrame(id: String, frame: CGRect, screenUUID: String?) {
        try? db.dbQueue.write { conn in
            try conn.execute(sql: "UPDATE pin_instance SET frame = ?, screenUUID = ? WHERE id = ?",
                             arguments: [Self.encode(frame), screenUUID, id])
        }
    }

    public func updateOpacity(id: String, opacity: Double) {
        try? db.dbQueue.write { conn in
            try conn.execute(sql: "UPDATE pin_instance SET opacity = ? WHERE id = ?",
                             arguments: [opacity, id])
        }
    }

    /// 关闭贴图只删实例，item 与 blob 留着给剪贴板历史和孤儿回收处理。
    public func delete(id: String) {
        try? db.dbQueue.write { conn in
            try conn.execute(sql: "DELETE FROM pin_instance WHERE id = ?", arguments: [id])
        }
    }

    public func loadAll() -> [StoredPin] {
        (try? db.dbQueue.read { conn -> [StoredPin] in
            let records = try PinRecord.fetchAll(conn, sql: "SELECT * FROM pin_instance ORDER BY zOrder")
            var pins: [StoredPin] = []
            for record in records {
                guard let item = try ClipItem.fetchOne(conn,
                                                       sql: "SELECT * FROM item WHERE id = ?",
                                                       arguments: [record.itemID]),
                      let blobPath = item.blobPath,
                      let frame = Self.decode(record.frame),
                      let width = item.pixelWidth,
                      let height = item.pixelHeight else { continue }
                // 这里不再解码位图：一张 2880×1800 的图 19.8 MB，贴图多开几张就撑爆。
                // 显示时按窗口像素子采样解码，导出时才取原图。
                let url = db.blobURL(forRelativePath: blobPath)
                pins.append(StoredPin(id: record.id,
                                      source: PinImageSource(pixelSize: CGSize(width: width, height: height),
                                                             fileURL: url),
                                      scale: max(CGFloat(item.scale ?? 1), 1),
                                      frame: frame,
                                      opacity: record.opacity))
            }
            return pins
        }) ?? []
    }

    private func nextZOrder() throws -> Int {
        try db.dbQueue.read { conn in
            (try Int.fetchOne(conn, sql: "SELECT COALESCE(MAX(zOrder), 0) + 1 FROM pin_instance")) ?? 1
        }
    }

    // MARK: - 编解码

    static func encode(_ rect: CGRect) -> String {
        guard let data = try? JSONEncoder().encode(rect) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ string: String) -> CGRect? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CGRect.self, from: data)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

public enum PinStoreError: Error, Sendable {
    case encodeFailed
}

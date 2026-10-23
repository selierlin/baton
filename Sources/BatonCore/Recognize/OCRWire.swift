import CoreGraphics
import Foundation

/// OCR 子进程的 wire 规格（照 Bob 的 JSONL over stdin/stdout）。
///
/// 一行一个 JSON 对象，请求与响应都带 `id`；图片走 **PNG 的 base64**，
/// 不传裸位图——2880×1800 的位图 20 MB，跨进程拷一次就把子进程省下的内存吃回去了。
public struct OCRWireRequest: Codable, Sendable, Equatable {
    public let id: String
    /// `hello` 握手 / `ocr` 识别
    public let kind: String
    public let bytes: String?
    public let languages: [String]
    public let autoDetect: Bool

    public init(id: String, kind: String, bytes: String? = nil,
                languages: [String], autoDetect: Bool = false) {
        self.id = id
        self.kind = kind
        self.bytes = bytes
        self.languages = languages
        self.autoDetect = autoDetect
    }

    public static func hello(id: String) -> OCRWireRequest {
        OCRWireRequest(id: id, kind: "hello", languages: [], autoDetect: false)
    }

    public static func ocr(id: String, pngBase64: String, languages: [String]) -> OCRWireRequest {
        OCRWireRequest(id: id, kind: "ocr", bytes: pngBase64,
                       languages: languages, autoDetect: false)
    }
}

public struct OCRWirePoint: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct OCRWireLine: Codable, Sendable, Equatable {
    public let text: String
    public let points: [OCRWirePoint]

    public init(text: String, points: [OCRWirePoint]) {
        self.text = text
        self.points = points
    }

    public init(_ line: OCRLine) {
        self.text = line.text
        self.points = line.points.map { OCRWirePoint(x: Double($0.x), y: Double($0.y)) }
    }

    /// 坐标约定不变：相对原图左上角的像素，顺序 左上 → 右上 → 右下 → 左下。
    public var ocrLine: OCRLine {
        OCRLine(text: text, points: points.map { CGPoint(x: $0.x, y: $0.y) })
    }
}

public struct OCRWireResponse: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let ms: Int?
    public let count: Int?
    public let lines: [OCRWireLine]?
    public let error: String?

    public init(id: String, kind: String, ms: Int? = nil,
                lines: [OCRWireLine]? = nil, error: String? = nil) {
        self.id = id
        self.kind = kind
        self.ms = ms
        self.count = lines?.count
        self.lines = lines
        self.error = error
    }

    public var ocrLines: [OCRLine] {
        (lines ?? []).map(\.ocrLine)
    }
}

/// JSONL 编解码。子进程与父进程共用，避免两边各自拼字符串拼错字段名。
public enum OCRWire {
    /// 每次新建：`JSONEncoder` 不是线程安全的，而这里会被两个进程、多条队列同时用到。
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

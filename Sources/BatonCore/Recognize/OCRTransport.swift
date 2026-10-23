import CoreGraphics
import Foundation

/// 一行识别结果。
///
/// `points` 是**相对原图左上角的像素坐标**，顺序为 左上 → 右上 → 右下 → 左下。
/// Vision 给的是 normalized + 左下原点，换算在 transport 内部完成，
/// 上层只按左上原点画框——这个约定错一次就会全篇偏移。
public struct OCRLine: Sendable, Equatable {
    public let text: String
    public let points: [CGPoint]

    public init(text: String, points: [CGPoint]) {
        self.text = text
        self.points = points
    }

    /// 用左上角 + 宽高构造，省掉手写四个点。
    public init(text: String, rect: CGRect) {
        self.init(text: text, points: [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ])
    }

    public var boundingRect: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 图标、分隔线、单个标点被识别成「文字」时产生的噪音行。
    ///
    /// 判据是**有没有文字内容**，而不是长度：只要不含任何字母/数字/汉字就丢掉。
    /// 这样 `)`、`+`、`...`、`———` 都会被清掉，而 `用`、`13`、`OK` 会留下。
    /// 长度不能作为主要判据——`...` 有 3 个字符却毫无内容，`好` 只有 1 个字却是正文。
    public static func isNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let letters = trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        // 完全没有文字内容：`)`、`...`、`———`
        if letters.isEmpty { return true }
        // 一个字母数字 + 符号，基本是被当成文字的图标：`#K`、`·A`。
        // 单个汉字（`用`）不含符号，不会被这条命中。
        if trimmed.count <= 2, letters.count <= 1, letters.count < trimmed.count {
            return true
        }
        return false
    }

    /// 按「行」重排：纵向聚类（容差取行高的一半），行内从左到右。
    ///
    /// 各家的返回顺序都不可靠：Vision 不保证阅读顺序，百度按检测框顺序返回，
    /// 所以统一在这里排一次，上层不用关心来源。
    ///
    /// 只要有一项缺坐标就**整体保持原顺序**——按 `minY=0` 排会把所有无坐标的行全挤到最前面，
    /// 比不排更糟。百度的 `*_basic` 接口就是这种情况（只给文字不给位置）。
    public static func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        guard lines.count > 1, lines.allSatisfy({ !$0.points.isEmpty }) else { return lines }
        let sorted = lines.sorted { $0.boundingRect.minY < $1.boundingRect.minY }

        var rows: [[OCRLine]] = []
        for line in sorted {
            let rect = line.boundingRect
            if var row = rows.last, let reference = row.first?.boundingRect {
                let tolerance = max(6, min(reference.height, rect.height) * 0.5)
                if abs(rect.minY - reference.minY) <= tolerance {
                    row.append(line)
                    rows[rows.count - 1] = row
                    continue
                }
            }
            rows.append([line])
        }
        return rows.flatMap { $0.sorted { $0.boundingRect.minX < $1.boundingRect.minX } }
    }
}

public struct OCRRequest: @unchecked Sendable {
    /// `CGImage` 是不可变 CF 对象，跨线程只读安全，因此不受 `Sendable` 检查约束。
    public let image: CGImage
    public let languages: [String]

    public init(image: CGImage, languages: [String] = VisionOCRTransport.defaultLanguages) {
        self.image = image
        self.languages = languages
    }
}

public struct OCRResult: Sendable, Equatable {
    public let lines: [OCRLine]
    public let milliseconds: Int

    /// 默认过滤噪音行（`OCRLine.isNoise`）。高精度接口会把 UI 图标识别成 `)`、`#K` 之类，
    /// 这些进了译文只会添乱。需要拿原始结果的场合（比如逐框调试）传 `filterNoise: false`。
    public init(lines: [OCRLine], milliseconds: Int, filterNoise: Bool = true) {
        self.lines = filterNoise ? lines.filter { !OCRLine.isNoise($0.text) } : lines
        self.milliseconds = milliseconds
    }

    /// 按阅读顺序拼接的纯文本，直接可写剪贴板。
    public var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    public var isEmpty: Bool { lines.allSatisfy { $0.text.isEmpty } }
}

public enum OCRError: Error, Sendable {
    case emptyImage
    case requestFailed(String)
    case missingCredential(account: String)
    case service(code: Int, message: String)
    case cancelled
}

extension OCRError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyImage:
            return "图片为空"
        case .requestFailed(let message):
            return message
        case .missingCredential(let account):
            return "未配置百度 OCR 凭据（Keychain 条目 \(account)）"
        case .service(let code, let message):
            return "\(message)（\(code)）"
        case .cancelled:
            return "已取消"
        }
    }
}

/// OCR 的唯一入口。P4 用进程内 Vision，P7 换成子进程只替换实现，调用方不动。
public protocol OCRTransport: Sendable {
    func recognize(_ request: OCRRequest) async throws -> OCRResult
}

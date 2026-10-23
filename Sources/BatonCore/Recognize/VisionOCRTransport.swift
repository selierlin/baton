import CoreGraphics
import Foundation
import Vision

/// 进程内 Vision 实现。
///
/// 实测成本：1600×900 中英混排 237 ms / +30.3 MB，且 60 s 后只回落 0.1 MB。
/// P4 先用这个跑通链路，P7 换成子进程实现（同样是 `OCRTransport`，调用方不改）。
public struct VisionOCRTransport: OCRTransport {
    /// 固定列表，不开自动检测：本机实测 `automaticallyDetectsLanguage` 会把混合行判错语种，
    /// 首行直接出乱码；而 `["en-US"]` 单独用会让中文全变乱码。
    public static let defaultLanguages = ["zh-Hans", "en-US", "ja-JP"]

    private let queue: DispatchQueue

    public init(qos: DispatchQoS = .userInitiated) {
        self.queue = DispatchQueue(label: "com.selier.baton.ocr", qos: qos)
    }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        let started = CFAbsoluteTimeGetCurrent()
        let image = request.image
        let languages = request.languages.isEmpty ? Self.defaultLanguages : request.languages

        let lines = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[OCRLine], Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try Self.recognize(image, languages: languages))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return OCRResult(lines: lines,
                         milliseconds: Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
    }

    // MARK: - 同步识别

    private static func recognize(_ image: CGImage, languages: [String]) throws -> [OCRLine] {
        guard image.width > 0, image.height > 0 else { throw OCRError.emptyImage }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCRError.requestFailed(error.localizedDescription)
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var lines: [OCRLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            guard !text.isEmpty else { continue }

            // Vision: normalized，原点在左下；上层约定：像素，原点在左上。
            let box = observation.boundingBox
            let left = box.minX * width
            let right = box.maxX * width
            let top = (1 - box.maxY) * height
            let bottom = (1 - box.minY) * height
            lines.append(OCRLine(text: text, points: [
                CGPoint(x: left, y: top),
                CGPoint(x: right, y: top),
                CGPoint(x: right, y: bottom),
                CGPoint(x: left, y: bottom),
            ]))
        }
        return readingOrder(lines)
    }

    /// Vision 不保证返回顺序等于阅读顺序，按「行」重新排：
    /// 纵向聚类（容差取行高的一半），行内从左到右。
    static func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        OCRLine.readingOrder(lines)
    }
}

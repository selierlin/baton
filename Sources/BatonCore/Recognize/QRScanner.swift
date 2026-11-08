import CoreGraphics
import Foundation
import Vision

/// 图里识别出的一个二维码。
///
/// 坐标口径与 `OCRLine` 完全一致：相对原图左上角的像素，顺序 左上 → 右上 → 右下 → 左下。
/// 两个框画在同一张画布上，口径差一点就会出现「文字框对得上、二维码框偏一半」。
public struct QRCode: Sendable, Equatable {
    public let payload: String
    public let points: [CGPoint]

    public init(payload: String, points: [CGPoint]) {
        self.payload = payload
        self.points = points
    }

    public init(payload: String, rect: CGRect) {
        self.init(payload: payload, points: [
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
}

/// 图里的二维码。
///
/// 只认 QR：Bob 也只认这个——条形码、Aztec、DataMatrix 实测都不会标框，
/// 混进来会让「识别到二维码」这块区域的语义说不清。检测失败一律返回空数组，
/// 二维码只是 OCR 的附赠信息，不能因为它把整条识别链路带崩。
public enum QRScanner {
    private static let queue = DispatchQueue(label: "com.selier.baton.qr", qos: .userInitiated)

    public static func scan(_ image: CGImage) async -> [QRCode] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: detect(image))
            }
        }
    }

    /// 同步版：调用方已经在后台队列里时直接用，省一次跳线程。
    public static func detect(_ image: CGImage) -> [QRCode] {
        guard image.width > 0, image.height > 0 else { return [] }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var codes: [QRCode] = []
        var seen: Set<String> = []
        for observation in request.results ?? [] {
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { continue }

            // Vision: normalized，原点在左下；上层约定：像素，原点在左上。
            let corners = [observation.topLeft, observation.topRight,
                           observation.bottomRight, observation.bottomLeft]
            let points = corners.map { point in
                CGPoint(x: point.x * width, y: (1 - point.y) * height)
            }
            let code = QRCode(payload: payload, points: points)
            // 同一张码有时会被重复报两次，按「内容 + 取整后的位置」去重
            let box = code.boundingRect
            let key = "\(payload)@\(Int(box.minX / 4)),\(Int(box.minY / 4))"
            guard seen.insert(key).inserted else { continue }
            codes.append(code)
        }
        return readingOrder(codes)
    }

    /// Vision 不保证顺序。按「行」排一次，跟文字识别用同一套规则：
    /// 纵向聚类（容差取框高的一半），行内从左到右——否则多张码的列表顺序是随机的。
    static func readingOrder(_ codes: [QRCode]) -> [QRCode] {
        guard codes.count > 1 else { return codes }
        let sorted = codes.sorted { $0.boundingRect.minY < $1.boundingRect.minY }

        var rows: [[QRCode]] = []
        for code in sorted {
            let rect = code.boundingRect
            if var row = rows.last, let reference = row.first?.boundingRect {
                let tolerance = max(8, min(reference.height, rect.height) * 0.5)
                if abs(rect.minY - reference.minY) <= tolerance {
                    row.append(code)
                    rows[rows.count - 1] = row
                    continue
                }
            }
            rows.append([code])
        }
        return rows.flatMap { $0.sorted { $0.boundingRect.minX < $1.boundingRect.minX } }
    }
}

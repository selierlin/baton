import CoreGraphics
import Foundation

/// 尺子拖完框之后的「吸附边缘」：把选区的四条边各自贴到附近对比最强的像素边界上。
///
/// 做法是把选区四周各扩 `tolerance` 像素取一张小图，按列/行算「隔一格的两列
/// 颜色差」，差最大的那一列就是边界；不足 `minimumStrength` 就不动，免得在
/// 纯色块上乱跳。全是纯函数，单测里用合成图就能验，不用真开屏幕。
public enum RulerSnap {
    public struct Options: Sendable {
        /// 每条边最多挪多少像素
        public var tolerance: Int
        /// 吸附门槛：相邻两列的平均通道差，0–255
        public var minimumStrength: Double
        /// 选区比这更小就不吸附（放大到 1px 的框没有「边缘」可言）
        public var minimumLength: Int

        public init(tolerance: Int = 6, minimumStrength: Double = 16, minimumLength: Int = 8) {
            self.tolerance = tolerance
            self.minimumStrength = minimumStrength
            self.minimumLength = minimumLength
        }

        public static let standard = Options()
    }

    /// 把像素矩形往最近的强边界推。换算不出更强边界的那条边保持原样。
    public static func snap(_ rect: CGRect, in image: CGImage, options: Options = .standard) -> CGRect {
        let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let base = rect.intersection(canvas).integral
        guard base.width >= CGFloat(options.minimumLength),
              base.height >= CGFloat(options.minimumLength) else { return rect }

        let pad = CGFloat(max(options.tolerance, 0))
        let band = base.insetBy(dx: -pad, dy: -pad).intersection(canvas).integral
        guard band.width >= 3, band.height >= 3,
              let sub = image.cropping(to: band),
              let buffer = Buffer(sub) else { return rect }

        var result = base

        // 每条边独立挪：先记成四个坐标，最后再拼回矩形，
        // 否则挪左边会带着右边一起动（宽高不变就变成「整体平移」了）。
        var (left, right) = (base.minX, base.maxX)
        var (top, bottom) = (base.minY, base.maxY)

        // 左右边：按行取样比较列
        let rows = Int(base.minY - band.minY)..<Int(base.maxY - band.minY)
        let columns = buffer.columnStrength(rows: rows)
        let leftTarget = Int(base.minX - band.minX)
        let rightTarget = Int(base.maxX - band.minX)

        if let x = best(in: columns, target: leftTarget, window: options.tolerance,
                        minimum: options.minimumStrength) {
            left = band.minX + CGFloat(x)
        }
        if let x = best(in: columns, target: rightTarget, window: options.tolerance,
                        minimum: options.minimumStrength,
                        lowerBound: Int(left - band.minX) + 2) {
            right = band.minX + CGFloat(x)
        }

        // 上下边：按列取样比较行
        let cols = Int(left - band.minX)..<Int(right - band.minX)
        let lines = buffer.rowStrength(columns: cols)
        let topTarget = Int(base.minY - band.minY)
        let bottomTarget = Int(base.maxY - band.minY)

        if let y = best(in: lines, target: topTarget, window: options.tolerance,
                        minimum: options.minimumStrength) {
            top = band.minY + CGFloat(y)
        }
        if let y = best(in: lines, target: bottomTarget, window: options.tolerance,
                        minimum: options.minimumStrength,
                        lowerBound: Int(top - band.minY) + 2) {
            bottom = band.minY + CGFloat(y)
        }

        // 两条边吸到一起会得到 0 宽/高的框：宁可整体退回原框
        guard right - left >= 1, bottom - top >= 1 else { return base }

        result = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        return result.integral
    }

    /// 在 `target ± window` 里挑强度最大的位置；不到门槛返回 nil。
    /// `lowerBound` 用来挡住对面那条边：底边不能吸到顶边上面去。
    static func best(in strength: [Double], target: Int, window: Int,
                     minimum: Double, lowerBound: Int = 1) -> Int? {
        guard !strength.isEmpty, window >= 0 else { return nil }
        let low = max(1, lowerBound, target - window)
        let high = min(strength.count - 2, target + window)
        guard low <= high else { return nil }

        var bestIndex = low
        var bestValue = -Double.infinity
        // 平局取后面那个：边界是「第一个变色像素」，右侧的索引才是矩形边
        for index in low...high where strength[index] >= bestValue {
            bestValue = strength[index]
            bestIndex = index
        }
        return bestValue >= minimum ? bestIndex : nil
    }
}

/// 一张 BGRA 位图。只在小条带上建，别拿整屏截图这么干。
struct Buffer {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: bitmapInfo) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// 每一列「左边一格 vs 右边一格」的平均通道差，索引 = 列号。
    func columnStrength(rows: Range<Int>) -> [Double] {
        var out = [Double](repeating: 0, count: width)
        let rows = rows.clamped(to: 1..<(height - 1))
        guard !rows.isEmpty else { return out }

        let step = max(1, rows.count / 256)
        var sampled = 0
        var sum = [Double](repeating: 0, count: width)

        var y = rows.lowerBound
        while y < rows.upperBound {
            let rowStart = y * width * 4
            var x = 1
            while x < width - 1 {
                let a = rowStart + (x - 1) * 4
                let b = rowStart + (x + 1) * 4
                var diff = 0
                for channel in 0..<3 {
                    diff += abs(Int(bytes[a + channel]) - Int(bytes[b + channel]))
                }
                sum[x] += Double(diff) / 3
                x += 1
            }
            sampled += 1
            y += step
        }

        guard sampled > 0 else { return out }
        for x in 1..<(width - 1) { out[x] = sum[x] / Double(sampled) }
        return out
    }

    /// 每一行「上一格 vs 下一格」的平均通道差，索引 = 行号。
    func rowStrength(columns: Range<Int>) -> [Double] {
        var out = [Double](repeating: 0, count: height)
        let columns = columns.clamped(to: 1..<(width - 1))
        guard !columns.isEmpty else { return out }

        let step = max(1, columns.count / 256)
        var sampled = 0
        var sum = [Double](repeating: 0, count: height)

        var y = 1
        while y < height - 1 {
            let above = (y - 1) * width * 4
            let below = (y + 1) * width * 4
            var x = columns.lowerBound
            while x < columns.upperBound {
                let a = above + x * 4
                let b = below + x * 4
                var diff = 0
                for channel in 0..<3 {
                    diff += abs(Int(bytes[a + channel]) - Int(bytes[b + channel]))
                }
                sum[y] += Double(diff) / 3
                x += step
            }
            sampled += 1
            y += 1
        }

        guard sampled > 0 else { return out }
        for y in 1..<(height - 1) { out[y] = sum[y] / Double(sampled) }
        return out
    }
}

private extension Range where Bound == Int {
    func clamped(to limits: Range<Int>) -> Range<Int> {
        let lower = Swift.max(lowerBound, limits.lowerBound)
        let upper = Swift.min(upperBound, limits.upperBound)
        return lower < upper ? lower..<upper : 0..<0
    }
}

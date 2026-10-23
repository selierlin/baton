import CoreGraphics
import Foundation

/// 灰度快照：长截图匹配只看结构，转灰度 + 降采样能把比较量压到 1/16。
public struct GrayFrame: Sendable {
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int

    public init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }
}

/// 纵向拼接的偏移估计。
///
/// 取上一帧底部 25% 作为模板，在当前帧里滑动匹配；搜索窗排除 `dy≈0`
/// 的吸附解（sticky header 会假装没滚动），再用 MAE 卡置信度。
/// 返回值 `offset` 已换算回原始像素。
public enum FrameStitcher {
    /// 降采样步长。2x 屏一帧约 2880px 宽，1/4 后 720px，单次匹配 3~5 万次比较。
    public static let sampleStep = 4

    public struct Match: Sendable, Equatable {
        /// 新帧相对上一帧向上滚过的像素数。
        public let offset: Int
        /// 重叠区平均绝对误差（0~255）。
        public let mae: Double
    }

    /// MAE 上限。超过就认为两帧对不上（切换标签页、弹层、加载动画）。
    public static let maeLimit: Double = 7

    /// 零位移时的 MAE 低于这个值，就算「画面没动」（滚动到位、页面静止）。
    public static let stationaryLimit: Double = 1.5

    /// 全重叠区 MAE 的绝对下限。真匹配的整区误差和模板误差是同一量级
    /// （实测 1px 亚像素位移在降采样后约 8），误配只有窄带对得上、
    /// 整区会大一个数量级，所以判据写成「≤ max(下限, 模板误差 × 3)」。
    public static let overlapFloor: Double = 12

    public static func grayscale(_ image: CGImage, step: Int = sampleStep) -> GrayFrame? {
        let width = image.width / step
        let height = image.height / step
        guard width > 8, height > 8 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return GrayFrame(pixels: pixels, width: width, height: height)
    }

    /// 页面往回滚了（内容往下走）。
    ///
    /// 判法：把两帧对调再匹配一次——「当前帧在上一帧上方」等价于「上一帧在当前帧下方」，
    /// 正好复用同一套唯一性与全重叠区校验，不用为反向再写一套。
    ///
    /// 为什么必须单独识别：往回滚时画面里是**已经截过**的内容，正常匹配找不到，
    /// 调用方若把它当「接不上」处理、跳过几帧后换基线，再往下滚就会重复追加已截的行
    /// ——实测「上下快速滚动后出现数字行交叉」。
    public static func isRewound(previous: GrayFrame, current: GrayFrame) -> Bool {
        return verticalOffset(previous: current, current: previous) != nil
    }

    public static func verticalOffset(previous: GrayFrame, current: GrayFrame) -> Match? {
        guard previous.width == current.width, previous.height == current.height else { return nil }
        let height = previous.height
        guard height >= 40 else { return nil }

        // 唯一的搜索窗：模板取上一帧底部 25%，最多找 0.75 屏。
        //
        // 这里刻意不再做「更小模板 + 更大搜索」的宽容兜底。
        // 兜底窗把重叠区压到 8% 之后，行距一致的文字、等高卡片随便就能在错位处
        // 凑出接近零的误差——正确率远低于收益，实测表现为「44 行之后冒出 35 行，
        // 再从 40 行接下去」。宁可判成接不上、留一个可见断点，也不出这种整段错位的图。
        //
        // 于是本项有一条明确的能力边界：**两次抓帧之间位移超过 0.75 屏即视为超速**，
        // 拼接器不会硬凑。超速的处理在 ScrollCaptureSession 里（留断点标记）。
        guard let primary = search(previous: previous, current: current,
                                   band: max(8, height / 4), maxDy: max(2, height * 3 / 4)) else {
            return nil
        }

        // 模板取的是底部内容区，不包含 sticky header：
        // 若原样对齐就已经几乎零误差，说明页面压根没动，别硬找一个伪偏移。
        if let zero = primary.scores.first(where: { $0.dy == 0 }),
           Double(zero.score) / Double(primary.sampleCount) < Self.stationaryLimit {
            return nil
        }
        return resolve(primary, previous: previous, current: current,
                       uniqueness: 0.85, limit: maeLimit)
    }

    /// 单帧最多能可靠拼接的位移，占一帧高度的比例。
    ///
    /// 与 `verticalOffset` 里的搜索窗保持一致：模板 1/4 高度，因此最大位移 3/4。
    /// 超出就属于「超速」，调用方应标记断点而不是继续硬拼。
    public static let maxReliableOffsetRatio: Double = 0.75

    /// 画面在原地没动（不是「滚太远接不上」）。
    ///
    /// 两种失败处理完全不同：没动就照旧等；接不上则要留着旧基线重试，
    /// 一旦换基线，中间那段内容就补不回来了。
    public static func isStationary(previous: GrayFrame, current: GrayFrame) -> Bool {
        guard previous.width == current.width, previous.height == current.height,
              previous.height >= 40,
              let search = search(previous: previous, current: current,
                                  band: max(8, previous.height / 4), maxDy: 0) else {
            return false
        }
        guard let zero = search.scores.first(where: { $0.dy == 0 }) else { return false }
        return Double(zero.score) / Double(search.sampleCount) < stationaryLimit
    }

    private struct Search {
        let scores: [(dy: Int, score: Int)]
        let sampleCount: Int
    }

    /// 在 `band` 大小的模板上滑 `maxDy` 行，返回每个位移的绝对差之和。
    private static func search(previous: GrayFrame, current: GrayFrame,
                               band: Int, maxDy: Int) -> Search? {
        let width = previous.width
        let height = previous.height
        guard band + maxDy <= height, band > 0 else { return nil }

        let rowStride = 2
        let colStride = 2
        let sampleRows = (band + rowStride - 1) / rowStride
        let sampleCols = (width + colStride - 1) / colStride
        let sampleCount = max(sampleRows * sampleCols, 1)

        // 模板必须自己有点纹理，纯色区域根本判不出滚没滚
        var mean = 0.0
        var square = 0.0
        var samples = 0
        for r in stride(from: height - band, to: height, by: rowStride) {
            for c in stride(from: 0, to: width, by: colStride) {
                let value = Double(previous.pixels[r * width + c])
                mean += value
                square += value * value
                samples += 1
            }
        }
        guard samples > 0 else { return nil }
        mean /= Double(samples)
        let variance = square / Double(samples) - mean * mean
        guard variance >= 4 else { return nil }

        var scores: [(dy: Int, score: Int)] = []
        scores.reserveCapacity(maxDy + 1)

        previous.pixels.withUnsafeBufferPointer { prev in
            current.pixels.withUnsafeBufferPointer { cur in
                for dy in 0...maxDy {
                    let start = height - band - dy
                    guard start >= 0 else { break }
                    var score = 0
                    var r = 0
                    while r < band {
                        let pRow = (height - band + r) * width
                        let cRow = (start + r) * width
                        var c = 0
                        while c < width {
                            score += abs(Int(prev[pRow + c]) - Int(cur[cRow + c]))
                            c += colStride
                        }
                        r += rowStride
                    }
                    scores.append((dy, score))
                }
            }
        }
        return Search(scores: scores, sampleCount: sampleCount)
    }

    /// 从打分里挑唯一谷底，再用整个重叠区复核一遍。
    private static func resolve(_ search: Search, previous: GrayFrame, current: GrayFrame,
                                uniqueness: Double, limit: Double) -> Match? {
        guard let best = search.scores.filter({ $0.dy > 0 }).min(by: { $0.score < $1.score }) else {
            return nil
        }

        // 谷底唯一性：只有「最佳明显优于次佳」才算真匹配，
        // 否则平滑渐变、重复行文这类画面会把 1~2 行误差当成滚动。
        if let rival = search.scores.filter({ abs($0.dy - best.dy) > 3 })
            .min(by: { $0.score < $1.score }),
           Double(best.score) > Double(rival.score) * uniqueness {
            return nil
        }

        let mae = Double(best.score) / Double(search.sampleCount)
        guard mae <= limit else { return nil }

        // 全重叠区复核：模板只是一条 8%~25% 的窄带，网页里行距一致的文字、
        // 等高的卡片、分隔线都能让窄带在错误位置上凑出接近零的误差——
        // 真接受下来就是「44 行之后冒出 35 行乱码，然后从 40 行接下去」。
        // 真匹配的整个重叠区都该对得上，误配只在那一小条上对得上。
        guard let overlap = overlapMAE(previous: previous, current: current, dy: best.dy),
              overlap <= max(overlapFloor, mae * 3) else {
            return nil
        }

        return Match(offset: best.dy * sampleStep, mae: mae)
    }

    /// `dy`（降采样行）位移下，上一帧与当前帧整个重叠区的平均绝对误差。
    ///
    /// 重叠区 = 上一帧第 `dy` 行到末尾 ↔ 当前帧第 0 行到 `height - dy`。
    /// 上下各留一点边：吸顶导航、固定底栏是「不动」的，它们出现在重叠区里
    /// 只会把正确匹配的误差拉高，正好把误配的判据搞钝。
    private static func overlapMAE(previous: GrayFrame, current: GrayFrame, dy: Int) -> Double? {
        let width = previous.width
        let height = previous.height
        let overlapRows = height - dy
        // 重叠区本来就窄（宽窗匹配只剩 8%）时，边距按重叠区比例收，别把整块削没
        let skipTop = min(max(2, height / 10), max(1, overlapRows / 4))
        let skipBottom = min(max(1, height / 20), max(1, overlapRows / 4))
        let from = dy + skipTop
        let to = height - skipBottom
        guard from + 4 <= to, overlapRows >= 6 else { return nil }

        var total = 0
        var count = 0
        previous.pixels.withUnsafeBufferPointer { prev in
            current.pixels.withUnsafeBufferPointer { cur in
                var r = from
                while r < to {
                    let pRow = r * width
                    let cRow = (r - dy) * width
                    var c = 0
                    while c < width {
                        total += abs(Int(prev[pRow + c]) - Int(cur[cRow + c]))
                        c += 2
                    }
                    count += (width + 1) / 2
                    r += 2
                }
            }
        }
        guard count > 0 else { return nil }
        return Double(total) / Double(count)
    }
}

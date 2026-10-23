import CoreGraphics
import CoreText
import Foundation

/// 长截图合成器：手动滚、停顿采样，一帧一帧往上接。
///
/// 只做纵向。每帧都拿「上一帧」比，不拿整张合成图比——页面可能已经被
/// 上一次拼接撑得比屏幕高很多，累计图的中段根本不在当前画面里。
@MainActor
public final class ScrollCaptureSession {
    public struct AppendResult: Sendable {
        public let advanced: Bool
        /// 本次前进的像素数
        public let offset: Int
        public let mae: Double
        public let totalHeight: Int
        /// 到达高度上限，调用方应停止采集
        public let reachedLimit: Bool
        /// 用户往回滚了：这一帧是已经截过的内容，不加高度，调用方也别算停手时间
        public let retreated: Bool
        /// 画面压根没动（不是匹配失败）。日志里要能区分「用户停手」和「接不上」
        public let stationary: Bool

        public init(advanced: Bool, offset: Int, mae: Double, totalHeight: Int,
                    reachedLimit: Bool, retreated: Bool = false, stationary: Bool = false) {
            self.advanced = advanced
            self.offset = offset
            self.mae = mae
            self.totalHeight = totalHeight
            self.reachedLimit = reachedLimit
            self.retreated = retreated
            self.stationary = stationary
        }
    }

    /// 12000 物理像素。2x 屏约 6000 逻辑高，位图约 138 MB。
    public static let maxHeight = 12000

    /// 连续多少帧接不上才认账换基线。换基线等于把中间那段永久丢掉。
    private static let missTolerance = 3
    /// 回滚状态下允许的「接不上」上限。过了就认为用户跳到了已截范围之外，只能换基线留缺口。
    private static let retreatMissTolerance = 8

    public private(set) var totalHeight: Int
    public private(set) var lastMatch: FrameStitcher.Match?
    /// 已经出现过「接不上、只能跳过」的区段：长图中段可能缺内容。
    public private(set) var hasGap = false
    /// 断点位置：距图片顶部的像素。
    ///
    /// 高速滚动时两帧之间可能真的什么都没拍到，这时**不能**假装接上。
    /// 与其输出一段错位内容（数字行交叉），不如在原图上留一条写明「此处缺失」的标记带，
    /// 用户一眼能看出哪里断过，需要完整内容就重截那一段。
    public private(set) var gapMarks: [Int] = []
    /// 用户滚回到已截范围内了，正在等画面重新往下走。
    ///
    /// 这时候基线必须钉在「已截到的最深处」，绝不能跟着回滚的帧跑：
    /// 基线一往回退，重新往下滚时追加的整条都是重复内容。
    public private(set) var isWaitingForForward = false

    private let width: Int
    private let context: CGContext
    private var lastGray: GrayFrame?
    private var misses = 0

    public init?(first frame: CGImage) {
        let width = frame.width
        guard width > 8, frame.height > 8,
              let context = CGContext(data: nil,
                                      width: width,
                                      height: Self.maxHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        self.width = width
        self.context = context
        self.totalHeight = frame.height
        self.lastGray = FrameStitcher.grayscale(frame)

        // 位图上下文是左下原点，而「第几行」说的是从顶部数：
        // 直接把第 0 行画在上下文顶部，不要翻转 CTM
        // （翻过一次之后 CGImage 会被二次翻转，长图就倒过来了）。
        context.draw(frame, in: CGRect(x: 0,
                                       y: CGFloat(Self.maxHeight - frame.height),
                                       width: CGFloat(width),
                                       height: CGFloat(frame.height)))
    }

    public func append(_ frame: CGImage) -> AppendResult {
        guard frame.width == width, totalHeight < Self.maxHeight else {
            return AppendResult(advanced: false, offset: 0, mae: .infinity,
                                totalHeight: totalHeight, reachedLimit: true)
        }

        guard let previous = lastGray,
              let gray = FrameStitcher.grayscale(frame) else {
            return AppendResult(advanced: false, offset: 0, mae: .infinity,
                                totalHeight: totalHeight, reachedLimit: false)
        }

        guard let match = FrameStitcher.verticalOffset(previous: previous, current: gray) else {
            // 往回滚：画面里是已经截过的内容。基线钉死不动，等它重新往下走——
            // 基线若跟着退，重新往下滚时追加的每条都是重复内容（「数字行交叉」）。
            if FrameStitcher.isRewound(previous: previous, current: gray) {
                isWaitingForForward = true
                misses = 0
                return AppendResult(advanced: false, offset: 0, mae: .infinity,
                                    totalHeight: totalHeight, reachedLimit: false,
                                    retreated: true)
            }
            // 没接上不等于画面换了：先留着旧基线重试几帧。
            // 滚动过快时一帧位移能超出搜索窗，但页面还在同一屏附近，
            // 立刻把基线挪到新帧上，中间那段就再也拼不回来了（实测「10 行直接跳到 17 行」）。
            if FrameStitcher.isStationary(previous: previous, current: gray) {
                misses = 0
                return AppendResult(advanced: false, offset: 0, mae: .infinity,
                                    totalHeight: totalHeight, reachedLimit: false,
                                    stationary: true)
            }
            misses += 1
            // 回滚状态下放宽容忍：用户可能一路翻回上面好几屏，这时候换基线最伤
            let tolerance = isWaitingForForward ? Self.retreatMissTolerance : Self.missTolerance
            guard misses >= tolerance else {
                return AppendResult(advanced: false, offset: 0, mae: .infinity,
                                    totalHeight: totalHeight, reachedLimit: false,
                                    retreated: isWaitingForForward)
            }
            // 连着几帧都接不上，只能认：换基线继续接。这个位置在最终图上会画一条断点标记，
            // 不假装接上了——用户看到的必须是「这里断了」，而不是错位的内容。
            lastGray = gray
            misses = 0
            isWaitingForForward = false
            hasGap = true
            gapMarks.append(totalHeight)
            return AppendResult(advanced: false, offset: 0, mae: .infinity,
                                totalHeight: totalHeight, reachedLimit: false)
        }
        // 只追加新露出来的那一条：当前帧底部 offset 行
        let dy = min(match.offset, frame.height, Self.maxHeight - totalHeight)
        guard dy > 0,
              let slice = frame.cropping(to: CGRect(x: 0, y: frame.height - dy,
                                                    width: width, height: dy)) else {
            return AppendResult(advanced: false, offset: 0, mae: match.mae,
                                totalHeight: totalHeight, reachedLimit: false)
        }

        context.draw(slice, in: CGRect(x: 0,
                                       y: CGFloat(Self.maxHeight - totalHeight - dy),
                                       width: CGFloat(width),
                                       height: CGFloat(dy)))
        totalHeight += dy
        lastGray = gray
        lastMatch = match
        misses = 0
        isWaitingForForward = false

        return AppendResult(advanced: true, offset: dy, mae: match.mae,
                            totalHeight: totalHeight,
                            reachedLimit: totalHeight >= Self.maxHeight)
    }

    /// 当前拼好的长图。`makeImage` 是快照语义，调用方可以安全持有。
    ///
    /// 有断点时在对应位置叠一条标记带，标记带**覆盖**缺口上方最后一点的画面：
    /// 那段内容本来就是不可信的，盖住比留着误导强。
    public func image() -> CGImage? {
        guard let full = context.makeImage() else { return nil }
        guard let cropped = full.cropping(to: CGRect(x: 0, y: 0,
                                                     width: width, height: totalHeight)) else {
            return full
        }
        guard !gapMarks.isEmpty else { return cropped }
        return Self.markGaps(in: cropped, marks: gapMarks, width: width, height: totalHeight)
    }

    /// 在断点处叠标记带。条高按图片宽度折算，保证 2x/1x 屏上视觉大小一致。
    private static func markGaps(in image: CGImage, marks: [Int], width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let bar = max(24, width / 50)
        let font = CTFontCreateWithName("PingFang SC" as CFString, CGFloat(bar) * 0.5, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(srgbRed: 0.24, green: 0.15, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "拼接断点 · 此处内容未被拍到，需要的话请重截这一段",
                               attributes: attributes) as CFAttributedString
        )

        for top in marks {
            // `top` 是从图片顶部数的像素；上下文是左下原点。
            // 条带要盖在断点**上方**紧邻的那一条内容上（那段本来就不完整），
            // 换算后条带的底边落在 `height - top` 处。
            let y = CGFloat(height - top)
            context.setFillColor(CGColor(srgbRed: 1, green: 0.78, blue: 0.12, alpha: 0.94))
            context.fill(CGRect(x: 0, y: y, width: CGFloat(width), height: CGFloat(bar)))
            context.textPosition = CGPoint(x: CGFloat(bar) * 0.5, y: y + CGFloat(bar) * 0.34)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }

    /// 预览缩略图：宽度压到 160pt 以内，按高度自适应。
    public func thumbnail() -> CGImage? {
        guard let image = image() else { return nil }
        let targetWidth = 160
        let ratio = CGFloat(targetWidth) / CGFloat(image.width)
        let height = max(1, Int(CGFloat(image.height) * ratio))
        guard let context = CGContext(data: nil,
                                      width: targetWidth,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: targetWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: height))
        return context.makeImage()
    }
}

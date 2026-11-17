import AppKit

/// 文字贴图的内容：一段纯文本 + 一套固定的「基准排版」。
///
/// 排版锚在基准字号 / 基准宽度上，窗口变大变小时整块等比放大（字号跟着走），
/// 换行位置不变——否则滚一下滚轮就重新折行，读起来是「字在跳」。
public struct PinTextContent: Sendable, Equatable {
    public let text: String

    /// 基准字号（pt）：窗口宽度等于 `baseWidth` 时就用这个字号。
    public static let baseFontSize: CGFloat = 13
    /// 基准宽度（pt，含内边距）。剪贴板里没有宽度信息，给一个读起来舒服的栏宽。
    public static let baseWidth: CGFloat = 320
    /// 内边距（pt，基准尺寸下）。
    public static let padding: CGFloat = 12
    /// 基准高度上限：粘进来一整篇文章时，别让贴图长到屏幕外。
    /// 超出部分画的时候截断，全文仍在库里，⌘C 复制回来是完整的。
    public static let maxBaseHeight: CGFloat = 640
    public static let cornerRadius: CGFloat = 10

    public init(text: String) {
        self.text = text
    }

    /// 基准尺寸（pt）：高度按真实排版量出来，再夹到上限。
    public var baseSize: CGSize {
        let measured = Self.measure(displayText, fontSize: Self.baseFontSize,
                                    width: Self.baseWidth - Self.padding * 2)
        let height = min(measured.height + Self.padding * 2, Self.maxBaseHeight)
        return CGSize(width: Self.baseWidth, height: max(height, 44))
    }

    /// 显示用的文本：超过高度上限时按基准排版裁掉尾巴、补省略号。
    ///
    /// 只影响「看」，`text` 始终是全文——⌘C 复制回去的还是完整的原文。
    /// 裁在字符边界上，不会把 emoji 或带修饰的字劈开。
    public var displayText: String {
        let limit = Self.maxBaseHeight - Self.padding * 2
        let width = Self.baseWidth - Self.padding * 2
        guard Self.measure(text, fontSize: Self.baseFontSize, width: width).height > limit else {
            return text
        }
        let characters = Array(text)
        var low = 0
        var high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = String(characters[0..<mid]) + "…"
            if Self.measure(candidate, fontSize: Self.baseFontSize, width: width).height <= limit {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return String(characters[0..<low]) + "…"
    }

    /// 空文本 / 纯空白不该钉出一张空卡。
    public var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 按给定字号排一遍，给绘制和量尺寸共用。
    ///
    /// 换行策略固定 `.byWordWrapping`：`.byTruncatingTail` 在整个字符串上会把内容压成
    /// 单行再截尾（量出来只有一行高），卡片里就只剩一行字。
    static func attributed(_ string: String, fontSize: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.18
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraph,
        ])
    }

    static func measure(_ string: String, fontSize: CGFloat, width: CGFloat) -> CGSize {
        let bounds = attributed(string, fontSize: fontSize)
            .boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }
}

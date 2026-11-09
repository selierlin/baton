import Foundation

/// 一份能搬走的配置：各模块的设置合成一个 JSON 文件。
///
/// 不导出的东西列在这里，免得以后被当成漏了：
/// - API Key：只存在钥匙串，配置里仅有 account 名，换台机器要重填
/// - 剪贴板历史 / 贴图 / 上一次截图：是数据不是配置
/// - 截图「上一次区域」：坐标跟显示器绑定，换机器没有意义
public struct ConfigBundle: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public struct Recording: Codable, Sendable, Equatable {
        public var capturesAudio: Bool
        public var capturesMicrophone: Bool

        public init(capturesAudio: Bool, capturesMicrophone: Bool) {
            self.capturesAudio = capturesAudio
            self.capturesMicrophone = capturesMicrophone
        }
    }

    public struct Clipboard: Codable, Sendable, Equatable {
        public var maxItems: Int
        public var maxBytes: Int
        public var ocrTitles: Bool

        public init(maxItems: Int, maxBytes: Int, ocrTitles: Bool) {
            self.maxItems = maxItems
            self.maxBytes = maxBytes
            self.ocrTitles = ocrTitles
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case newerVersion(found: Int)
        case empty
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .newerVersion(let found):
                return "这份配置来自更新的 Baton（格式 v\(found)），当前版本只认到 v\(ConfigBundle.currentVersion)。先升级 Baton。"
            case .empty:
                return "文件里没有任何可导入的配置。"
            case .unreadable:
                return "这不是 Baton 导出的配置文件，或者文件已经损坏。"
            }
        }
    }

    public var version: Int
    public var exportedAt: Date
    /// 导出时的 App 版本，出问题时好对账
    public var appVersion: String

    public var capture: CaptureSettings?
    public var smoothScroll: SmoothScrollSettings?
    public var recording: Recording?
    public var hotkeys: HotkeySettings?
    public var inputSource: InputSourceSettings?
    public var translate: TranslateSettings?
    public var ocr: OCRSettings?
    public var ruler: RulerSettings?
    public var clipboard: Clipboard?

    public init(version: Int = ConfigBundle.currentVersion,
                exportedAt: Date = Date(),
                appVersion: String = "",
                capture: CaptureSettings? = nil,
                smoothScroll: SmoothScrollSettings? = nil,
                recording: Recording? = nil,
                hotkeys: HotkeySettings? = nil,
                inputSource: InputSourceSettings? = nil,
                translate: TranslateSettings? = nil,
                ocr: OCRSettings? = nil,
                ruler: RulerSettings? = nil,
                clipboard: Clipboard? = nil) {
        self.version = version
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.capture = capture
        self.smoothScroll = smoothScroll
        self.recording = recording
        self.hotkeys = hotkeys
        self.inputSource = inputSource
        self.translate = translate
        self.ocr = ocr
        self.ruler = ruler
        self.clipboard = clipboard
    }

    /// 实际装进来的模块名，按界面上的顺序。导入提示直接用它，别另维护一张表。
    public var sectionNames: [String] {
        var names: [String] = []
        if capture != nil { names.append("截图") }
        if smoothScroll != nil { names.append("平滑滚动") }
        if recording != nil { names.append("录制") }
        if hotkeys != nil { names.append("热键") }
        if inputSource != nil { names.append("输入法记忆") }
        if translate != nil { names.append("翻译") }
        if ocr != nil { names.append("OCR") }
        if ruler != nil { names.append("尺子") }
        if clipboard != nil { names.append("剪贴板") }
        return names
    }

    // MARK: - 读写

    /// 逐段解码：某一段来自更新的版本、字段对不上时只丢这一段，不整份作废
    /// （和各个 store 的宽容解码是同一个思路）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try? container.decode(Int.self, forKey: .version) else {
            throw Failure.unreadable
        }
        guard version <= Self.currentVersion else {
            throw Failure.newerVersion(found: version)
        }
        self.version = version
        exportedAt = (try? container.decode(Date.self, forKey: .exportedAt)) ?? Date()
        appVersion = (try? container.decode(String.self, forKey: .appVersion)) ?? ""
        capture = try? container.decodeIfPresent(CaptureSettings.self, forKey: .capture)
        smoothScroll = try? container.decodeIfPresent(SmoothScrollSettings.self, forKey: .smoothScroll)
        recording = try? container.decodeIfPresent(Recording.self, forKey: .recording)
        hotkeys = try? container.decodeIfPresent(HotkeySettings.self, forKey: .hotkeys)
        inputSource = try? container.decodeIfPresent(InputSourceSettings.self, forKey: .inputSource)
        translate = try? container.decodeIfPresent(TranslateSettings.self, forKey: .translate)
        ocr = try? container.decodeIfPresent(OCRSettings.self, forKey: .ocr)
        ruler = try? container.decodeIfPresent(RulerSettings.self, forKey: .ruler)
        clipboard = try? container.decodeIfPresent(Clipboard.self, forKey: .clipboard)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ConfigBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let bundle = try decoder.decode(ConfigBundle.self, from: data)
            guard !bundle.sectionNames.isEmpty else { throw Failure.empty }
            return bundle
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable
        }
    }
}

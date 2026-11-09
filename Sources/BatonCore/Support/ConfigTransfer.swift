import Foundation

/// 配置的收集与落回。
///
/// 只做「把 store 里的值拼成一份 bundle」和「把 bundle 装回 store」，
/// 文件面板、确认框留给调用方——BatonCore 里不该出现模态 UI。
@MainActor
public final class ConfigTransfer {
    private let capture: CaptureSettingsStore
    private let scroll: ScrollSmoother?
    private let recording: RecordingSettingsStore
    private let hotkeys: HotkeySettingsStore?
    private let inputSource: InputSourceService?
    private let ruler: RulerSettingsStore
    private let clipboard: ClipboardPrefs
    private let translateStore = try? TranslateSettingsStore()
    private let ocrStore = try? OCRSettingsStore()

    public init(capture: CaptureSettingsStore,
                scroll: ScrollSmoother?,
                recording: RecordingSettingsStore,
                hotkeys: HotkeySettingsStore?,
                inputSource: InputSourceService?,
                ruler: RulerSettingsStore,
                clipboard: ClipboardPrefs) {
        self.capture = capture
        self.scroll = scroll
        self.recording = recording
        self.hotkeys = hotkeys
        self.inputSource = inputSource
        self.ruler = ruler
        self.clipboard = clipboard
    }

    public func makeBundle() -> ConfigBundle {
        // 上一次区域的坐标绑着当前显示器，跨机器没意义，导出前抹掉
        var captureSection = capture.settings
        captureSection.lastArea = nil

        // `pid:1234` 是拿不到 bundle id 时的兜底键，换台机器必然对不上；留着只会越积越多
        var inputSection = inputSource?.settings
        if let memory = inputSection?.memory {
            inputSection?.memory = memory.filter { !$0.key.hasPrefix("pid:") }
        }

        return ConfigBundle(
            exportedAt: Date(),
            appVersion: Self.appVersion,
            capture: captureSection,
            smoothScroll: scroll?.settings,
            recording: ConfigBundle.Recording(capturesAudio: recording.capturesAudio,
                                              capturesMicrophone: recording.capturesMicrophone),
            hotkeys: hotkeys?.load(),
            inputSource: inputSection,
            translate: translateStore?.load(),
            ocr: ocrStore?.load(),
            ruler: ruler.settings,
            clipboard: ConfigBundle.Clipboard(maxItems: clipboard.maxItems,
                                              maxBytes: clipboard.maxBytes,
                                              ocrTitles: clipboard.ocrTitles)
        )
    }

    /// 只装文件里有的模块，其余保持原样。
    /// 一律走各 store 现成的 setter / save，不直接写文件——内存里的状态和磁盘必须一起变。
    public func apply(_ bundle: ConfigBundle) throws {
        if let section = bundle.capture {
            // 只拿秒数：lastArea 属于「当前这台机器上次框在哪」
            capture.setTimedSeconds(section.timedSeconds)
        }

        if let section = bundle.smoothScroll, let scroll {
            scroll.apply { $0 = section }
            // 导入的配置是关着的：顺手收尾当前手势，否则松手后还会补几帧动画
            if !section.enabled { scroll.setEnabled(false) }
        }

        if let section = bundle.recording {
            recording.setCapturesAudio(section.capturesAudio)
            recording.setCapturesMicrophone(section.capturesMicrophone)
        }

        if let section = bundle.hotkeys {
            try hotkeys?.save(section)
        }

        if let section = bundle.inputSource {
            inputSource?.replaceSettings(section)
        }

        if let section = bundle.translate {
            try translateStore?.save(section)
        }

        if let section = bundle.ocr {
            try ocrStore?.save(section)
        }

        if let section = bundle.ruler {
            ruler.update { $0 = section }
        }

        if let section = bundle.clipboard {
            clipboard.maxItems = max(section.maxItems, 1)
            clipboard.maxBytes = max(section.maxBytes, 1)
            clipboard.ocrTitles = section.ocrTitles
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

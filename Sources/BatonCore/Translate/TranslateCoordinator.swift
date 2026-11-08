import AppKit
import CoreGraphics
import Foundation

/// 把「取词 / 截图 → OCR → 翻译 → 落地」串成一条链。
///
/// 三条出口：
/// - 划词翻译：前台 App 的选中文本 → 浮窗
/// - 截图 OCR：图像 → 文本 → 剪贴板（同时开 Bob 那个图文对照窗）
/// - 截图翻译：图像 → 文本 → 浮窗（`silentMode` 时只写剪贴板）
///
/// OCR 与翻译各自独立选服务商：OCR 用 `ocr.json` 的 `active`，翻译用 `translate.json` 的 `active`。
@MainActor
public final class TranslateCoordinator {
    private let panel = TranslatePanelController()
    private let ocrPanel = OCRPanelController()
    private var settings: TranslateSettings
    private var ocrSettings: OCRSettings
    /// 语言条改语言后要重跑同一条原文，这里留着上次的输入
    private var lastText: String?

    /// 浮窗右上角「设置」的去处，由 AppShell 接到偏好设置窗口。
    public var onOpenSettings: ((String) -> Void)?
    /// OCR 窗左上角「重新截图」：截图流程在 AppShell 里，绕回来跑一次
    public var onRequestCapture: (() -> Void)?

    public init() {
        self.settings = (try? TranslateSettingsStore())?.load() ?? .default
        self.ocrSettings = (try? OCRSettingsStore())?.load() ?? .default
        panel.onPickSource = { [weak self] code in self?.changeSource(code) }
        panel.onPickTarget = { [weak self] code in self?.changeTarget(code) }
        panel.onSwap = { [weak self] in self?.swapLanguages() }
        panel.onOpenSettings = { [weak self] in self?.onOpenSettings?("翻译") }
        ocrPanel.onTranslate = { [weak self] text, target in
            // 翻译浮窗自己会带原文，OCR 窗留在前面只会互相挡
            self?.ocrPanel.hide()
            Task { await self?.translate(text: text, target: target) }
        }
        ocrPanel.onCapture = { [weak self] in self?.onRequestCapture?() }
        ocrPanel.onRecognizeImage = { [weak self] image in
            Task { await self?.recognize(image: image, silent: false) }
        }
        ocrPanel.onOpenSettings = { [weak self] in self?.onOpenSettings?("OCR") }
    }

    public func reloadSettings() {
        settings = (try? TranslateSettingsStore())?.load() ?? .default
        ocrSettings = (try? OCRSettingsStore())?.load() ?? .default
    }

    private var providerName: String {
        settings.active?.displayName ?? "未配置"
    }

    private var providerID: String {
        settings.active?.id ?? ""
    }

    private var ocrName: String {
        ocrSettings.active?.displayName ?? "未配置"
    }

    /// 语言条要的数据。源语言为空表示交给模型判断。
    private var languages: TranslateLanguagePair {
        TranslateLanguagePair(source: settings.sourceLanguage, target: settings.targetLanguage)
    }

    // MARK: - 三条链路

    public func translateSelection() async {
        guard let text = SelectionReader.selectedText() else {
            // 带上诊断串：是没授权、前台 App 没暴露焦点元素，还是焦点元素里没选中内容
            panel.showFailure(message: "没有取到选中文本（\(SelectionReader.diagnose())）。"
                              + "请先在目标 App 里选中文字，再按一次热键。",
                              source: "",
                              languages: languages,
                              providerName: providerName)
            return
        }
        await translate(text: text)
    }

    public func translate(image: CGImage) async {
        let result: OCRResult
        do {
            result = try await recognize(in: image)
        } catch {
            panel.showFailure(message: "识别失败：\(error.localizedDescription)",
                              source: "",
                              languages: languages,
                              providerName: ocrName)
            return
        }
        guard !result.text.isEmpty else {
            panel.showFailure(message: "图里没有识别到文字。",
                              source: "",
                              languages: languages,
                              providerName: ocrName)
            return
        }
        await translate(text: result.text)
    }

    /// 只做 OCR，不翻译。
    public func recognize(image: CGImage, silent: Bool) async {
        do {
            let result = try await recognize(in: image)
            // 二维码跟文字一起出：截图里常常只有一个码，没有内容可选
            let codes = await QRScanner.scan(image)
            let text = result.text
            guard !text.isEmpty || !codes.isEmpty else {
                panel.showFailure(message: "图里没有识别到文字，也没有二维码。",
                                  source: "",
                                  languages: languages,
                                  providerName: ocrName)
                return
            }
            let combined = Self.combined(text: text, codes: codes)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(combined, forType: .string)
            if !silent {
                ocrPanel.show(image: image,
                              lines: result.lines,
                              text: text,
                              engine: ocrName,
                              copiedHint: combined.isEmpty ? nil : "已复制 \(combined.count) 个字符",
                              codes: codes)
                panel.hide()
            }
        } catch {
            panel.showFailure(message: "识别失败：\(error.localizedDescription)",
                              source: "",
                              languages: languages,
                              providerName: ocrName)
        }
    }

    /// 剪贴板里放「文本 + 二维码内容」：截一张码就是为了直接粘链接，
    /// 不该让人再回窗口点一次复制。两段之间空一行，跟 Bob 的「复制所有」一致。
    static func combined(text: String, codes: [QRCode]) -> String {
        var parts: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        let listing = codes.map(\.payload).joined(separator: "\n\n")
        if !listing.isEmpty { parts.append(listing) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 内部

    private func recognize(in image: CGImage) async throws -> OCRResult {
        guard let config = ocrSettings.active else {
            throw OCRError.requestFailed("没有可用的 OCR 服务")
        }
        let transport = try OCRTransportFactory.make(config)
        return try await transport.recognize(OCRRequest(image: image))
    }

    /// `target` 非空时只影响这一下（OCR 窗右下角的语言胶囊），不改全局设置。
    private func translate(text: String, target: String? = nil) async {
        lastText = text
        let target = target ?? settings.targetLanguage
        let pair = TranslateLanguagePair(source: settings.sourceLanguage, target: target)
        guard let config = settings.active else {
            panel.showFailure(message: "没有配置翻译服务，先跑 --translate-preset",
                              source: text,
                              languages: pair,
                              providerName: "未配置")
            return
        }

        let provider: any TranslateProvider
        do {
            provider = try TranslateProviderFactory.make(config)
        } catch {
            panel.showFailure(message: error.localizedDescription,
                              source: text,
                              languages: pair,
                              providerName: config.displayName,
                              providerID: config.id)
            return
        }

        panel.showLoading(source: text,
                          languages: pair,
                          providerName: config.displayName,
                          providerID: config.id)
        do {
            let result = try await provider.translate(TranslateRequest(text: text,
                                                                      source: settings.sourceLanguage,
                                                                      target: target))
            if settings.silentMode {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.text, forType: .string)
                panel.hide()
            } else {
                panel.show(result: result,
                           source: text,
                           languages: pair,
                           providerName: config.displayName,
                           providerID: config.id)
            }
        } catch {
            panel.showFailure(message: error.localizedDescription,
                              source: text,
                              languages: pair,
                              providerName: config.displayName,
                              providerID: config.id)
        }
    }

    // MARK: - 语言切换

    private func changeSource(_ code: String?) {
        guard code != settings.sourceLanguage else { return }
        settings.sourceLanguage = code
        persist()
        panel.updateLanguages(languages)
        retranslate()
    }

    private func changeTarget(_ code: String) {
        guard code != settings.targetLanguage else { return }
        settings.targetLanguage = code
        persist()
        panel.updateLanguages(languages)
        retranslate()
    }

    private func swapLanguages() {
        // 「自动检测」没有具体语言可换，换成最常见的英中互转
        if settings.sourceLanguage == nil {
            settings.sourceLanguage = settings.targetLanguage
            settings.targetLanguage = settings.targetLanguage == "zh-Hans" ? "en" : "zh-Hans"
        } else {
            let oldSource = settings.sourceLanguage
            settings.sourceLanguage = settings.targetLanguage
            settings.targetLanguage = oldSource ?? "zh-Hans"
        }
        persist()
        panel.updateLanguages(languages)
        retranslate()
    }

    private func retranslate() {
        guard let text = lastText, !text.isEmpty else { return }
        Task { await translate(text: text) }
    }

    private func persist() {
        try? TranslateSettingsStore().save(settings)
    }

    public func hidePanel() {
        panel.hide()
        ocrPanel.hide()
    }
}

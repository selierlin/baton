import AppKit
import CoreGraphics
import Foundation

/// 把「取词 / 截图 → OCR → 翻译 → 落地」串成一条链。
///
/// 三条出口：
/// - 划词翻译：前台 App 的选中文本 → 浮窗
/// - 截图 OCR：图像 → 文本 → 剪贴板
/// - 截图翻译：图像 → 文本 → 浮窗（`silentMode` 时只写剪贴板）
///
/// OCR 与翻译各自独立选服务商：OCR 用 `ocr.json` 的 `active`，翻译用 `translate.json` 的 `active`。
@MainActor
public final class TranslateCoordinator {
    private let panel = TranslatePanelController()
    private var settings: TranslateSettings
    private var ocrSettings: OCRSettings

    public init() {
        self.settings = (try? TranslateSettingsStore())?.load() ?? .default
        self.ocrSettings = (try? OCRSettingsStore())?.load() ?? .default
    }

    public func reloadSettings() {
        settings = (try? TranslateSettingsStore())?.load() ?? .default
        ocrSettings = (try? OCRSettingsStore())?.load() ?? .default
    }

    private var providerName: String {
        settings.active?.displayName ?? "未配置"
    }

    private var ocrName: String {
        ocrSettings.active?.displayName ?? "未配置"
    }

    // MARK: - 三条链路

    public func translateSelection() async {
        guard let text = SelectionReader.selectedText() else {
            // 带上诊断串：是没授权、前台 App 没暴露焦点元素，还是焦点元素里没选中内容
            panel.showFailure(message: "没有取到选中文本（\(SelectionReader.diagnose())）。"
                              + "请先在目标 App 里选中文字，再按一次热键。",
                              source: "",
                              providerName: providerName)
            return
        }
        await translate(text: text)
    }

    public func translate(image: CGImage) async {
        let text: String
        do {
            text = try await recognizeText(in: image)
        } catch {
            panel.showFailure(message: "识别失败：\(error.localizedDescription)",
                              source: "",
                              providerName: ocrName)
            return
        }
        guard !text.isEmpty else {
            panel.showFailure(message: "图里没有识别到文字。",
                              source: "",
                              providerName: ocrName)
            return
        }
        await translate(text: text)
    }

    /// 只做 OCR，不翻译。
    public func recognize(image: CGImage, silent: Bool) async {
        do {
            let text = try await recognizeText(in: image)
            guard !text.isEmpty else {
                panel.showFailure(message: "图里没有识别到文字。",
                                  source: "",
                                  providerName: ocrName)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if !silent {
                panel.showText(title: "OCR · \(ocrName) · 已复制 \(text.count) 个字符", body: text)
            }
        } catch {
            panel.showFailure(message: "识别失败：\(error.localizedDescription)",
                              source: "",
                              providerName: ocrName)
        }
    }

    // MARK: - 内部

    private func recognizeText(in image: CGImage) async throws -> String {
        guard let config = ocrSettings.active else {
            throw OCRError.requestFailed("没有可用的 OCR 服务")
        }
        let transport = try OCRTransportFactory.make(config)
        let result = try await transport.recognize(OCRRequest(image: image))
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func translate(text: String) async {
        guard let config = settings.active else {
            panel.showFailure(message: "没有配置翻译服务，先跑 --translate-preset",
                              source: text,
                              providerName: "未配置")
            return
        }

        let provider: any TranslateProvider
        do {
            provider = try TranslateProviderFactory.make(config)
        } catch {
            panel.showFailure(message: error.localizedDescription,
                              source: text,
                              providerName: config.displayName)
            return
        }

        panel.showLoading(source: text, providerName: config.displayName)
        do {
            let result = try await provider.translate(TranslateRequest(text: text,
                                                                      source: settings.sourceLanguage,
                                                                      target: settings.targetLanguage))
            if settings.silentMode {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.text, forType: .string)
                panel.hide()
            } else {
                panel.show(result: result,
                           source: text,
                           providerName: config.displayName)
            }
        } catch {
            panel.showFailure(message: error.localizedDescription,
                              source: text,
                              providerName: config.displayName)
        }
    }

    public func hidePanel() {
        panel.hide()
    }
}

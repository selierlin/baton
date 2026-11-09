import Foundation
import XCTest
@testable import BatonCore

final class TranslateSettingsTests: XCTestCase {
    func testChatCompletionsURLAppendsPath() {
        let config = ProviderConfig(id: "deepseek",
                                    displayName: "DeepSeek",
                                    baseURL: URL(string: "https://api.deepseek.com/v1")!,
                                    model: "deepseek-chat",
                                    apiKeyRef: "provider.deepseek")
        XCTAssertEqual(config.chatCompletionsURL?.absoluteString,
                       "https://api.deepseek.com/v1/chat/completions")
    }

    func testPresetsAreConfigurable() {
        for preset in ProviderPreset.all {
            guard let config = preset.config() else {
                return XCTFail("预设 \(preset.id) 生成配置失败")
            }
            XCTAssertEqual(config.apiKeyRef, "provider.\(preset.id)")
            XCTAssertEqual(config.kind, preset.kind, "预设 \(preset.id) 的 kind 没带进配置")
            switch preset.kind {
            case .openAICompatible, .proxy:
                XCTAssertNotNil(config.baseURL, "预设 \(preset.id) 的 baseURL 解析失败")
                XCTAssertFalse(config.model.isEmpty, "预设 \(preset.id) 没有默认模型")
            case .baiduTranslate, .tencentTranslate:
                // 按账号签名的服务商没有接口地址，模型也不参与请求
                XCTAssertNil(config.baseURL)
            }
        }
    }

    func testAccountBasedPresetsAreOfferedInSettings() {
        // 百度传输层早就写完了，但预设里没有条目时下拉框永远选不到它
        XCTAssertNotNil(ProviderPreset.all.first { $0.id == "baidu" && $0.kind == .baiduTranslate })
        XCTAssertNotNil(ProviderPreset.all.first { $0.id == "tencent" && $0.kind == .tencentTranslate })
    }

    func testAccountBasedKindsAskForAccountInsteadOfEndpoint() {
        for kind in [ProviderConfig.Kind.baiduTranslate, .tencentTranslate] {
            let targets = kind.fields.map(\.target)
            XCTAssertTrue(targets.contains(.accountID), "\(kind) 少了账号输入项")
            XCTAssertTrue(targets.contains(.secret), "\(kind) 少了密钥输入项")
            XCTAssertFalse(targets.contains(.endpoint), "\(kind) 不该要接口地址")
        }
    }

    func testSystemPromptNamesBothLanguages() {
        let prompt = OpenAICompatibleProvider.systemPrompt(source: "en-US", target: "zh-Hans")
        XCTAssertTrue(prompt.contains("English"))
        XCTAssertTrue(prompt.contains("Simplified Chinese"))
    }

    func testSystemPromptOmitsSourceWhenUnknown() {
        let prompt = OpenAICompatibleProvider.systemPrompt(source: nil, target: "ja-JP")
        XCTAssertFalse(prompt.contains("from "))
        XCTAssertTrue(prompt.contains("Japanese"))
    }

    func testSettingsStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-translate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try TranslateSettingsStore(directory: directory)
        var settings = TranslateSettings.default
        settings.targetLanguage = "ja-JP"
        settings.sourceLanguage = "en-US"
        settings.silentMode = true
        try store.save(settings)

        XCTAssertEqual(store.load(), settings)
    }

    func testMissingKeySurfacesAsMissingAPIKey() {
        let config = ProviderConfig(id: "ghost",
                                    displayName: "Ghost",
                                    baseURL: URL(string: "http://127.0.0.1:1/v1")!,
                                    model: "none",
                                    apiKeyRef: "provider.definitely-not-set-\(UUID().uuidString)")
        XCTAssertThrowsError(try OpenAICompatibleProvider(config: config)) { error in
            XCTAssertEqual(error as? TranslateError,
                           .missingAPIKey(account: config.apiKeyRef))
        }
    }
}

/// 取词的字符串收尾：AX 拿回来的东西经常带换行/前后空格（Safari 的标记范围尤其）
final class SelectionReaderTests: XCTestCase {
    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(SelectionReader.normalize("  hello \n"), "hello")
    }

    func testKeepsInnerNewlines() {
        XCTAssertEqual(SelectionReader.normalize("\n第一行\n第二行\n"), "第一行\n第二行")
    }

    func testEmptyAndWhitespaceOnlyBecomeNil() {
        XCTAssertNil(SelectionReader.normalize(nil))
        XCTAssertNil(SelectionReader.normalize(""))
        XCTAssertNil(SelectionReader.normalize(" \n\t "))
    }
}

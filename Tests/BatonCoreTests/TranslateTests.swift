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

    func testPresetsAllHaveValidURLs() {
        for preset in ProviderPreset.all {
            let config = preset.config()
            XCTAssertNotNil(config, "预设 \(preset.id) 的 baseURL 解析失败")
            XCTAssertEqual(config?.apiKeyRef, "provider.\(preset.id)")
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

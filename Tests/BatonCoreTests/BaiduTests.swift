import CoreGraphics
import Foundation
import XCTest
@testable import BatonCore

final class BaiduTranslateTests: XCTestCase {
    func testSignatureMatchesDocumentedOrder() {
        // 拼接顺序 appid + q + salt + 密钥，任何一处颠倒都会换出别的值。
        let sign = BaiduTranslateProvider.signature(appID: "2015063000000001",
                                                    text: "apple",
                                                    salt: "1435660288",
                                                    secret: "12345678")
        XCTAssertEqual(sign, "f89f9594663708c1605f3d736d01d2d4")
        XCTAssertEqual(sign.count, 32)
    }

    func testSignatureUsesRawTextNotEncoded() {
        let raw = BaiduTranslateProvider.signature(appID: "a", text: "你好 world", salt: "1", secret: "s")
        let encoded = BaiduTranslateProvider.signature(appID: "a",
                                                       text: "你好%20world",
                                                       salt: "1",
                                                       secret: "s")
        XCTAssertNotEqual(raw, encoded)
    }

    func testLanguageCodesUseBaiduSpelling() {
        // 百度不是 ISO：日语 jp、韩语 kor、繁体 cht。
        XCTAssertEqual(BaiduTranslateProvider.languageCode("ja-JP"), "jp")
        XCTAssertEqual(BaiduTranslateProvider.languageCode("ko-KR"), "kor")
        XCTAssertEqual(BaiduTranslateProvider.languageCode("zh-Hant"), "cht")
        XCTAssertEqual(BaiduTranslateProvider.languageCode("zh-Hans"), "zh")
        XCTAssertEqual(BaiduTranslateProvider.languageCode(nil), "auto")
    }

    func testMissingAppIDThrowsMissingConfig() {
        let config = ProviderConfig(id: "baidu",
                                    displayName: "百度翻译",
                                    kind: .baiduTranslate,
                                    apiKeyRef: "provider.baidu")
        XCTAssertThrowsError(try BaiduTranslateProvider(config: config, secretKey: "x")) { error in
            guard case TranslateError.missingConfig = error else {
                return XCTFail("期望 missingConfig，实际 \(error)")
            }
        }
    }

    func testMissingSecretThrowsMissingAPIKey() {
        let config = ProviderConfig(id: "baidu-\(UUID().uuidString)",
                                    displayName: "百度翻译",
                                    kind: .baiduTranslate,
                                    apiKeyRef: "provider.definitely-not-set-\(UUID().uuidString)",
                                    appID: "123")
        XCTAssertThrowsError(try BaiduTranslateProvider(config: config)) { error in
            XCTAssertEqual(error as? TranslateError,
                           .missingAPIKey(account: config.apiKeyRef))
        }
    }
}

final class TranslateSettingsMultiProviderTests: XCTestCase {
    private func makeStore() throws -> (TranslateSettingsStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-multi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try TranslateSettingsStore(directory: directory), directory)
    }

    func testMultipleProvidersRoundTrip() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let openAI = ProviderConfig(id: "deepseek",
                                    displayName: "DeepSeek",
                                    baseURL: URL(string: "https://api.deepseek.com/v1"),
                                    model: "deepseek-chat",
                                    apiKeyRef: "provider.deepseek")
        let baidu = ProviderConfig(id: "baidu",
                                   displayName: "百度翻译",
                                   kind: .baiduTranslate,
                                   apiKeyRef: "provider.baidu",
                                   appID: "2015063000000001")
        let settings = TranslateSettings(providers: [openAI, baidu], activeID: "baidu")
        try store.save(settings)

        let loaded = store.load()
        XCTAssertEqual(loaded.providers.count, 2)
        XCTAssertEqual(loaded.activeID, "baidu")
        XCTAssertEqual(loaded.active?.kind, .baiduTranslate)
        XCTAssertEqual(loaded.active?.appID, "2015063000000001")
    }

    func testActiveFallsBackToFirstWhenIDMissing() {
        let only = ProviderConfig(id: "solo",
                                  displayName: "Solo",
                                  baseURL: URL(string: "http://localhost:1/v1"),
                                  model: "m",
                                  apiKeyRef: "provider.solo")
        let settings = TranslateSettings(providers: [only], activeID: "ghost")
        XCTAssertEqual(settings.active?.id, "solo")
    }

    func testLegacySingleProviderConfigStillDecodes() throws {
        let json = """
        {
          "provider": {
            "id": "deepseek",
            "displayName": "DeepSeek",
            "kind": "openAICompatible",
            "baseURL": "https://api.deepseek.com/v1",
            "model": "deepseek-chat",
            "apiKeyRef": "provider.deepseek"
          },
          "targetLanguage": "ja-JP",
          "silentMode": true
        }
        """
        let settings = try JSONDecoder().decode(TranslateSettings.self,
                                                from: Data(json.utf8))
        XCTAssertEqual(settings.providers.count, 1)
        XCTAssertEqual(settings.activeID, "deepseek")
        XCTAssertEqual(settings.targetLanguage, "ja-JP")
        XCTAssertTrue(settings.silentMode)
    }
}

final class BaiduOCRUploadTests: XCTestCase {
    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // 画点噪声，避免纯色图被 JPEG 压到极小、测不出上限逻辑。
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                context.setFillColor(red: CGFloat((x / 8) % 255) / 255,
                                     green: CGFloat((y / 8) % 255) / 255,
                                     blue: 0.5,
                                     alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        return context.makeImage()
    }

    func testEncodedPayloadStaysUnderLimit() throws {
        guard let image = makeImage(width: 1600, height: 900) else {
            return XCTFail("构造测试图片失败")
        }
        let data = try BaiduOCRTransport.encodeForUpload(image)
        XCTAssertLessThanOrEqual(data.base64EncodedString().utf8.count,
                                 BaiduOCRTransport.uploadLimit)
        XCTAssertFalse(data.isEmpty)
    }

    func testOversizedImageGetsScaledDown() throws {
        guard let image = makeImage(width: 2880, height: 1800) else {
            return XCTFail("构造测试图片失败")
        }
        let data = try BaiduOCRTransport.encodeForUpload(image)
        XCTAssertLessThanOrEqual(data.base64EncodedString().utf8.count,
                                 BaiduOCRTransport.uploadLimit)
    }
}

final class OCRReadingOrderTests: XCTestCase {
    func testKeepsOriginalOrderWhenCoordinatesMissing() {
        // 百度的 `*_basic` 接口不给 location。此时按 minY 排会把所有行挤到 0，
        // 必须整体保持服务端返回顺序。
        let first = OCRLine(text: "第一行", points: [])
        let second = OCRLine(text: "第二行", points: [])
        XCTAssertEqual(OCRLine.readingOrder([first, second]).map(\.text), ["第一行", "第二行"])
    }

    func testSortsWhenAllHaveCoordinates() {
        let bottom = OCRLine(text: "bottom", rect: CGRect(x: 0, y: 100, width: 50, height: 10))
        let top = OCRLine(text: "top", rect: CGRect(x: 0, y: 0, width: 50, height: 10))
        XCTAssertEqual(OCRLine.readingOrder([bottom, top]).map(\.text), ["top", "bottom"])
    }

    func testMixedCoordinatesAlsoKeepsOrder() {
        let a = OCRLine(text: "a", rect: CGRect(x: 0, y: 50, width: 10, height: 10))
        let b = OCRLine(text: "b", points: [])
        XCTAssertEqual(OCRLine.readingOrder([a, b]).map(\.text), ["a", "b"])
    }
}

final class OCRSettingsTests: XCTestCase {
    private func makeStore() throws -> (OCRSettingsStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try OCRSettingsStore(directory: directory), directory)
    }

    func testDefaultIsVision() {
        XCTAssertEqual(OCRSettings.default.activeID, "vision")
        XCTAssertEqual(OCRSettings.default.active?.kind, .vision)
    }

    func testSwitchToBaiduPersists() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = store.load()
        settings.providers.append(.baidu)
        settings.activeID = "baidu"
        try store.save(settings)

        let loaded = store.load()
        XCTAssertEqual(loaded.active?.kind, .baidu)
        XCTAssertEqual(loaded.active?.variant, "general")
    }

    /// 账号（App ID / SecretId）和翻译侧一致：明文进配置文件，界面上能回显。
    func testAccountIDPersistsInConfigFile() throws {
        var config = OCRProviderConfig.baidu
        config.accountID = "20191112000356260"
        let settings = OCRSettings(providers: [.vision, config], activeID: "baidu")

        let data = try JSONEncoder().encode(settings)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("20191112000356260"))

        let decoded = try JSONDecoder().decode(OCRSettings.self, from: data)
        XCTAssertEqual(decoded.active?.accountID, "20191112000356260")
    }

    /// 旧配置只有 Keychain 条目名，没有 accountID，解码不能失败。
    func testLegacyConfigWithoutAccountIDStillDecodes() throws {
        let json = """
        {"activeID":"baidu","providers":[
          {"id":"baidu","displayName":"百度 OCR","kind":"baidu",
           "apiKeyRef":"ocr.baidu.ak","secretRef":"ocr.baidu.sk","variant":"general"}
        ]}
        """
        let decoded = try JSONDecoder().decode(OCRSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.active?.accountID, nil)
        XCTAssertEqual(decoded.active?.apiKeyRef, "ocr.baidu.ak")
    }

    /// 账号来自配置文件、密钥来自刚敲的内容时，工厂不该再去 Keychain 要账号。
    func testFactoryResolvesAccountFromConfigAndTypedKey() throws {
        var config = OCRProviderConfig.baidu
        config.accountID = "appid-from-config"
        let transport = try OCRTransportFactory.make(config, key: "typed-secret")
        XCTAssertTrue(transport is BaiduOCRTransport)
    }
}

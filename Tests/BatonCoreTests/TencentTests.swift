import CoreGraphics
import Foundation
import XCTest
@testable import BatonCore

final class TencentCloudSignerTests: XCTestCase {
    private let body = Data(#"{"SourceText":"hello","Source":"en","Target":"zh"}"#.utf8)

    func testSha256HexOfEmptyData() {
        // 空字符串的 SHA-256 是所有实现的公共基准，抄错一位这里就会挂
        XCTAssertEqual(TencentCloudSigner.sha256Hex(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testDateStringUsesUTC() {
        // 2023-12-31T23:00:00Z。本地时区（UTC+8）已经是 1 月 1 日，
        // 签名域必须按 UTC 算，用本地日历会在跨零点前后全挂。
        XCTAssertEqual(TencentCloudSigner.dateString(timestamp: 1_704_063_600), "2023-12-31")
    }

    func testAuthorizationShape() {
        let value = TencentCloudSigner.authorization(secretID: "AKIDEXAMPLE",
                                                     secretKey: "secret",
                                                     host: "tmt.tencentcloudapi.com",
                                                     service: "tmt",
                                                     body: body,
                                                     timestamp: 1_704_063_600)
        XCTAssertTrue(value.hasPrefix("TC3-HMAC-SHA256 Credential=AKIDEXAMPLE/2023-12-31/tmt/tc3_request"))
        XCTAssertTrue(value.contains("SignedHeaders=content-type;host"))

        let signature = value.components(separatedBy: "Signature=").last ?? ""
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(signature.allSatisfy { $0.isHexDigit })
    }

    func testAuthorizationIsDeterministic() {
        let a = TencentCloudSigner.authorization(secretID: "id", secretKey: "key",
                                                 host: "ocr.tencentcloudapi.com",
                                                 service: "ocr", body: body,
                                                 timestamp: 1_704_063_600)
        let b = TencentCloudSigner.authorization(secretID: "id", secretKey: "key",
                                                 host: "ocr.tencentcloudapi.com",
                                                 service: "ocr", body: body,
                                                 timestamp: 1_704_063_600)
        XCTAssertEqual(a, b)
    }

    func testSignatureDependsOnBodyAndSecret() {
        func sign(_ body: Data, _ secret: String) -> String {
            TencentCloudSigner.authorization(secretID: "id", secretKey: secret,
                                             host: "tmt.tencentcloudapi.com",
                                             service: "tmt", body: body,
                                             timestamp: 1_704_063_600)
        }
        XCTAssertNotEqual(sign(body, "a"), sign(Data("{".utf8), "a"))
        XCTAssertNotEqual(sign(body, "a"), sign(body, "b"))
    }

    func testHeadersCarryActionVersionAndRegion() {
        let signer = TencentCloudSigner(secretID: "id", secretKey: "key")
        let headers = signer.headers(host: TencentTranslateProvider.host,
                                     service: TencentTranslateProvider.service,
                                     action: "TextTranslate",
                                     version: TencentTranslateProvider.apiVersion,
                                     region: TencentTranslateProvider.region,
                                     body: body,
                                     timestamp: 1_704_063_600)
        XCTAssertEqual(headers["X-TC-Action"], "TextTranslate")
        XCTAssertEqual(headers["X-TC-Version"], "2018-03-21")
        XCTAssertEqual(headers["X-TC-Region"], "ap-guangzhou")
        XCTAssertEqual(headers["Host"], "tmt.tencentcloudapi.com")
        XCTAssertEqual(headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertEqual(headers["X-TC-Timestamp"], "1704063600")
        XCTAssertNotNil(headers["Authorization"])
    }
}

final class TencentTranslateTests: XCTestCase {
    func testLanguageCodes() {
        // 腾讯基本沿用 ISO，只有繁体是 zh-TW（百度是 cht）
        XCTAssertEqual(TencentTranslateProvider.languageCode("zh-Hans"), "zh")
        XCTAssertEqual(TencentTranslateProvider.languageCode("zh-Hant"), "zh-TW")
        XCTAssertEqual(TencentTranslateProvider.languageCode("ja-JP"), "ja")
        XCTAssertEqual(TencentTranslateProvider.languageCode(nil), "auto")
    }

    func testSignatureFailureExplained() {
        let message = TencentTranslateProvider.explain("AuthFailure.SignatureFailure", fallback: "raw")
        XCTAssertTrue(message.contains("SecretKey"))
        XCTAssertTrue(message.contains("AuthFailure.SignatureFailure"))
    }

    func testUnknownCodeFallsBackToServerMessage() {
        XCTAssertEqual(TencentTranslateProvider.explain("Something.Weird", fallback: "服务端原话"),
                       "服务端原话（Something.Weird）")
    }

    func testMissingSecretIDThrowsMissingConfig() {
        let config = ProviderConfig(id: "tencent",
                                    displayName: "腾讯翻译",
                                    kind: .tencentTranslate,
                                    apiKeyRef: "provider.tencent")
        XCTAssertThrowsError(try TencentTranslateProvider(config: config, secretKey: "x")) { error in
            guard case TranslateError.missingConfig = error else {
                return XCTFail("期望 missingConfig，实际 \(error)")
            }
        }
    }

    func testMissingSecretKeyThrowsMissingAPIKey() {
        let config = ProviderConfig(id: "tencent-\(UUID().uuidString)",
                                    displayName: "腾讯翻译",
                                    kind: .tencentTranslate,
                                    apiKeyRef: "provider.missing-\(UUID().uuidString)",
                                    appID: "AKID")
        XCTAssertThrowsError(try TencentTranslateProvider(config: config)) { error in
            XCTAssertEqual(error as? TranslateError,
                           .missingAPIKey(account: config.apiKeyRef))
        }
    }
}

final class OCRProviderKindTests: XCTestCase {
    func testCredentialAccountsMatchKeychainConstants() {
        let baidu = try? XCTUnwrap(OCRProviderConfig.Kind.baidu.credentials)
        XCTAssertEqual(baidu?.idAccount, BaiduOCRCredentials.accessKeyAccount)
        XCTAssertEqual(baidu?.secretAccount, BaiduOCRCredentials.secretKeyAccount)

        let tencent = try? XCTUnwrap(OCRProviderConfig.Kind.tencent.credentials)
        XCTAssertEqual(tencent?.idAccount, TencentOCRCredentials.secretIDAccount)
        XCTAssertEqual(tencent?.secretAccount, TencentOCRCredentials.secretKeyAccount)
        XCTAssertEqual(tencent?.idLabel, "SecretId")
    }

    func testVisionHasNoCredentials() {
        XCTAssertNil(OCRProviderConfig.Kind.vision.credentials)
    }

    func testOnlyBaiduHasVariant() {
        XCTAssertTrue(OCRProviderConfig.Kind.baidu.hasVariant)
        XCTAssertFalse(OCRProviderConfig.Kind.tencent.hasVariant)
    }

    func testTencentExplainNamesTheRealProblem() {
        let message = TencentOCRTransport.explain("FailedOperation.NoFreeAmount", fallback: "raw")
        XCTAssertTrue(message.contains("免费额度"))
    }
}

final class OCRSelfTestImageTests: XCTestCase {
    func testImageHasExpectedPixelSize() throws {
        let image = try OCRSelfTest.image()
        XCTAssertEqual(image.width, 360)
        XCTAssertEqual(image.height, 110)
    }

    func testImageIsReadableByVision() async throws {
        // 自检图必须真能被认出来，否则「测试连接」会对着云端报「没识别出字」，
        // 而问题其实出在测试图本身。
        let result = try await VisionOCRTransport().recognize(OCRRequest(image: try OCRSelfTest.image()))
        XCTAssertTrue(result.text.uppercased().contains("HELLO"),
                      "自检图应能识别出 HELLO，实际：\(result.text)")
    }
}

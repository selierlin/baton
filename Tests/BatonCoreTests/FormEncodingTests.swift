import Foundation
import XCTest
@testable import BatonCore

final class FormEncodingTests: XCTestCase {
    func testPlusSlashEqualsAreEncoded() {
        // 关键回归：`URLComponents` 会原样保留 `+`，服务端按表单解析成空格，
        // base64 被破坏后百度报 216201 图片格式错误。
        XCTAssertEqual(FormEncoding.encode("ab+cd/ef=="), "ab%2Bcd%2Fef%3D%3D")
    }

    func testBase64RoundTrips() {
        let original = Data((0..<512).map { UInt8($0 % 256) }).base64EncodedString()
        let encoded = FormEncoding.encode(original)
        XCTAssertEqual(encoded.removingPercentEncoding, original)
        XCTAssertFalse(encoded.contains("+"), "编码后不应残留 +")
        XCTAssertFalse(encoded.contains("/"), "编码后不应残留 /")
    }

    func testChineseIsEncodedNotLeftRaw() {
        // `CharacterSet.alphanumerics` 包含 Unicode 字母，中文会被原样放过，这里必须编码。
        let encoded = FormEncoding.encode("你好")
        XCTAssertEqual(encoded, "%E4%BD%A0%E5%A5%BD")
    }

    func testBodyJoinsFields() {
        let body = FormEncoding.body([(key: "q", value: "a+b"), (key: "to", value: "zh")])
        XCTAssertEqual(String(decoding: body ?? Data(), as: UTF8.self), "q=a%2Bb&to=zh")
    }

    func testSpaceBecomesPercent20NotPlus() {
        // 表单允许用 + 表示空格，但我们输出端统一用 %20，避免与真实 + 混淆。
        XCTAssertEqual(FormEncoding.encode("a b"), "a%20b")
    }
}

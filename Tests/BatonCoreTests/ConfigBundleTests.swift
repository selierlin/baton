import Foundation
import XCTest
@testable import BatonCore

final class ConfigBundleTests: XCTestCase {
    private func makeBundle() -> ConfigBundle {
        ConfigBundle(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "0.1.0 (1)",
            capture: CaptureSettings(lastArea: nil, timedSeconds: 10),
            smoothScroll: SmoothScrollSettings(),
            recording: ConfigBundle.Recording(capturesAudio: false, capturesMicrophone: true),
            hotkeys: .default,
            clipboard: ConfigBundle.Clipboard(maxItems: 1500, maxBytes: 1024 * 1024 * 1024,
                                              ocrTitles: false)
        )
    }

    func testRoundTrip() throws {
        let original = makeBundle()
        let decoded = try ConfigBundle.decode(try original.encoded())

        XCTAssertEqual(decoded.version, ConfigBundle.currentVersion)
        XCTAssertEqual(decoded.exportedAt, original.exportedAt)
        XCTAssertEqual(decoded.appVersion, "0.1.0 (1)")
        XCTAssertEqual(decoded.capture, original.capture)
        XCTAssertEqual(decoded.smoothScroll, original.smoothScroll)
        XCTAssertEqual(decoded.recording, original.recording)
        XCTAssertEqual(decoded.hotkeys, original.hotkeys)
        XCTAssertEqual(decoded.clipboard, original.clipboard)
        // 文件里没有的模块解码后仍是 nil，不会被填成默认值
        XCTAssertNil(decoded.translate)
        XCTAssertNil(decoded.ocr)
    }

    func testSectionNamesFollowContent() {
        let bundle = makeBundle()
        XCTAssertEqual(bundle.sectionNames, ["截图", "平滑滚动", "录制", "热键", "剪贴板"])

        var onlyCapture = bundle
        onlyCapture.smoothScroll = nil
        onlyCapture.recording = nil
        onlyCapture.hotkeys = nil
        onlyCapture.clipboard = nil
        XCTAssertEqual(onlyCapture.sectionNames, ["截图"])
    }

    func testRejectsNewerFormat() throws {
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try makeBundle().encoded()) as? [String: Any])
        json["version"] = ConfigBundle.currentVersion + 1
        let data = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try ConfigBundle.decode(data)) { error in
            XCTAssertEqual(error as? ConfigBundle.Failure,
                           .newerVersion(found: ConfigBundle.currentVersion + 1))
        }
    }

    func testRejectsEmptyAndGarbage() {
        XCTAssertThrowsError(try ConfigBundle.decode(Data("{\"version\": 1}".utf8))) { error in
            XCTAssertEqual(error as? ConfigBundle.Failure, .empty)
        }
        XCTAssertThrowsError(try ConfigBundle.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? ConfigBundle.Failure, .unreadable)
        }
        XCTAssertThrowsError(try ConfigBundle.decode(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? ConfigBundle.Failure, .unreadable)
        }
    }

    /// 某一段坏掉（比如字段对不上）只丢这一段，别的模块照常导入。
    func testBadSectionIsDroppedNotFatal() throws {
        let json = """
        {
          "version": 1,
          "appVersion": "0.1.0 (1)",
          "hotkeys": {},
          "translate": { "providers": [] }
        }
        """
        let bundle = try ConfigBundle.decode(Data(json.utf8))
        XCTAssertNotNil(bundle.hotkeys)
        XCTAssertNil(bundle.translate)
        XCTAssertEqual(bundle.sectionNames, ["热键"])
    }
}

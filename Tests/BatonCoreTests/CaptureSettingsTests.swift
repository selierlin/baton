import XCTest
@testable import BatonCore

@MainActor
final class CaptureSettingsTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-capture-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("capture.json")
    }

    func testLastAreaSurvivesReload() throws {
        let url = tempURL()
        let store = CaptureSettingsStore(url: url)
        store.remember(rect: CGRect(x: 100, y: 200, width: 640, height: 480), displayID: 42)

        let reloaded = CaptureSettingsStore(url: url)
        let area = try XCTUnwrap(reloaded.settings.lastArea)
        XCTAssertEqual(area.rect, CGRect(x: 100, y: 200, width: 640, height: 480))
        XCTAssertEqual(area.display, 42)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testMissingFileFallsBackToDefaults() {
        let store = CaptureSettingsStore(url: tempURL())
        XCTAssertNil(store.settings.lastArea)
        XCTAssertEqual(store.settings.timedSeconds, 5)
    }

    func testTimedSecondsIsClamped() {
        let url = tempURL()
        let store = CaptureSettingsStore(url: url)
        store.setTimedSeconds(0)
        XCTAssertEqual(store.settings.timedSeconds, 1)
        store.setTimedSeconds(999)
        XCTAssertEqual(store.settings.timedSeconds, 60)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// 老配置缺字段、或字段是脏值时不能整份失效——否则用户升级一次就丢上次区域。
    func testCorruptFieldsDecodeToDefaults() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try #"{"timedSeconds": 9999}"#.data(using: .utf8)?.write(to: url)

        let store = CaptureSettingsStore(url: url)
        XCTAssertEqual(store.settings.timedSeconds, 5)
        XCTAssertNil(store.settings.lastArea)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// 分辨率变了、旧区域整块跑到屏幕外时必须判不可用，否则「上一次区域」会截到空白。
    func testLastAreaUsability() {
        let area = CaptureSettings.LastArea(rect: CGRect(x: 100, y: 100, width: 200, height: 200),
                                            displayID: 1)
        XCTAssertTrue(area.isUsable(on: CGRect(x: 0, y: 0, width: 1440, height: 900)))
        XCTAssertFalse(area.isUsable(on: CGRect(x: 2000, y: 0, width: 1440, height: 900)))
        XCTAssertFalse(
            CaptureSettings.LastArea(rect: CGRect(x: 0, y: 0, width: 0, height: 0), displayID: 1)
                .isUsable(on: CGRect(x: 0, y: 0, width: 1440, height: 900))
        )
    }

    /// 新增的五个热键不能和已有八个撞车，也不能重复。
    func testNewHotkeysAreUnique() {
        let combos = HotkeyAction.allCases.map { $0.defaultCombo }
        XCTAssertEqual(Set(combos.map { "\($0.keyCode)-\($0.modifiers)" }).count, combos.count)
    }
}

import XCTest
@testable import BatonCore

final class InputSourceResolverTests: XCTestCase {
    func testRuleWinsOverMemory() {
        let settings = InputSourceSettings(
            rules: ["com.apple.Terminal": "com.apple.keylayout.ABC"],
            memory: ["com.apple.Terminal": "com.apple.inputmethod.SCIM.ITABC"]
        )
        XCTAssertEqual(
            InputSourceResolver.target(for: "com.apple.Terminal", settings: settings),
            "com.apple.keylayout.ABC"
        )
    }

    func testFallsBackToMemory() {
        let settings = InputSourceSettings(memory: ["com.tencent.xinWeChat": "com.apple.inputmethod.SCIM.ITABC"])
        XCTAssertEqual(
            InputSourceResolver.target(for: "com.tencent.xinWeChat", settings: settings),
            "com.apple.inputmethod.SCIM.ITABC"
        )
    }

    func testNoRuleNoMemoryMeansHandsOff() {
        XCTAssertNil(InputSourceResolver.target(for: "com.foo.bar", settings: InputSourceSettings()))
    }

    func testEmptyRuleIsTreatedAsUnset() {
        let settings = InputSourceSettings(
            rules: ["com.foo.bar": ""],
            memory: ["com.foo.bar": "com.apple.keylayout.ABC"]
        )
        XCTAssertEqual(
            InputSourceResolver.target(for: "com.foo.bar", settings: settings),
            "com.apple.keylayout.ABC"
        )
    }
}

final class InputSourceStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-input-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testMissingFileReturnsDefaults() throws {
        let store = try InputSourceStore(directory: directory)
        let settings = store.load()
        XCTAssertTrue(settings.enabled)
        XCTAssertTrue(settings.rules.isEmpty)
        XCTAssertTrue(settings.memory.isEmpty)
    }

    func testRoundTrip() throws {
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings(enabled: false)
        settings.rules["com.apple.Terminal"] = "com.apple.keylayout.ABC"
        settings.memory["com.tencent.xinWeChat"] = "com.apple.inputmethod.SCIM.ITABC"
        try store.save(settings)

        let loaded = store.load()
        XCTAssertEqual(loaded, settings)
    }
}

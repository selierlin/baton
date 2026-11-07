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

    /// 忽略是最高优先级：连显式规则都不生效，否则用户勾了「忽略」还会被切走。
    func testIgnoredWinsOverRuleAndMemory() {
        let settings = InputSourceSettings(
            rules: ["com.apple.Terminal": "com.apple.keylayout.ABC"],
            memory: ["com.apple.Terminal": "com.apple.inputmethod.SCIM.ITABC"],
            ignored: ["com.apple.Terminal"]
        )
        XCTAssertNil(InputSourceResolver.target(for: "com.apple.Terminal", settings: settings))
        XCTAssertFalse(InputSourceResolver.shouldRemember("com.apple.Terminal", settings: settings))
    }

    func testOtherAppsStillWorkWhenOneIsIgnored() {
        let settings = InputSourceSettings(
            memory: ["com.apple.Terminal": "com.apple.keylayout.ABC"],
            ignored: ["com.jetbrains.intellij"]
        )
        XCTAssertEqual(
            InputSourceResolver.target(for: "com.apple.Terminal", settings: settings),
            "com.apple.keylayout.ABC"
        )
        XCTAssertTrue(InputSourceResolver.shouldRemember("com.apple.Terminal", settings: settings))
    }

    /// 地址栏比「这个 App 用什么」更具体：在 Chrome 里敲网址和在 Chrome 里写文档，期望的源不同。
    func testAddressBarWinsOverAppRule() {
        let settings = InputSourceSettings(
            rules: ["com.google.Chrome": "com.apple.inputmethod.SCIM.ITABC"],
            addressBarSourceID: "com.apple.keylayout.ABC"
        )
        XCTAssertEqual(
            InputSourceResolver.target(for: "com.google.Chrome", settings: settings, inAddressBar: true),
            "com.apple.keylayout.ABC"
        )
        XCTAssertEqual(
            InputSourceResolver.target(for: "com.google.Chrome", settings: settings, inAddressBar: false),
            "com.apple.inputmethod.SCIM.ITABC"
        )
    }

    func testAddressBarUnsetFallsBackToAppRule() {
        let settings = InputSourceSettings(rules: ["com.google.Chrome": "com.apple.inputmethod.SCIM.ITABC"])
        XCTAssertEqual(
            InputSourceResolver.target(for: "com.google.Chrome", settings: settings, inAddressBar: true),
            "com.apple.inputmethod.SCIM.ITABC"
        )
    }

    /// 勾了忽略的 App 连地址栏都不该碰：用户说过「完全不管这个 App」。
    func testIgnoredBeatsAddressBar() {
        let settings = InputSourceSettings(
            ignored: ["com.google.Chrome"],
            addressBarSourceID: "com.apple.keylayout.ABC"
        )
        XCTAssertNil(InputSourceResolver.target(for: "com.google.Chrome",
                                                settings: settings,
                                                inAddressBar: true))
    }
}

/// 设置页列表的排序：已配置的必须永远在最上面，否则 App 一多又要往下翻。
final class InputSourceRowOrderTests: XCTestCase {
    private func row(_ name: String,
                     rule: String? = nil,
                     ignored: Bool = false,
                     memory: String? = nil,
                     running: Bool = false) -> InputSourceRowModel {
        InputSourceRowModel(bundleID: "id.\(name)",
                            name: name,
                            ruleSourceID: rule,
                            isIgnored: ignored,
                            memorySourceID: memory,
                            isRunning: running)
    }

    func testConfiguredFirstThenRunningThenMemoryThenName() {
        let rows = [
            row("Zebra"),                       // 什么都没有
            row("WeChat", memory: "scim"),      // 记住过
            row("Xcode", running: true),        // 正在运行
            row("Terminal", rule: "abc"),       // 显式规则
            row("IntelliJ", ignored: true),     // 忽略也算配置过
            row("Alpha"),
        ]
        XCTAssertEqual(
            InputSourceRowModel.ordered(rows).map(\.name),
            ["IntelliJ", "Terminal", "Xcode", "WeChat", "Alpha", "Zebra"]
        )
    }

    func testManagedFilterExcludesUntouchedApps() {
        XCTAssertTrue(row("A", rule: "abc").isManaged)
        XCTAssertTrue(row("B", ignored: true).isManaged)
        XCTAssertTrue(row("C", memory: "scim").isManaged)
        XCTAssertTrue(row("D", running: true).isManaged)
        XCTAssertFalse(row("E").isManaged)
    }
}

/// 老版本的 input-source.json 只有三个键，升级后不能因为缺字段就退回默认配置。
final class InputSourceDecodingTests: XCTestCase {
    func testDecodesLegacyJSON() throws {
        let json = """
        {"enabled":false,"rules":{"a":"b"},"memory":{"c":"d"}}
        """
        let settings = try JSONDecoder().decode(InputSourceSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.rules["a"], "b")
        XCTAssertEqual(settings.memory["c"], "d")
        XCTAssertTrue(settings.ignored.isEmpty)
        XCTAssertEqual(settings.switchDelayMs, 0)
    }

    func testRoundTripKeepsNewFields() throws {
        var settings = InputSourceSettings()
        settings.ignored = ["com.apple.Terminal", "com.jetbrains.intellij"]
        settings.switchDelayMs = 100
        settings.addressBarSourceID = "com.apple.keylayout.ABC"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(InputSourceSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    /// 没配地址栏就不要往 JSON 里写 null，配置文件要能一眼看懂。
    func testUnsetAddressBarIsOmitted() throws {
        let data = try JSONEncoder().encode(InputSourceSettings())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("addressBarSourceID"))
        XCTAssertNil(try JSONDecoder().decode(InputSourceSettings.self, from: data).addressBarSourceID)
    }
}

/// 浏览器识别是纯字符串判断，能单测的那部分放这儿。
final class BrowserFocusReaderTests: XCTestCase {
    func testKnownBrowsersAreSupported() {
        XCTAssertTrue(BrowserFocusReader.isSupported("com.google.Chrome"))
        XCTAssertTrue(BrowserFocusReader.isSupported("com.apple.Safari"))
        XCTAssertTrue(BrowserFocusReader.isSupported("com.microsoft.edgemac"))
    }

    func testNonBrowsersAreNotSupported() {
        XCTAssertFalse(BrowserFocusReader.isSupported("com.apple.Terminal"))
        XCTAssertFalse(BrowserFocusReader.isSupported(nil))
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
        settings.ignored = ["com.jetbrains.intellij"]
        settings.switchDelayMs = 50
        try store.save(settings)

        let loaded = store.load()
        XCTAssertEqual(loaded, settings)
    }
}

/// 服务层的边界：延迟值要收敛，清记忆要真的落盘。
@MainActor
final class InputSourceServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-input-service-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testSwitchDelayIsClamped() throws {
        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.setSwitchDelay(9_999)
        XCTAssertEqual(service.switchDelayMs, 500)
        service.setSwitchDelay(-10)
        XCTAssertEqual(service.switchDelayMs, 0)
        service.setSwitchDelay(100)
        XCTAssertEqual(service.switchDelayMs, 100)
    }

    func testRulesAndIgnoredPersist() throws {
        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.setRule(bundleID: "com.apple.Terminal", sourceID: "com.apple.keylayout.ABC")
        XCTAssertEqual(service.rule(for: "com.apple.Terminal"), "com.apple.keylayout.ABC")

        service.setIgnored("com.apple.Terminal", true)
        XCTAssertTrue(service.isIgnored("com.apple.Terminal"))
        service.setIgnored("com.apple.Terminal", false)
        XCTAssertFalse(service.isIgnored("com.apple.Terminal"))

        // 重新读一份，确认没只改内存
        let reread = try InputSourceService(hub: EventHub(), directory: directory)
        XCTAssertEqual(reread.rule(for: "com.apple.Terminal"), "com.apple.keylayout.ABC")
    }

    func testClearMemory() throws {
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings()
        settings.memory["com.apple.Terminal"] = "com.apple.keylayout.ABC"
        try store.save(settings)

        let service = try InputSourceService(hub: EventHub(), directory: directory)
        XCTAssertEqual(service.memory.count, 1)
        service.clearMemory()
        XCTAssertTrue(service.memory.isEmpty)
        XCTAssertTrue(try InputSourceStore(directory: directory).load().memory.isEmpty)
    }
}

import XCTest
@testable import BatonCore

/// App 级输入框规则：钉钉的聊天框要中文、搜索框要英文，靠「bundle id + 输入框文案」区分。
/// 网站规则和 App 规则存在同一个数组里，这里重点验证两者不会互相串味。
@MainActor
final class AppFieldRuleTests: XCTestCase {
    private let dingTalk = "com.alibaba.DingTalkMac"
    private let pinyin = "com.apple.inputmethod.SCIM.ITABC"
    private let abc = "com.apple.keylayout.ABC"

    // MARK: - 匹配

    func testMatchesTheRightFieldInOneApp() {
        let rules = [
            SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc),
            SiteRule(app: dingTalk, keyword: "输入消息", sourceID: pinyin),
        ]
        XCTAssertEqual(SiteRuleMatcher.match(app: dingTalk, label: "搜索", rules: rules)?.sourceID, abc)
        XCTAssertEqual(SiteRuleMatcher.match(app: dingTalk, label: "输入消息…", rules: rules)?.sourceID, pinyin)
    }

    /// 关键字是「包含」匹配，文案里带补充说明也要命中
    func testKeywordMatchesInsideLongerLabel() {
        let rules = [SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc)]
        XCTAssertEqual(
            SiteRuleMatcher.match(app: dingTalk, label: "搜索联系人、群聊、消息记录", rules: rules)?.sourceID,
            abc
        )
    }

    func testDoesNotLeakAcrossApps() {
        let rules = [SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc)]
        XCTAssertNil(SiteRuleMatcher.match(app: "com.tencent.xinWeChat", label: "搜索", rules: rules))
    }

    func testAppFieldWithoutReadableLabelDoesNotMatch() {
        let rules = [SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc)]
        XCTAssertNil(SiteRuleMatcher.match(app: dingTalk, label: nil, rules: rules))
        XCTAssertNil(SiteRuleMatcher.match(app: dingTalk, label: "", rules: rules))
    }

    /// 同一个 App 里配了整 App 规则和某个框的规则时，带关键字的优先
    func testFieldRuleBeatsAppWideRule() {
        let rules = [
            SiteRule(app: dingTalk, keyword: nil, sourceID: pinyin),
            SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc),
        ]
        let hit = SiteRuleMatcher.match(app: dingTalk, label: "搜索", rules: rules)
        XCTAssertEqual(hit?.sourceID, abc)
        XCTAssertEqual(hit?.keyword, "搜索")
    }

    // MARK: - 解析优先级

    func testAppFieldRuleBeatsAppRuleAndMemory() {
        let settings = InputSourceSettings(
            rules: [dingTalk: pinyin],
            memory: [dingTalk: pinyin],
            siteRules: [SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc)]
        )
        XCTAssertEqual(
            InputSourceResolver.target(for: dingTalk, settings: settings, fieldLabel: "搜索"),
            abc
        )
        // 焦点不在搜索框时退回 App 规则
        XCTAssertEqual(
            InputSourceResolver.target(for: dingTalk, settings: settings, fieldLabel: nil),
            pinyin
        )
    }

    /// 网站规则和 App 规则同时能命中时，网站更具体（它只在网页里成立）
    func testSiteRuleWinsWhenHostIsPresent() {
        let settings = InputSourceSettings(siteRules: [
            SiteRule(host: "github.com", keyword: "搜索", sourceID: pinyin),
            SiteRule(app: "com.google.Chrome", keyword: "搜索", sourceID: abc),
        ])
        XCTAssertEqual(
            InputSourceResolver.target(for: "com.google.Chrome",
                                       settings: settings,
                                       host: "github.com",
                                       fieldLabel: "搜索"),
            pinyin
        )
    }

    func testIgnoredAppSkipsFieldRule() {
        let settings = InputSourceSettings(
            ignored: [dingTalk],
            siteRules: [SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc)]
        )
        XCTAssertNil(InputSourceResolver.target(for: dingTalk, settings: settings, fieldLabel: "搜索"))
    }

    // MARK: - 学习

    func testAppFieldNeedsTwoSightings() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try InputSourceService(hub: EventHub(), directory: directory)

        let field = BrowserContext(kind: .field, host: nil, label: "搜索")
        let first = Date()
        service.recordLearn(context: field, key: dingTalk, sourceID: abc, now: first)
        XCTAssertTrue(service.siteRules.isEmpty)
        XCTAssertEqual(service.learnCandidates.first?.hits, 1)
        XCTAssertEqual(service.learnCandidates.first?.app, dingTalk)

        service.recordLearn(context: field, key: dingTalk, sourceID: abc,
                            now: first.addingTimeInterval(60))
        XCTAssertEqual(service.siteRules.count, 1)
        XCTAssertEqual(service.siteRules.first?.app, dingTalk)
        XCTAssertEqual(service.siteRules.first?.host, "")
        XCTAssertEqual(service.siteRules.first?.keyword, "搜索")
        XCTAssertEqual(service.siteRules.first?.learned, true)
        XCTAssertTrue(service.learnCandidates.isEmpty)

        // 落盘后仍然能解出来
        let reread = try InputSourceService(hub: EventHub(), directory: directory)
        XCTAssertEqual(reread.siteRules.first?.app, dingTalk)
    }

    func testAppFieldWithoutLabelIsNotLearned() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try InputSourceService(hub: EventHub(), directory: directory)

        service.recordLearn(context: BrowserContext(kind: .field, host: nil, label: nil),
                            key: dingTalk, sourceID: abc)
        XCTAssertTrue(service.learnCandidates.isEmpty)
        XCTAssertTrue(service.siteRules.isEmpty)
    }

    /// 没有 key（普通 App 但拿不到 bundle id）时不猜作用域
    func testFieldWithoutScopeIsIgnored() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try InputSourceService(hub: EventHub(), directory: directory)

        service.recordLearn(context: BrowserContext(kind: .field, host: nil, label: "搜索"),
                            sourceID: abc)
        XCTAssertTrue(service.learnCandidates.isEmpty)
    }

    func testTwoAppsLearnIndependently() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try InputSourceService(hub: EventHub(), directory: directory)

        let field = BrowserContext(kind: .field, host: nil, label: "搜索")
        let now = Date()
        service.recordLearn(context: field, key: dingTalk, sourceID: abc, now: now)
        service.recordLearn(context: field, key: dingTalk, sourceID: abc, now: now.addingTimeInterval(60))
        service.recordLearn(context: field, key: "com.tencent.xinWeChat", sourceID: abc, now: now)

        XCTAssertEqual(service.learnCandidates.count, 1)
        XCTAssertEqual(service.learnCandidates.first?.app, "com.tencent.xinWeChat")
        XCTAssertEqual(service.siteRules.count, 1)
        XCTAssertEqual(service.siteRules.first?.app, dingTalk)
    }

    /// 手工配了同一个 App 的同一个框，攒了一半的候选就作废
    func testManualAppRuleDropsCandidate() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings()
        settings.learnCandidates = [
            SiteRuleCandidate(app: dingTalk, keyword: "搜索", sourceID: abc),
            SiteRuleCandidate(app: dingTalk, keyword: "输入消息", sourceID: pinyin),
        ]
        try store.save(settings)

        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.addSiteRule(SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc))
        XCTAssertEqual(service.learnCandidates.map(\.keyword), ["输入消息"])
        XCTAssertEqual(service.appFieldRules.count, 1)
        XCTAssertEqual(service.appFieldRules.first?.app, dingTalk)
    }

    /// 网站候选不会被 App 规则的添加顺手清掉（作用域不同）
    func testAddingAppRuleLeavesSiteCandidateAlone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings()
        settings.learnCandidates = [SiteRuleCandidate(host: "github.com", keyword: "搜索", sourceID: abc)]
        try store.save(settings)

        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.addSiteRule(SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc))
        XCTAssertEqual(service.learnCandidates.count, 1)
        XCTAssertEqual(service.learnCandidates.first?.host, "github.com")
    }

    // MARK: - 归一化与清理

    func testNormalizeMergesLearnedAppRulesOfSameField() {
        var rules = [
            SiteRule(app: dingTalk, keyword: "输入消息", sourceID: pinyin, learned: true,
                     createdAt: Date(timeIntervalSince1970: 100)),
            SiteRule(app: dingTalk, keyword: "输入消息，@ 选择人", sourceID: pinyin, learned: true,
                     createdAt: Date(timeIntervalSince1970: 200)),
        ]
        SiteRuleLearning.normalizeLearned(&rules)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.keyword, "输入消息")
        XCTAssertEqual(rules.first?.createdAt, Date(timeIntervalSince1970: 100))
    }

    func testNormalizeKeepsSiteAndAppRulesSeparate() {
        var rules = [
            SiteRule(host: "search", keyword: "搜索", sourceID: abc, learned: true),
            SiteRule(app: "search", keyword: "搜索", sourceID: pinyin, learned: true),
        ]
        SiteRuleLearning.normalizeLearned(&rules)
        XCTAssertEqual(rules.count, 2)
    }

    func testCoveredAppCandidateIsDropped() {
        var candidates = [
            SiteRuleCandidate(app: dingTalk, keyword: "搜索", sourceID: abc),
            SiteRuleCandidate(app: dingTalk, keyword: "搜索", sourceID: pinyin),
        ]
        SiteRuleLearning.dropCandidatesCoveredBy(
            [SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc, learned: true)],
            &candidates
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.sourceID, pinyin)
    }

    func testPruneDropsStaleLearnedAppRule() {
        var rules = [
            SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc, learned: true,
                     createdAt: Date().addingTimeInterval(-70 * 24 * 3600)),
            SiteRule(app: dingTalk, keyword: "输入消息", sourceID: pinyin),
        ]
        let removed = SiteRuleLearning.pruneStale(&rules)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.keyword, "输入消息")
    }

    /// 同一个 App 的同一个框再加一次 = 改源，不会长出两行
    func testAddingSameAppFieldTwiceReplacesSource() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try InputSourceService(hub: EventHub(), directory: directory)

        service.addSiteRule(SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc))
        service.addSiteRule(SiteRule(app: dingTalk, keyword: "搜索", sourceID: pinyin))
        XCTAssertEqual(service.siteRules.count, 1)
        XCTAssertEqual(service.siteRules.first?.sourceID, pinyin)
    }

    // MARK: - 编解码

    func testAppRuleRoundTrip() throws {
        let rule = SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc, learned: true)
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(SiteRule.self, from: data)
        XCTAssertEqual(decoded, rule)
    }

    /// 老配置里没有 app 字段，必须还能当网站规则读出来
    func testLegacyRuleWithoutAppDecodesAsSiteRule() throws {
        let json = """
        {"host":"github.com","keyword":"搜索","sourceID":"abc"}
        """.data(using: .utf8)!
        let rule = try JSONDecoder().decode(SiteRule.self, from: json)
        XCTAssertNil(rule.app)
        XCTAssertTrue(rule.isAppRule == false)
        XCTAssertEqual(rule.id, "github.com|搜索")
    }

    func testAppRuleIDIsScoped() {
        let rule = SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc)
        XCTAssertEqual(rule.id, "app:com.alibaba.DingTalkMac|搜索")
        XCTAssertEqual(rule.scope, "app:com.alibaba.DingTalkMac")
        XCTAssertEqual(rule.displayKeyword, "搜索")
    }

    /// 读不到文案的框（钉钉聊天框）只能落到整 App 规则上，这也是它唯一能配的形态
    func testAppWideRuleCoversUnlabelledField() {
        let rules = [
            SiteRule(app: dingTalk, keyword: nil, sourceID: pinyin),
            SiteRule(app: dingTalk, keyword: "搜索", sourceID: abc),
        ]
        XCTAssertEqual(SiteRuleMatcher.match(app: dingTalk, label: nil, rules: rules)?.sourceID, pinyin)
        XCTAssertEqual(SiteRuleMatcher.match(app: dingTalk, label: "", rules: rules)?.sourceID, pinyin)
    }

    // MARK: - 文案消失 vs 换了输入框

    /// placeholder 有字就消失：还是同一个框，保持现状，别把用户打了一半的字弹回默认源
    func testKeepsSourceWhenPlaceholderVanishesInSameField() {
        let context = BrowserContext(kind: .field, label: nil, fieldKey: "42")
        XCTAssertTrue(InputSourceService.keepsCurrentSource(context: context,
                                                           suppressMemory: true,
                                                           lastFieldKey: "42"))
    }

    /// 换到另一个读不到文案的框（钉钉聊天框）：必须重新判断，「整 App」规则才有机会生效
    func testSwitchesWhenMovingToAnotherUnlabelledField() {
        let context = BrowserContext(kind: .field, label: nil, fieldKey: "77")
        XCTAssertFalse(InputSourceService.keepsCurrentSource(context: context,
                                                            suppressMemory: true,
                                                            lastFieldKey: "42"))
    }

    /// 读不到元素身份时按老办法保守处理：宁可少切一次，也别把用户打的字弹回默认源
    func testKeepsSourceWhenFieldIdentityIsUnknown() {
        let context = BrowserContext(kind: .field, label: nil, fieldKey: nil)
        XCTAssertTrue(InputSourceService.keepsCurrentSource(context: context,
                                                           suppressMemory: true,
                                                           lastFieldKey: "42"))
    }

    /// 有文案就正常走规则，跟身份无关
    func testLabelledFieldIsNeverSuppressed() {
        let context = BrowserContext(kind: .field, label: "搜索", fieldKey: "42")
        XCTAssertFalse(InputSourceService.keepsCurrentSource(context: context,
                                                            suppressMemory: true,
                                                            lastFieldKey: "42"))
    }

    func testSuppressionOnlyAppliesInsideARuleScope() {
        let context = BrowserContext(kind: .field, label: nil, fieldKey: "42")
        XCTAssertFalse(InputSourceService.keepsCurrentSource(context: context,
                                                            suppressMemory: false,
                                                            lastFieldKey: "42"))
    }

    // MARK: - 焦点抖动不切源

    /// 输入框里打字时 Chrome 偶尔读不到焦点：报 page / unknown 不该把源弹回去
    func testPageAndUnknownContextsAreLeftAlone() {
        XCTAssertTrue(InputSourceService.keepsSourceOutsideField(BrowserContext(kind: .page),
                                                                 inAddressBar: false))
        XCTAssertTrue(InputSourceService.keepsSourceOutsideField(BrowserContext(kind: .unknown),
                                                                 inAddressBar: false))
    }

    /// 输入框和地址栏照旧判定
    func testFieldAndAddressBarAreNotLeftAlone() {
        XCTAssertFalse(InputSourceService.keepsSourceOutsideField(BrowserContext(kind: .field),
                                                                  inAddressBar: false))
        XCTAssertFalse(InputSourceService.keepsSourceOutsideField(BrowserContext(kind: .addressBar),
                                                                  inAddressBar: false))
    }

    /// 地址栏状态下的 page 交给原逻辑：进出地址栏是真实变化
    func testPageInsideAddressBarStillEvaluates() {
        XCTAssertFalse(InputSourceService.keepsSourceOutsideField(BrowserContext(kind: .page),
                                                                  inAddressBar: true))
    }

    // MARK: - 辅助

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-app-rule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

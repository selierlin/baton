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

    /// 网站规则比 App 规则具体：GitHub 里写中文评论，不该把整站英文的设定推翻。
    func testSiteRuleWinsOverAppRule() {
        let settings = InputSourceSettings(
            rules: ["com.google.Chrome": "com.apple.keylayout.ABC"],
            siteRules: [SiteRule(host: "github.com", keyword: "写评论", sourceID: "pinyin")]
        )
        XCTAssertEqual(
            InputSourceResolver.target(for: "com.google.Chrome",
                                       settings: settings,
                                       host: "github.com",
                                       fieldLabel: "写评论…"),
            "pinyin"
        )
        XCTAssertEqual(
            InputSourceResolver.target(for: "com.google.Chrome",
                                       settings: settings,
                                       host: "github.com",
                                       fieldLabel: "Search"),
            "com.apple.keylayout.ABC"
        )
    }

    /// 地址栏优先于网站规则：敲网址永远是 ASCII 动作。
    func testAddressBarBeatsSiteRule() {
        let settings = InputSourceSettings(
            addressBarSourceID: "com.apple.keylayout.ABC",
            siteRules: [SiteRule(host: "github.com", sourceID: "pinyin")]
        )
        XCTAssertEqual(
            InputSourceResolver.target(for: "com.google.Chrome",
                                       settings: settings,
                                       inAddressBar: true,
                                       host: "github.com"),
            "com.apple.keylayout.ABC"
        )
    }

    func testIgnoredBeatsSiteRule() {
        let settings = InputSourceSettings(
            ignored: ["com.google.Chrome"],
            siteRules: [SiteRule(host: "github.com", sourceID: "pinyin")]
        )
        XCTAssertNil(InputSourceResolver.target(for: "com.google.Chrome",
                                                settings: settings,
                                                host: "github.com"))
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

/// 网站规则的匹配逻辑：域名收敛、子域、关键字优先级。
final class SiteRuleMatcherTests: XCTestCase {
    func testNormalizeHostFromAddressBarValue() {
        // 地址栏给的就是这种：没有 scheme，带端口和路径
        XCTAssertEqual(SiteRuleMatcher.normalizeHost("dev-box.example.com:8443/session/abc"),
                       "dev-box.example.com")
        XCTAssertEqual(SiteRuleMatcher.normalizeHost("https://GitHub.com/selierlin/baton"),
                       "github.com")
        XCTAssertEqual(SiteRuleMatcher.normalizeHost("www.google.com"), "google.com")
        XCTAssertEqual(SiteRuleMatcher.normalizeHost("  localhost:3000  "), "localhost")
        XCTAssertNil(SiteRuleMatcher.normalizeHost(""))
        XCTAssertNil(SiteRuleMatcher.normalizeHost(nil))
    }

    func testSubdomainMatches() {
        XCTAssertTrue(SiteRuleMatcher.hostMatches("gist.github.com", ruleHost: "github.com"))
        XCTAssertTrue(SiteRuleMatcher.hostMatches("github.com", ruleHost: "github.com"))
        // 别把 notgithub.com 当成 github.com
        XCTAssertFalse(SiteRuleMatcher.hostMatches("notgithub.com", ruleHost: "github.com"))
    }

    func testKeywordRuleOnlyAppliesToMatchingField() {
        let rules = [
            SiteRule(host: "github.com", sourceID: "abc"),
            SiteRule(host: "github.com", keyword: "写评论", sourceID: "pinyin"),
        ]
        XCTAssertEqual(SiteRuleMatcher.match(host: "github.com", label: nil, rules: rules)?.sourceID, "abc")
        XCTAssertEqual(SiteRuleMatcher.match(host: "github.com", label: "写评论…", rules: rules)?.sourceID, "pinyin")
        XCTAssertEqual(SiteRuleMatcher.match(host: "github.com", label: "Search", rules: rules)?.sourceID, "abc")
    }

    func testLongerHostWins() {
        let rules = [
            SiteRule(host: "google.com", sourceID: "abc"),
            SiteRule(host: "docs.google.com", sourceID: "pinyin"),
        ]
        XCTAssertEqual(SiteRuleMatcher.match(host: "docs.google.com", label: nil, rules: rules)?.sourceID, "pinyin")
    }

    func testNoHostNoMatch() {
        let rules = [SiteRule(host: "github.com", sourceID: "abc")]
        XCTAssertNil(SiteRuleMatcher.match(host: nil, label: "写评论", rules: rules))
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

    func testLegacyJSONHasNoSiteRules() throws {
        let json = """
        {"enabled":true,"rules":{},"memory":{},"addressBarSourceID":"com.apple.keylayout.ABC"}
        """
        let settings = try JSONDecoder().decode(InputSourceSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.siteRules.isEmpty)
    }

    func testSiteRulesRoundTrip() throws {
        var settings = InputSourceSettings()
        settings.siteRules = [
            SiteRule(host: "github.com", sourceID: "abc"),
            SiteRule(host: "github.com", keyword: "写评论", sourceID: "pinyin"),
        ]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(InputSourceSettings.self, from: data)
        XCTAssertEqual(decoded.siteRules, settings.siteRules)
    }

    /// 学习默认开着，老配置读进来也应当是开着的。
    func testLegacyJSONLearnsByDefault() throws {
        let settings = try JSONDecoder().decode(InputSourceSettings.self,
                                               from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertTrue(settings.learningEnabled)
        XCTAssertTrue(settings.learnCandidates.isEmpty)
    }

    /// 开着是常态，不该每份配置都多一行 true。
    func testLearningEnabledIsOmittedWhenOn() throws {
        let text = String(decoding: try JSONEncoder().encode(InputSourceSettings()), as: UTF8.self)
        XCTAssertFalse(text.contains("learningEnabled"))
    }

    func testLearnCandidatesRoundTrip() throws {
        var settings = InputSourceSettings()
        settings.learningEnabled = false
        settings.learnCandidates = [
            SiteRuleCandidate(host: "github.com", keyword: "写评论", sourceID: "pinyin"),
        ]
        let decoded = try JSONDecoder().decode(InputSourceSettings.self,
                                               from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.learningEnabled)
        XCTAssertEqual(decoded.learnCandidates, settings.learnCandidates)
    }
}

/// 自动学习：攒次数、覆盖择新、清掉过期候选。
final class SiteRuleLearningTests: XCTestCase {
    func testKeywordIsNormalized() {
        XCTAssertEqual(SiteRuleLearning.keyword(from: "  写评论… \n"), "写评论…")
        // 换行算分隔符：取第一行，后半句常常是随产品名变动的补充说明
        XCTAssertEqual(SiteRuleLearning.keyword(from: "多行\nplaceholder\t文案"), "多行")
        XCTAssertEqual(SiteRuleLearning.keyword(from: "搜索  多个   空格"), "搜索 多个 空格")
        XCTAssertNil(SiteRuleLearning.keyword(from: "   "))
        XCTAssertNil(SiteRuleLearning.keyword(from: nil))
    }

    /// 真正踩过的坑：整段 placeholder 里带产品名，改名就多一条规则出来。
    func testKeywordStopsAtFirstClause() {
        let labels = [
            "输入 / 调用命令，@ 选择文件，或向 DeepSeek Harness 提问.",
            "输入 / 调用命令，@ 选择文件，或向 Pi 提问...",
            "输入 / 调用命令，@ 选择文件，或向 WorkBuddy 提问...",
        ]
        let keywords = labels.map { SiteRuleLearning.keyword(from: $0) }
        XCTAssertEqual(keywords, ["输入 / 调用命令", "输入 / 调用命令", "输入 / 调用命令"])
    }

    /// 三条同框不同文案的老规则，启动时归一成一条，时间戳取历史的最早/最晚。
    func testNormalizeMergesDuplicateLearnedRules() {
        let old = Date().addingTimeInterval(-10 * 24 * 3600)
        var rules = [
            SiteRule(host: "dev-box.example.com",
                     keyword: "输入 / 调用命令，@ 选择文件，或向 Pi 提问...",
                     sourceID: "doubao", learned: true, createdAt: old),
            SiteRule(host: "dev-box.example.com",
                     keyword: "输入 / 调用命令，@ 选择文件，或向 WorkBuddy 提问...",
                     sourceID: "doubao", learned: true, createdAt: Date(), lastUsed: Date()),
            SiteRule(host: "mp.lemobar.com", keyword: "⌘ + K", sourceID: "abc", learned: true),
        ]
        SiteRuleLearning.normalizeLearned(&rules)
        XCTAssertEqual(rules.count, 2)
        let merged = rules.first { $0.host == "dev-box.example.com" }
        XCTAssertEqual(merged?.keyword, "输入 / 调用命令")
        XCTAssertEqual(merged?.createdAt, old)
        XCTAssertNotNil(merged?.lastUsed)
    }

    /// 手工规则不参与归一：关键字是用户自己写的，改了就不是他的意思了。
    func testNormalizeLeavesManualRulesAlone() {
        var rules = [SiteRule(host: "github.com", keyword: "写评论，仅此一处", sourceID: "pinyin")]
        SiteRuleLearning.normalizeLearned(&rules)
        XCTAssertEqual(rules.first?.keyword, "写评论，仅此一处")
    }

    func testNormalizeMergesCandidates() {
        var candidates = [
            SiteRuleCandidate(host: "a.com", keyword: "搜索，补充说明一", sourceID: "abc"),
            SiteRuleCandidate(host: "a.com", keyword: "搜索，补充说明二", sourceID: "abc"),
        ]
        SiteRuleLearning.normalizeCandidates(&candidates)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.keyword, "搜索")
        XCTAssertEqual(candidates.first?.hits, 2)
    }

    /// 已经有规则的框不再攒候选，换了个源的候选要留着（那是新意图）。
    func testCandidatesCoveredByRuleAreDropped() {
        let rules = [SiteRule(host: "a.com", keyword: "搜索", sourceID: "abc", learned: true)]
        var candidates = [
            SiteRuleCandidate(host: "a.com", keyword: "搜索", sourceID: "abc"),
            SiteRuleCandidate(host: "a.com", keyword: "搜索", sourceID: "pinyin"),
        ]
        SiteRuleLearning.dropCandidatesCoveredBy(rules, &candidates)
        XCTAssertEqual(candidates.map(\.sourceID), ["pinyin"])
    }

    /// 同一个框的两条规则，关键字常常是前缀关系，要认成同一个框。
    func testSameFieldMatchesByKeywordContainment() {
        let manual = SiteRule(host: "a.com", keyword: "输入 / 调用命令，@ 选择文件，或向 X 提问...",
                              sourceID: "abc")
        let learned = SiteRule(host: "www.a.com", keyword: "输入 / 调用命令", sourceID: "abc")
        XCTAssertTrue(SiteRuleMatcher.sameField(manual, learned))
        XCTAssertFalse(SiteRuleMatcher.sameField(
            SiteRule(host: "a.com", keyword: "搜索", sourceID: "abc"),
            SiteRule(host: "a.com", keyword: "写评论", sourceID: "abc")))
        XCTAssertFalse(SiteRuleMatcher.sameField(
            SiteRule(host: "a.com", sourceID: "abc"),
            SiteRule(host: "a.com", keyword: "搜索", sourceID: "abc")))
    }

    /// 同一个框、同一个源的手工 + 自动两条，启动时留手工那条。
    func testNormalizeDropsLearnedShadowedByManual() {
        var rules = [
            SiteRule(host: "a.com", keyword: "输入 / 调用命令，@ 选择文件，或向 X 提问...",
                     sourceID: "abc"),
            SiteRule(host: "a.com", keyword: "输入 / 调用命令", sourceID: "abc",
                     learned: true, createdAt: Date()),
        ]
        SiteRuleLearning.normalizeLearned(&rules)
        XCTAssertEqual(rules.count, 1)
        XCTAssertNil(rules.first?.learned)
    }

    /// 长 placeholder 截到固定长度，截的是尾巴，前缀还在，`contains` 匹配照旧成立。
    func testLongKeywordIsTruncated() {
        let label = String(repeating: "搜", count: 100)
        let keyword = SiteRuleLearning.keyword(from: label)
        XCTAssertEqual(keyword?.count, SiteRuleLearning.maxKeywordLength)
    }

    func testFirstSightingOnlyRecordsCandidate() {
        var candidates: [SiteRuleCandidate] = []
        let rule = SiteRuleLearning.record(host: "github.com", keyword: "写评论", sourceID: "pinyin",
                                           candidates: &candidates)
        XCTAssertNil(rule)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.hits, 1)
    }

    func testSecondSightingCreatesRuleAndClearsCandidate() {
        var candidates: [SiteRuleCandidate] = []
        SiteRuleLearning.record(host: "github.com", keyword: "写评论", sourceID: "pinyin",
                                candidates: &candidates)
        let rule = SiteRuleLearning.record(host: "github.com", keyword: "写评论", sourceID: "pinyin",
                                           candidates: &candidates)
        XCTAssertEqual(rule?.sourceID, "pinyin")
        XCTAssertEqual(rule?.keyword, "写评论")
        XCTAssertTrue(candidates.isEmpty)
    }

    /// 主机要收敛成域名：AX 读到的是不带 scheme 的，用户手填的会带。
    func testHostIsNormalized() {
        var candidates: [SiteRuleCandidate] = []
        SiteRuleLearning.record(host: "https://www.GitHub.com/selierlin", keyword: "写评论", sourceID: "pinyin",
                                candidates: &candidates)
        XCTAssertEqual(candidates.first?.host, "github.com")
    }

    /// 同一个框换了另一个源：旧候选作废，别让两个源各攒一半永远攒不满。
    func testSwitchingSourceDropsCompetingCandidate() {
        var candidates: [SiteRuleCandidate] = []
        SiteRuleLearning.record(host: "github.com", keyword: "写评论", sourceID: "pinyin",
                                candidates: &candidates)
        let rule = SiteRuleLearning.record(host: "github.com", keyword: "写评论", sourceID: "abc",
                                           candidates: &candidates)
        XCTAssertNil(rule)
        XCTAssertEqual(candidates.map(\.sourceID), ["abc"])
    }

    /// 不同输入框各算各的：同一个网站两个框，不能合并成一个。
    func testDifferentFieldsAreIndependent() {
        var candidates: [SiteRuleCandidate] = []
        SiteRuleLearning.record(host: "github.com", keyword: "写评论", sourceID: "pinyin",
                                candidates: &candidates)
        let rule = SiteRuleLearning.record(host: "github.com", keyword: "搜索", sourceID: "pinyin",
                                           candidates: &candidates)
        XCTAssertNil(rule)
        XCTAssertEqual(candidates.count, 2)
    }

    func testStaleCandidatesExpire() {
        var candidates = [
            SiteRuleCandidate(host: "github.com", keyword: "写评论", sourceID: "pinyin",
                              hits: 1, lastSeen: Date(timeIntervalSinceNow: -SiteRuleLearning.expiry - 60)),
        ]
        SiteRuleLearning.expire(&candidates)
        XCTAssertTrue(candidates.isEmpty)
    }

    /// 候选有上限，攒不满的不能无限占着配置。
    func testCandidatesAreCapped() {
        var candidates: [SiteRuleCandidate] = []
        for index in 0..<(SiteRuleLearning.maxCandidates + 10) {
            SiteRuleLearning.record(host: "site\(index).com", keyword: "框\(index)", sourceID: "abc",
                                    candidates: &candidates)
        }
        XCTAssertEqual(candidates.count, SiteRuleLearning.maxCandidates)
    }

    // MARK: - 启动清理

    private func days(_ count: Double) -> Date {
        Date().addingTimeInterval(-count * 24 * 3600)
    }

    /// 两个月没命中的自动规则要清掉：多半是当时临时用的站点。
    func testPruneDropsLearnedRuleUnusedForTwoMonths() {
        var rules = [SiteRule(host: "temp.example", keyword: "搜索", sourceID: "abc",
                              learned: true, createdAt: days(70), lastUsed: nil)]
        let removed = SiteRuleLearning.pruneStale(&rules)
        XCTAssertEqual(removed.count, 1)
        XCTAssertTrue(rules.isEmpty)
    }

    /// 一个月才打开一次的站点（账单、后台）不能被清：这就是阈值定 60 天的原因。
    func testPruneKeepsMonthlySite() {
        var rules = [SiteRule(host: "bill.example", keyword: "搜索", sourceID: "abc",
                              learned: true, createdAt: days(200), lastUsed: days(31))]
        XCTAssertTrue(SiteRuleLearning.pruneStale(&rules).isEmpty)
        XCTAssertEqual(rules.count, 1)
    }

    /// 建了两个月但上周刚用过 → 留。
    func testPruneKeepsRecentlyUsedRule() {
        var rules = [SiteRule(host: "github.com", keyword: "写评论", sourceID: "pinyin",
                              learned: true, createdAt: days(60), lastUsed: days(5))]
        XCTAssertTrue(SiteRuleLearning.pruneStale(&rules).isEmpty)
        XCTAssertEqual(rules.count, 1)
    }

    /// 手工配的永远不动，哪怕几年没用。
    func testPruneNeverTouchesManualRule() {
        var rules = [SiteRule(host: "github.com", keyword: "写评论", sourceID: "pinyin",
                              learned: nil, createdAt: days(400), lastUsed: days(400))]
        XCTAssertTrue(SiteRuleLearning.pruneStale(&rules).isEmpty)
        XCTAssertEqual(rules.count, 1)
    }

    /// 没有时间戳老数据判断不了，先留着，别猜着删。
    func testPruneKeepsRuleWithoutTimestamps() {
        var rules = [SiteRule(host: "github.com", keyword: "写评论", sourceID: "pinyin", learned: true)]
        XCTAssertTrue(SiteRuleLearning.pruneStale(&rules).isEmpty)
    }
}

/// 浏览器识别是纯字符串判断，能单测的那部分放这儿。
final class BrowserContextReaderTests: XCTestCase {
    func testKnownBrowsersAreSupported() {
        XCTAssertTrue(BrowserContextReader.isSupported("com.google.Chrome"))
        XCTAssertTrue(BrowserContextReader.isSupported("com.apple.Safari"))
        XCTAssertTrue(BrowserContextReader.isSupported("com.microsoft.edgemac"))
    }

    func testNonBrowsersAreNotSupported() {
        XCTAssertFalse(BrowserContextReader.isSupported("com.apple.Terminal"))
        XCTAssertFalse(BrowserContextReader.isSupported(nil))
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

    /// 关掉自动学习要把候选清掉：留着不学只会让下次打开看到一堆陈年记录。
    func testDisablingLearningClearsCandidates() throws {
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings()
        settings.learnCandidates = [
            SiteRuleCandidate(host: "github.com", keyword: "写评论", sourceID: "pinyin"),
        ]
        try store.save(settings)

        let service = try InputSourceService(hub: EventHub(), directory: directory)
        XCTAssertTrue(service.isLearningEnabled)
        XCTAssertEqual(service.learnCandidates.count, 1)

        service.setLearning(false)
        XCTAssertFalse(service.isLearningEnabled)
        XCTAssertTrue(service.learnCandidates.isEmpty)
        let reread = try InputSourceStore(directory: directory).load()
        XCTAssertFalse(reread.learningEnabled)
        XCTAssertTrue(reread.learnCandidates.isEmpty)
    }

    /// 手工配了同一个输入框，学习记录就作废，否则重复两次会把手工的覆盖掉。
    func testManualRuleDropsCandidateForSameField() throws {
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings()
        settings.learnCandidates = [
            SiteRuleCandidate(host: "github.com", keyword: "写评论", sourceID: "pinyin"),
            SiteRuleCandidate(host: "github.com", keyword: "搜索", sourceID: "pinyin"),
        ]
        try store.save(settings)

        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.addSiteRule(SiteRule(host: "github.com", keyword: "写评论", sourceID: "abc"))
        XCTAssertEqual(service.learnCandidates.map(\.keyword), ["搜索"])
        XCTAssertEqual(service.siteRules.first?.sourceID, "abc")
    }

    /// 同一个输入框第二次出现就落规则，而且写进配置——重启后还在。
    func testTwoSightingsCreatePersistedRule() throws {
        let service = try InputSourceService(hub: EventHub(), directory: directory)
        let field = BrowserContext(kind: .field, host: "github.com", label: "写评论…")
        let first = Date()

        service.recordLearn(context: field, sourceID: "pinyin", now: first)
        XCTAssertTrue(service.siteRules.isEmpty)
        XCTAssertEqual(service.learnCandidates.first?.hits, 1)

        service.recordLearn(context: field, sourceID: "pinyin", now: first.addingTimeInterval(60))
        XCTAssertEqual(service.siteRules.count, 1)
        XCTAssertEqual(service.siteRules.first?.sourceID, "pinyin")
        XCTAssertEqual(service.siteRules.first?.learned, true)
        XCTAssertEqual(service.siteRules.first?.createdAt, first.addingTimeInterval(60))
        XCTAssertTrue(service.learnCandidates.isEmpty)

        let reread = try InputSourceService(hub: EventHub(), directory: directory)
        XCTAssertEqual(reread.siteRules.count, 1)
        XCTAssertTrue(reread.learnCandidates.isEmpty)
    }

    /// 只学输入框：网页正文、地址栏、没有文案的框都不该留下候选。
    func testNonFieldContextsAreIgnored() throws {
        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.recordLearn(context: BrowserContext(kind: .page, host: "github.com"), sourceID: "pinyin")
        service.recordLearn(context: BrowserContext(kind: .addressBar), sourceID: "pinyin")
        service.recordLearn(context: BrowserContext(kind: .field, host: "github.com", label: "  "),
                            sourceID: "pinyin")
        XCTAssertTrue(service.learnCandidates.isEmpty)
        XCTAssertTrue(service.siteRules.isEmpty)
    }

    /// Chrome 换源偶尔连发两条通知：1 秒内同一条记录只算一次，不然一次手动切换就攒满了。
    func testDuplicateNotificationWithinOneSecondCountsOnce() throws {
        let service = try InputSourceService(hub: EventHub(), directory: directory)
        let field = BrowserContext(kind: .field, host: "github.com", label: "写评论")
        let first = Date()
        service.recordLearn(context: field, sourceID: "pinyin", now: first)
        service.recordLearn(context: field, sourceID: "pinyin", now: first.addingTimeInterval(0.05))
        XCTAssertTrue(service.siteRules.isEmpty)
        XCTAssertEqual(service.learnCandidates.first?.hits, 1)
    }

    // MARK: - 启动清理

    /// 启动时清掉两个月没命中的自动规则，手工规则和最近用过的都要留着，并且真的落盘。
    func testLaunchPrunesStaleLearnedRulesOnly() throws {
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings()
        settings.siteRules = [
            SiteRule(host: "old.example", keyword: "搜索", sourceID: "abc",
                     learned: true, createdAt: Date().addingTimeInterval(-70 * 24 * 3600)),
            SiteRule(host: "used.example", keyword: "搜索", sourceID: "abc",
                     learned: true, createdAt: Date().addingTimeInterval(-60 * 24 * 3600),
                     lastUsed: Date().addingTimeInterval(-3 * 24 * 3600)),
            SiteRule(host: "manual.example", keyword: "搜索", sourceID: "abc"),
        ]
        try store.save(settings)

        let service = try InputSourceService(hub: EventHub(), directory: directory)
        XCTAssertEqual(service.siteRules.map(\.host), ["used.example", "manual.example"])
        XCTAssertEqual(try InputSourceStore(directory: directory).load().siteRules.map(\.host),
                       ["used.example", "manual.example"])
    }

    /// 命中时间要落盘（否则每天用的规则也会被当成没用过），但不必每次命中都写文件。
    func testRuleHitPersistsAtMostOncePerHour() throws {
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings()
        settings.siteRules = [
            SiteRule(host: "github.com", keyword: "写评论", sourceID: "pinyin",
                     learned: true, createdAt: Date()),
        ]
        try store.save(settings)

        let service = try InputSourceService(hub: EventHub(), directory: directory)
        let id = settings.siteRules[0].id
        let first = Date().addingTimeInterval(1)

        service.noteRuleHit(id, now: first)
        XCTAssertEqual(service.lastHit(ruleID: id)?.timeIntervalSince1970 ?? 0,
                       first.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try store.load().siteRules[0].lastUsed?.timeIntervalSince1970 ?? 0,
                       first.timeIntervalSince1970, accuracy: 1)

        // 一小时内的第二次命中只改内存，不重复写盘
        service.noteRuleHit(id, now: first.addingTimeInterval(60))
        XCTAssertEqual(try store.load().siteRules[0].lastUsed?.timeIntervalSince1970 ?? 0,
                       first.timeIntervalSince1970, accuracy: 1)

        let later = first.addingTimeInterval(7200)
        service.noteRuleHit(id, now: later)
        XCTAssertEqual(try store.load().siteRules[0].lastUsed?.timeIntervalSince1970 ?? 0,
                       later.timeIntervalSince1970, accuracy: 1)
    }

    /// 手工规则不会被学习改掉：用户手写的配置不该被「两次顺手换源」翻掉。
    func testManualRuleIsNotOverriddenByLearning() throws {
        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.addSiteRule(SiteRule(host: "github.com", keyword: "写评论", sourceID: "pinyin"))

        let field = BrowserContext(kind: .field, host: "github.com", label: "写评论")
        let first = Date()
        service.recordLearn(context: field, sourceID: "abc", now: first)
        service.recordLearn(context: field, sourceID: "abc", now: first.addingTimeInterval(60))

        XCTAssertEqual(service.siteRules.count, 1)
        XCTAssertEqual(service.siteRules[0].sourceID, "pinyin")
        XCTAssertTrue(service.learnCandidates.isEmpty)
    }

    /// 已经学出来的规则不用再学一遍：同一个框、同一个源不攒候选，也不会重写规则。
    func testLearnedRuleDoesNotAccumulateCandidates() throws {
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings()
        let created = Date().addingTimeInterval(-3600)
        settings.siteRules = [SiteRule(host: "github.com", keyword: "写评论", sourceID: "pinyin",
                                       learned: true, createdAt: created)]
        try store.save(settings)

        let service = try InputSourceService(hub: EventHub(), directory: directory)
        let field = BrowserContext(kind: .field, host: "github.com", label: "写评论")
        let now = Date()
        service.recordLearn(context: field, sourceID: "pinyin", now: now)
        service.recordLearn(context: field, sourceID: "pinyin", now: now.addingTimeInterval(60))

        XCTAssertTrue(service.learnCandidates.isEmpty)
        XCTAssertEqual(service.siteRules.count, 1)
        // 创建时间没被这次「重复确认」推后，60 天清理的起算点不会一直往后滚
        XCTAssertEqual(service.siteRules[0].createdAt, created)
    }

    /// 用户亲手改过源，这条就不再是「自动学的」，30 天清理也不会碰它。
    func testEditingSourceAdoptsLearnedRule() throws {
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings()
        settings.siteRules = [
            SiteRule(host: "github.com", keyword: "写评论", sourceID: "pinyin",
                     learned: true, createdAt: Date()),
        ]
        try store.save(settings)

        let service = try InputSourceService(hub: EventHub(), directory: directory)
        let id = settings.siteRules[0].id
        service.setSiteRuleSource(id: id, sourceID: "abc")
        XCTAssertNil(service.siteRules[0].learned)
        XCTAssertNil(service.siteRules[0].createdAt)
        XCTAssertEqual(service.siteRules[0].sourceID, "abc")
    }

    // MARK: - 失效的输入源

    private func installed(_ pairs: (String, String)...) -> [InputSourceInfo] {
        pairs.map { InputSourceInfo(id: $0.0, name: $0.1, isASCIICapable: false, isCurrent: false) }
    }

    /// 换掉输入法后，得过一遍配置才算得出「哪些地方指着它」。
    /// 同一个 App 的规则和记忆指同一个源时只算一个 App。
    func testMissingSourcesCountEveryReference() throws {
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings()
        settings.rules["com.apple.Terminal"] = "com.sogou.pinyin"
        settings.memory["com.apple.Terminal"] = "com.sogou.pinyin"
        settings.memory["com.apple.Safari"] = "com.sogou.pinyin"
        settings.addressBarSourceID = "com.sogou.pinyin"
        settings.siteRules = [SiteRule(host: "github.com", keyword: "写评论", sourceID: "com.sogou.pinyin")]
        settings.learnCandidates = [SiteRuleCandidate(host: "a.com", keyword: "搜索", sourceID: "com.sogou.pinyin")]
        try store.save(settings)

        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.refreshSourceAvailability(installed(("com.apple.keylayout.ABC", "ABC")))

        let missing = try XCTUnwrap(service.missingSources.first)
        XCTAssertEqual(missing.sourceID, "com.sogou.pinyin")
        XCTAssertEqual(missing.appCount, 2)
        XCTAssertEqual(missing.siteRuleCount, 1)
        XCTAssertEqual(missing.candidateCount, 1)
        XCTAssertTrue(missing.addressBar)
        XCTAssertEqual(missing.total, 5)
    }

    /// 一次迁移把五处引用全换掉，并且落盘；其他配置一个字都不动。
    func testMigrateReplacesAllReferencesAndPersists() throws {
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings()
        settings.rules["com.apple.Terminal"] = "com.old"
        settings.memory["com.apple.Safari"] = "com.old"
        settings.addressBarSourceID = "com.old"
        settings.siteRules = [
            SiteRule(host: "github.com", keyword: "写评论", sourceID: "com.old"),
            SiteRule(host: "github.com", sourceID: "com.apple.keylayout.ABC"),
        ]
        settings.learnCandidates = [
            SiteRuleCandidate(host: "a.com", keyword: "搜索", sourceID: "com.old"),
        ]
        try store.save(settings)

        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.refreshSourceAvailability(installed(("com.apple.keylayout.ABC", "ABC"),
                                                    ("com.sogou.pinyin", "搜狗拼音")))

        let summary = service.migrateSource(from: "com.old", to: "com.sogou.pinyin")
        XCTAssertEqual(summary.apps, 2)
        XCTAssertEqual(summary.siteRules, 1)
        XCTAssertEqual(summary.candidates, 1)
        XCTAssertTrue(summary.addressBar)
        XCTAssertEqual(summary.total, 5)

        XCTAssertEqual(service.rule(for: "com.apple.Terminal"), "com.sogou.pinyin")
        XCTAssertEqual(service.memory["com.apple.Safari"], "com.sogou.pinyin")
        XCTAssertEqual(service.addressBarSourceID, "com.sogou.pinyin")
        XCTAssertEqual(service.siteRules.first { $0.keyword == "写评论" }?.sourceID, "com.sogou.pinyin")
        // 迁移算一次确认：自动规则的时间刷新到此刻，不会下次启动就被当「两个月没用」清掉
        XCTAssertNotNil(service.siteRules.first { $0.keyword == "写评论" }?.lastUsed)
        // 没指向旧源的那条不能被顺手改掉
        XCTAssertEqual(service.siteRules.first { $0.isSiteWide }?.sourceID, "com.apple.keylayout.ABC")
        XCTAssertEqual(service.learnCandidates.first?.sourceID, "com.sogou.pinyin")
        // 迁移后 service 会用真实的 TIS 列表再对一次账；测试里没有这个源，手动喂一遍
        service.refreshSourceAvailability(installed(("com.apple.keylayout.ABC", "ABC"),
                                                    ("com.sogou.pinyin", "搜狗拼音")))
        XCTAssertTrue(service.missingSources.isEmpty)

        let reread = try InputSourceService(hub: EventHub(), directory: directory)
        XCTAssertEqual(reread.rule(for: "com.apple.Terminal"), "com.sogou.pinyin")
        XCTAssertEqual(reread.siteRules.first { $0.keyword == "写评论" }?.sourceID, "com.sogou.pinyin")
    }

    /// 目标源本身不可用时拒绝迁移：把一堆配置迁到一个不存在的源等于集体失效。
    func testMigrateToUnavailableSourceIsRejected() throws {
        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.setRule(bundleID: "com.apple.Terminal", sourceID: "com.old")
        service.refreshSourceAvailability(installed(("com.apple.keylayout.ABC", "ABC")))

        let summary = service.migrateSource(from: "com.old", to: "com.not.installed")
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(service.rule(for: "com.apple.Terminal"), "com.old")
    }

    /// 读不到输入法列表（TIS 异常、无图形会话）时保持上次的判断：
    /// 误判成「全部失效」会让用户一点迁移就把所有配置改成同一个源。
    func testEmptySourceListKeepsPreviousVerdict() throws {
        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.setRule(bundleID: "com.apple.Terminal", sourceID: "com.old")
        service.refreshSourceAvailability(installed(("com.apple.keylayout.ABC", "ABC")))
        XCTAssertEqual(service.missingSources.count, 1)

        service.refreshSourceAvailability([])
        XCTAssertEqual(service.missingSources.count, 1)
        XCTAssertTrue(service.isSourceAvailable("com.apple.keylayout.ABC"))
    }

    /// 卸载后系统查不到名字了，但提示里得能说出它叫什么。
    func testSourceNameSurvivesUninstall() throws {
        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.setRule(bundleID: "com.apple.Terminal", sourceID: "com.old")
        service.refreshSourceAvailability(installed(("com.old", "搜狗拼音")))
        service.refreshSourceAvailability(installed(("com.apple.keylayout.ABC", "ABC")))

        XCTAssertEqual(service.sourceName(id: "com.old"), "搜狗拼音")
        XCTAssertEqual(service.missingSources.first?.name, "搜狗拼音")
    }

    /// 迁移后两个源各自攒过同一个框的候选会变成重复项，合并成一条。
    func testMigrateMergesDuplicateCandidates() throws {
        let store = try InputSourceStore(directory: directory)
        var settings = InputSourceSettings()
        settings.learnCandidates = [
            SiteRuleCandidate(host: "a.com", keyword: "搜索", sourceID: "com.old", hits: 1),
            SiteRuleCandidate(host: "a.com", keyword: "搜索", sourceID: "com.sogou.pinyin", hits: 1),
        ]
        try store.save(settings)

        let service = try InputSourceService(hub: EventHub(), directory: directory)
        service.refreshSourceAvailability(installed(("com.sogou.pinyin", "搜狗拼音")))
        service.migrateSource(from: "com.old", to: "com.sogou.pinyin")

        XCTAssertEqual(service.learnCandidates.count, 1)
        XCTAssertEqual(service.learnCandidates.first?.sourceID, "com.sogou.pinyin")
    }
}

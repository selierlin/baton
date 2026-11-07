import Foundation

/// 一条网站规则。
///
/// 两种粒度共用一套结构：
/// - `keyword` 为空 → 整站都用这个源
/// - `keyword` 非空 → 只有焦点的输入框文案里含这个关键字时才用
///
/// 拿不到输入框文案（富文本编辑器常这样）时，带关键字的规则不会命中，
/// 页面退回整站规则——宁可不动，也别乱切。
public struct SiteRule: Codable, Sendable, Equatable, Identifiable {
    /// 已是规范化后的域名：小写、无 scheme、无 www.、无端口、无路径
    public var host: String
    /// 输入框关键字（placeholder / aria-label 里的一段）。nil 或空串 = 整站
    public var keyword: String?
    public var sourceID: String
    /// 这条是自动学出来的（而不是手工采集/填的）。只是给界面打个标，不参与匹配。
    public var learned: Bool?
    /// 学出来的时间。启动清理时拿它当「从没命中过」的起算点。
    public var createdAt: Date?
    /// 最近一次真的被用上（焦点落进去、因此换了源）。重启后仍然有效，
    /// 因为「两个月没用过」这件事本身要跨重启才判得出来。
    public var lastUsed: Date?

    public init(host: String,
                keyword: String? = nil,
                sourceID: String,
                learned: Bool? = nil,
                createdAt: Date? = nil,
                lastUsed: Date? = nil) {
        self.host = host
        self.keyword = (keyword?.isEmpty ?? true) ? nil : keyword
        self.sourceID = sourceID
        self.learned = learned
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }

    public var id: String { "\(host)|\(keyword ?? "")" }

    /// 带关键字的规则更具体，界面上也用它来决定显示「整站」还是「含 xx」
    public var isSiteWide: Bool { keyword == nil }

    public var displayKeyword: String { keyword ?? "整站" }
}

public enum SiteRuleMatcher {
    /// 把用户输入或地址栏里的东西收敛成域名。
    ///
    /// 地址栏给的是 `selier-air-cc.linliang.top:8443/session/xxx`（没有 scheme），
    /// 用户可能直接粘 `https://github.com/foo`，两种都要能用。
    public static func normalizeHost(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !text.isEmpty else {
            return nil
        }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        if let cut = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }
        // 去端口。IPv6 的 [::1]:3000 这种情况先不处理，个人用不到
        if let colon = text.firstIndex(of: ":"), !text.hasPrefix("[") {
            text = String(text[..<colon])
        }
        while text.hasPrefix("www.") {
            text = String(text.dropFirst(4))
        }
        return text.isEmpty ? nil : text
    }

    /// 子域算命中：配了 `github.com`，`gist.github.com` 也算。
    public static func hostMatches(_ host: String, ruleHost: String) -> Bool {
        host == ruleHost || host.hasSuffix("." + ruleHost)
    }

    /// 找最贴合的一条：带关键字的优先于整站，域名长的优先于短的。
    public static func match(host: String?, label: String?, rules: [SiteRule]) -> SiteRule? {
        guard let host = normalizeHost(host), !rules.isEmpty else { return nil }
        var best: SiteRule?
        for rule in rules {
            let ruleHost = normalizeHost(rule.host)
            guard let ruleHost, hostMatches(host, ruleHost: ruleHost) else { continue }
            if let keyword = rule.keyword {
                guard let label, !label.isEmpty,
                      label.localizedCaseInsensitiveContains(keyword) else {
                    continue
                }
            }
            if isMoreSpecific(rule, than: best) {
                best = rule
            }
        }
        return best
    }

    /// 两条规则是不是指向同一个输入框。
    ///
    /// 关键字都是从不多的几句 placeholder 里截出来的，同一个框的两条规则
    /// 通常一条是另一条的前缀（`输入 / 调用命令` ⊂ `输入 / 调用命令，@ 选择文件…`）。
    /// 只看字符串相等会把它们当成两个框，同一个框就长出两行规则。
    public static func sameField(_ lhs: SiteRule, _ rhs: SiteRule) -> Bool {
        guard let lHost = normalizeHost(lhs.host), let rHost = normalizeHost(rhs.host),
              lHost == rHost,
              let lKey = lhs.keyword, let rKey = rhs.keyword else {
            return false
        }
        return lKey.localizedCaseInsensitiveContains(rKey)
            || rKey.localizedCaseInsensitiveContains(lKey)
    }

    private static func isMoreSpecific(_ lhs: SiteRule, than rhs: SiteRule?) -> Bool {
        guard let rhs else { return true }
        if (lhs.keyword != nil) != (rhs.keyword != nil) { return lhs.keyword != nil }
        return lhs.host.count > rhs.host.count
    }
}

/// 自动学习中的一个组合：哪个网站的哪个输入框，用过哪个源，攒了几次。
///
/// 存进配置而不是只放内存：攒次数跨越重启才有意义——今天用一次、明天用一次，
/// 也该算「两次」。条数有上限，攒不满的老候选会被清掉，不会无限长。
public struct SiteRuleCandidate: Codable, Sendable, Equatable {
    public var host: String
    public var keyword: String
    public var sourceID: String
    public var hits: Int
    public var lastSeen: Date

    public init(host: String, keyword: String, sourceID: String, hits: Int = 1, lastSeen: Date = Date()) {
        self.host = host
        self.keyword = keyword
        self.sourceID = sourceID
        self.hits = hits
        self.lastSeen = lastSeen
    }

    public var id: String { "\(host)|\(keyword)|\(sourceID)" }
}

/// 从「用户手动换源」里学出输入框级规则。
///
/// 规则是纯数据变换，不碰 AX、不碰配置，服务层拿到上下文后调一次即可。
public enum SiteRuleLearning {
    /// 同一个组合重复这么多次才建规则。一次不算：改错别字、临时查个词都会顺手换源。
    public static let threshold = 2
    /// 关键字太长没有意义，截断后仍然按「包含」匹配（前缀还在）
    public static let maxKeywordLength = 24
    /// placeholder 到了这些字符就算「换了一句」，只取前面那段当关键字。
    /// 很多输入框的 placeholder 是「主提示，补充说明」，后面那截常带产品名、
    /// 模型名、当前文档标题——那部分一变，同一个框就会重新学一条规则出来
    public static let keywordStops: Set<Character> = ["，", ",", "。", "；", ";", "｜", "|", "·", "—", "\n"]
    /// 候选上限。攒不满的被挤掉，配置不会越写越大
    public static let maxCandidates = 40
    /// 一个月没再出现的候选忘掉，别让一次误操作留到明年
    public static let expiry: TimeInterval = 30 * 24 * 60 * 60

    /// 把 placeholder 收敛成一个能长期匹配的关键字。
    ///
    /// 只取第一个分隔符之前那段：`输入 / 调用命令，@ 选择文件，或向 XX 提问`
    /// 里真正稳定的是前半句，后半句随产品改名就变，留着它等于每改一次名建一条规则。
    /// 换行和多空格压成单空格：规则用的是 `contains`，压缩只影响显示和匹配的稳定性。
    public static func keyword(from label: String?) -> String? {
        guard let raw = label else { return nil }
        var text = raw.prefix { !keywordStops.contains($0) }
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > maxKeywordLength {
            text = String(text.prefix(maxKeywordLength))
        }
        return text
    }

    /// 让已有的自动规则跟上关键字规则的变化，并合并指向同一个框的重复规则。
    /// 老版本把整段 placeholder 存成关键字，改个产品名就多一条规则出来
    /// （`…或向 A 提问` / `…或向 B 提问` 各一条，界面上就是三行一模一样的）。
    /// 这里按新规则重新提取，提取后撞成同一个 id 的合成一条：
    /// 源取第一条，创建时间取最早，命中时间取最晚——都是同一条规则的历史。
    /// 只碰自动学的，手工规则一个字都不动；自动规则和手工规则撞在同一个框、
    /// 又要的是同一个源时，留手工那条（那是用户明确写下的）。
    public static func normalizeLearned(_ rules: inout [SiteRule]) {
        var result: [SiteRule] = []
        // 只记「自动规则」在结果里的位置：手工规则永远单独占一行，不去和谁合并
        var learnedIndex: [String: Int] = [:]

        for rule in rules {
            var item = rule
            if item.learned == true, let stored = item.keyword {
                item.keyword = keyword(from: stored)
            }
            guard item.learned == true, let position = learnedIndex[item.id] else {
                if item.learned == true { learnedIndex[item.id] = result.count }
                result.append(item)
                continue
            }
            var existing = result[position]
            if let created = item.createdAt {
                existing.createdAt = existing.createdAt.map { min($0, created) } ?? created
            }
            if let used = item.lastUsed {
                existing.lastUsed = existing.lastUsed.map { max($0, used) } ?? used
            }
            result[position] = existing
        }

        // 老配置里同一个框可能同时留着手工和自动两条：源一样就是纯重复
        let manual = result.filter { $0.learned != true }
        result.removeAll { rule in
            rule.learned == true && manual.contains {
                $0.sourceID == rule.sourceID && SiteRuleMatcher.sameField($0, rule)
            }
        }
        rules = result
    }

    /// 已经有正式规则的框不用再攒候选（同一个源）。
    /// 留着只会让界面上「学习中 N 条」虚高，攒够了还会把同一条规则重写一遍。
    public static func dropCandidatesCoveredBy(_ rules: [SiteRule],
                                               _ candidates: inout [SiteRuleCandidate]) {
        let covered = Set(rules.filter { $0.learned == true }
            .map { "\($0.host)|\($0.keyword ?? "")|\($0.sourceID)" })
        candidates.removeAll { covered.contains($0.id) }
    }

    /// 学习中的候选也按新规则重算关键字，并合并撞在一起的：
    /// 攒的次数取多的、最后出现时间取晚的，等于把两次记录算成同一条。
    public static func normalizeCandidates(_ candidates: inout [SiteRuleCandidate]) {
        var merged: [String: SiteRuleCandidate] = [:]
        var order: [String] = []
        for candidate in candidates {
            var item = candidate
            item.keyword = keyword(from: candidate.keyword) ?? candidate.keyword
            if var existing = merged[item.id] {
                existing.hits += item.hits
                existing.lastSeen = max(existing.lastSeen, item.lastSeen)
                merged[item.id] = existing
            } else {
                merged[item.id] = item
                order.append(item.id)
            }
        }
        candidates = order.compactMap { merged[$0] }
    }

    /// 记一次用户手动换源。返回非 nil 表示攒够了，调用方应当落一条正式规则。
    ///
    /// 同一个输入框换成了别的源时，之前给另一个源攒的次数直接丢掉：
    /// 交替使用时两边各攒一半永远攒不满，而「最近一次想用什么」才是最可靠的信号。
    @discardableResult
    public static func record(host: String,
                              keyword: String,
                              sourceID: String,
                              candidates: inout [SiteRuleCandidate],
                              now: Date = Date()) -> SiteRule? {
        guard let normalized = SiteRuleMatcher.normalizeHost(host),
              !keyword.isEmpty, !sourceID.isEmpty else {
            return nil
        }
        expire(&candidates, now: now)

        if let index = candidates.firstIndex(where: {
            $0.host == normalized && $0.keyword == keyword && $0.sourceID == sourceID
        }) {
            candidates[index].hits += 1
            candidates[index].lastSeen = now
            guard candidates[index].hits >= threshold else { return nil }
            candidates.remove(at: index)
            return SiteRule(host: normalized, keyword: keyword, sourceID: sourceID)
        }

        candidates.removeAll { $0.host == normalized && $0.keyword == keyword }
        candidates.append(SiteRuleCandidate(host: normalized,
                                           keyword: keyword,
                                           sourceID: sourceID,
                                           hits: 1,
                                           lastSeen: now))
        trim(&candidates)
        return nil
    }

    public static func expire(_ candidates: inout [SiteRuleCandidate], now: Date = Date()) {
        candidates.removeAll { now.timeIntervalSince($0.lastSeen) > expiry }
    }

    /// 学出来的规则多久没用就当成「当时临时用的站点」。
    /// 60 天：30 天会误伤「每月用一次」的账单/后台类站点，刚好卡在边界上被反复删了又学。
    public static let staleRuleAge: TimeInterval = 60 * 24 * 60 * 60

    /// 清掉「自动学的、且两个月没再命中」的规则。
    ///
    /// 只碰 `learned == true` 的：手工采集/填写的规则是用户明确写下来的配置，
    /// 自动删掉等于替他做决定。没有时间戳的老数据也留着——没法判断就别猜。
    ///
    /// 只在启动时跑一次，不挂定时器：判断粒度是天，为此常驻一个计时器不划算。
    @discardableResult
    public static func pruneStale(_ rules: inout [SiteRule],
                                  now: Date = Date(),
                                  maxAge: TimeInterval = staleRuleAge) -> [SiteRule] {
        var removed: [SiteRule] = []
        rules.removeAll { rule in
            guard rule.learned == true else { return false }
            guard let reference = rule.lastUsed ?? rule.createdAt else { return false }
            let stale = now.timeIntervalSince(reference) > maxAge
            if stale { removed.append(rule) }
            return stale
        }
        return removed
    }

    private static func trim(_ candidates: inout [SiteRuleCandidate]) {
        guard candidates.count > maxCandidates else { return }
        candidates.sort { $0.lastSeen > $1.lastSeen }
        candidates.removeLast(candidates.count - maxCandidates)
    }
}

import Foundation

/// 一份「用户导入的歌词源」配置 —— **数据形状照 primuse 的 `ScraperConfig`**（MIT）。
///
/// 一个源 = 两个 endpoint（`search` / `lyrics`），每个 endpoint 的 `script` **必填**：
/// 脚本把响应体变成**固定键**的对象 / 数组（键名在 `LyricsSourceMappingPolicy`）。
/// 二进制歌词（密文）不另立端点 —— 脚本返回 `_fetchEncryptedLyrics`，客户端按
/// `secrets` 里的四个键去下载、解密（照 primuse 的约定）。
///
/// ⚠️ `secrets` 在**主配置 JSON 里不落盘**：存盘时拆到 `<id>.secrets.json` 旁路文件。
struct LyricsSourceConfig: Codable, Equatable, Identifiable {

    let id: String
    var name: String
    var version: Int
    var capabilities: [String]
    var rateLimit: Int?
    var headers: [String: String]?
    /// 随请求头发出的一次性 Cookie（照 primuse 的字段）。
    var cookie: String?
    var search: Endpoint?
    var lyrics: Endpoint?
    /// 取回来的正文要过一遍的**声明式清洗规则**（见 `LyricsRuleEngine`）。缺省 = 不清洗。
    var rules: [LyricsRule]?
    var secrets: [String: String]?
    /// 只用于**拒绝**：本 App 不绕 TLS 校验（primuse 的 `sslTrustDomains`）。
    var sslTrustDomains: [String]?

    struct Endpoint: Codable, Equatable {
        var url: String
        var method: String
        var params: [String: String]?
        var headers: [String: String]?
        /// POST 的 JSON 体模板（`{{变量}}` 会按 JSON 字符串转义）。
        var bodyTemplate: String?
        /// 必填：一段 JavaScript，入参 `responseText` / `response`，返回固定键。
        var script: String?
    }

    /// `capabilities` 里声明逐字 —— 只当徽标，不当门槛。
    var supportsWordLevel: Bool { capabilities.contains("lyricsWordLevel") }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case capabilities
        case rateLimit
        case headers
        case cookie
        case search
        case lyrics
        case rules
        case secrets
        case sslTrustDomains
    }

    /// 🔴 **编码时不输出 `secrets`** —— 密钥只走 `<id>.secrets.json` 旁路。
    ///
    /// 这条规矩写在**类型里**，不写在存储层：存储层要写、导出要写、以后分享 / 备份还要写，
    /// 每加一条往外走的路就得再记得剥一次，漏一处密钥就跟着出去了。写在 encode 里，
    /// 所有往外走的出口自动干净 —— **一个写者，一处判据**。
    ///
    /// ⚠️ 只手动实现了 `encode(to:)`，`init(from:)` 仍由编译器合成（读的时候要能读回 secrets）。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(rateLimit, forKey: .rateLimit)
        try container.encodeIfPresent(headers, forKey: .headers)
        try container.encodeIfPresent(cookie, forKey: .cookie)
        try container.encodeIfPresent(search, forKey: .search)
        try container.encodeIfPresent(lyrics, forKey: .lyrics)
        try container.encodeIfPresent(rules, forKey: .rules)
        try container.encodeIfPresent(sslTrustDomains, forKey: .sslTrustDomains)
        // secrets 故意省略 —— 见上面的说明。
    }
}

/// 配置不能用的原因（逐条给 UI 看）。
enum LyricsSourceConfigIssue: Equatable {
    case invalidID
    case emptyName
    case emptyCapabilities
    case missingSearch
    case missingLyrics
    case tlsBypassNotSupported
    case urlNotHTTPS(endpoint: String)
    case unsupportedMethod(endpoint: String)
    case missingScript(endpoint: String)
    case scriptTooLong(endpoint: String)
    case emptyRuleKeyword
    case ruleKeywordTooShort
    case ruleKeywordHasColon
    case ruleKeywordTooLong
    case tooManyRuleKeywords
    case ruleMinHitsOutOfRange
}

/// 规则本身读不出来（跟 `LyricsSourceConfigIssue` 分两档：这个是**解码阶段**就炸，
/// 根本走不到 `issues`）。
enum LyricsRuleError: Error, Equatable {
    /// `rules` 里出现了白名单之外的键。
    case unknownAction([String])
    /// `scope` 写了不认识的值。
    case unknownScope(String)

    var message: String {
        switch self {
        case let .unknownAction(names):
            return "rules 里有不认识的键：\(names.joined(separator: "、"))"
        case let .unknownScope(value):
            return "rules 里的 scope 只能是 label 或 line，不认得「\(value)」"
        }
    }
}

/// 规则在**哪儿**找词。
enum LyricsRuleScope: String, Codable, CaseIterable {
    /// 冒号前那截标签 —— 默认。制作信息行的常规形态（`编曲：X`）。
    case label
    /// 整行，**不要求冒号**。给「腾讯翻译权声明」「版权声明」这类没有冒号的整句用。
    case line
}

/// 一条声明式清洗规则 —— **纯数据，不跑任意代码**。
///
/// 一个动作（`dropLineContaining`）＋ 两个可选修饰（`scope` / `minHits`）：
///
/// ```json
/// { "dropLineContaining": ["编曲", "制作"] }
/// { "dropLineContaining": ["腾讯", "享有", "翻译", "权"], "scope": "line", "minHits": 4 }
/// ```
///
/// 以后要加换行 / 平移就往下加键，引擎按数组顺序逐条执行（见 `LyricsRuleEngine`）。
struct LyricsRule: Codable, Equatable {

    /// 词表。**命中几个才算删**由 `minHits` 决定，**在哪儿找**由 `scope` 决定。
    ///
    /// 🔴 **词条不带冒号**（写 `"编曲"`，不写 `"编曲："`）—— 判据只取冒号前那截，
    /// 写 `"编曲"` 一条就能盖住「编曲：」「编曲人：」；写 `"编曲："` 反而一条都删不掉。
    /// 带冒号的词条会在导入校验里报错，不会静默失效。
    ///
    /// 🔴 **只列要删的**：「作词」「作曲」「艺人」「专辑」「演唱」不进词表，自然就留下了。
    /// 🔴 **只写简体**：繁体由引擎在标签上归一（ICU 转写），不用再写一份繁体词表。
    /// 🔴 **大小写不敏感**：英文词条写 `Mixed` 就能撞上 `mixed:`。
    var dropLineContaining: [String]?

    /// 在哪儿找词。缺省 `label`（冒号前那截，要求有冒号）。
    var scope: LyricsRuleScope?

    /// 至少命中几个词才删。缺省 `1`（命中任一）。
    ///
    /// 给「版权声明」这种**整句里散着好几个词**的行用：`未经许可，不得翻唱或使用`
    /// 一条词条都撞不中，但 7 个词里中 4 个就够判定。见 `kugou-rules.json`。
    var minHits: Int?

    /// 真正参与匹配的词条 —— **唯一出口**。
    ///
    /// 空串在这里去掉：空串 `contains` 恒真，一个空串就能把整份歌词删光。
    /// 引擎只认这个属性，所以词表不管从哪条路进来（JSON / 代码构造 / 直接赋 `var`）
    /// 都拿不到空串 —— 引擎不用再判一次。
    var activeKeywords: [String] {
        (dropLineContaining ?? []).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 实际生效的范围（缺省 `label`）。
    var effectiveScope: LyricsRuleScope { scope ?? .label }

    /// 实际生效的门槛（缺省 `1`，且**不小于 1** —— 0 或负数是坏配置，校验会报）。
    var effectiveMinHits: Int { max(1, minHits ?? 1) }

    /// 认得的键 —— 解码时的白名单。
    static let knownActions: Set<String> = ["dropLineContaining", "scope", "minHits"]

    init(dropLineContaining: [String]? = nil, scope: LyricsRuleScope? = nil, minHits: Int? = nil) {
        self.dropLineContaining = dropLineContaining
        self.scope = scope
        self.minHits = minHits
    }

    private enum CodingKeys: String, CodingKey {
        case dropLineContaining
        case scope
        case minHits
    }

    /// 🔴 **未知键必须报错，不能静默跳过**：`dropLineContaining` 手滑写成 `dropLines`，
    /// 默认的 `Codable` 会把它当"这个字段没有"，规则解成 `nil` 被引擎 `continue` 掉 ——
    /// 不报错、不删行，用户只会以为"没命中"。所以先拿全部键名过一遍白名单。
    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknown = all.allKeys.map(\.stringValue).filter { !Self.knownActions.contains($0) }
        guard unknown.isEmpty else { throw LyricsRuleError.unknownAction(unknown) }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        dropLineContaining = try container.decodeIfPresent([String].self, forKey: .dropLineContaining)

        // 🔴 `scope` 写错值必须报错。让 `LyricsRuleScope` 自己去 decode 的话，
        // 未知值抛的是 `DecodingError`，界面上只会显示「数据损坏」，说不出错在哪。
        if let raw = try container.decodeIfPresent(String.self, forKey: .scope) {
            guard let parsed = LyricsRuleScope(rawValue: raw) else {
                throw LyricsRuleError.unknownScope(raw)
            }
            scope = parsed
        }

        minHits = try container.decodeIfPresent(Int.self, forKey: .minHits)
    }
}

/// 只为「读出对象里所有键名」而存在。
private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue }

    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = "\(intValue)"
    }
}

extension LyricsSourceConfig {

    /// 单段脚本上限（字符）—— 与 primuse 同档（它的源配置里脚本可以很长）。
    /// 真正防卡死的是执行时限（`LyricsSourceScriptRunner.timeout`），不是长度。
    static let maxScriptLength = 200_000

    /// 规则词表的上限 —— 防手滑粘一大段进去。
    ///
    /// 条数上限给到 512：真实词表（简繁两份）就两百多条，这里是**防呆**，不是设计约束。
    static let maxRuleKeywordLength = 32
    static let maxRuleKeywordCount = 512

    /// `scope: line` 的词条最短 **2** 个字。
    ///
    /// 🔴 **只拦 `line` 范围**：`label` 只比冒号前那截，一个「曲」只会命中「作曲」「编曲」
    /// 这类标签 —— 安全，而且「词：」「曲：」「编：」这种一字一行的署名正需要它。
    /// `line` 是**整行**比，一个「的」「我」就能把整份歌词删光。
    static let minLineRuleKeywordLength = 2

    /// 导入时的结构校验。
    ///
    /// 🔴 **不校验"逐字"声明**：`lyricsWordLevel` 只是徽标，取回来不是逐字就按行级。
    var issues: [LyricsSourceConfigIssue] {
        var result: [LyricsSourceConfigIssue] = []
        if !Self.isSafeID(id) { result.append(.invalidID) }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.emptyName)
        }
        if capabilities.isEmpty { result.append(.emptyCapabilities) }
        if let domains = sslTrustDomains, !domains.isEmpty {
            result.append(.tlsBypassNotSupported)
        }
        if let issue = ruleIssue { result.append(issue) }
        guard let search else {
            result.append(.missingSearch)
            return result
        }
        guard let lyrics else {
            result.append(.missingLyrics)
            return result
        }
        result.append(contentsOf: Self.endpointIssues(search, name: "search"))
        result.append(contentsOf: Self.endpointIssues(lyrics, name: "lyrics"))
        return result
    }

    /// 只允许字母数字和 `._-`，且 1–64 字符 —— 它同时是文件名，防路径穿越。
    static func isSafeID(_ id: String) -> Bool {
        guard (1...64).contains(id.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return id.unicodeScalars.allSatisfy(allowed.contains)
    }

    // MARK: - 私有

    /// 规则写错了就吐一条 —— 这些错法**都不会报错、只会静默失效**，所以必须拦。
    ///
    /// - 空串 `contains` 恒真 ⇒ 一条空词条删光整份歌词；
    /// - `scope: line` 下的单字（`"的"`）会删光正文 —— `label` 下的单字是安全的（见 `minLineRuleKeywordLength`）；
    /// - 带冒号的词条一条都删不掉（判据只取冒号前那截，冒号不在里面）；
    /// - 超长 / 超多基本是粘错了；
    /// - `minHits` 比词条数还大 ⇒ 这条规则**永远不可能命中**。
    private var ruleIssue: LyricsSourceConfigIssue? {
        let rules = self.rules ?? []
        let keywords = rules.flatMap { $0.dropLineContaining ?? [] }
        if keywords.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return .emptyRuleKeyword
        }
        // 单字只在 `label` 范围安全；`line` 范围必须 ≥2 个字（整行比，单字会删光正文）。
        if rules.contains(where: { rule in
            rule.effectiveScope == .line
                && rule.activeKeywords.contains { $0.count < Self.minLineRuleKeywordLength }
        }) {
            return .ruleKeywordTooShort
        }
        if keywords.contains(where: { $0.contains(":") || $0.contains("：") }) {
            return .ruleKeywordHasColon
        }
        if keywords.contains(where: { $0.count > Self.maxRuleKeywordLength }) {
            return .ruleKeywordTooLong
        }
        if keywords.count > Self.maxRuleKeywordCount {
            return .tooManyRuleKeywords
        }
        // 门槛要落在 1…这条规则的词条数 之间，否则这条规则写与不写一个样。
        if rules.contains(where: { rule in
            guard let minHits = rule.minHits else { return false }
            return !(1...max(1, rule.activeKeywords.count)).contains(minHits)
        }) {
            return .ruleMinHitsOutOfRange
        }
        return nil
    }

    private static func endpointIssues(
        _ endpoint: Endpoint,
        name: String
    ) -> [LyricsSourceConfigIssue] {
        var result: [LyricsSourceConfigIssue] = []
        let url = endpoint.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !url.hasPrefix("https://") {
            result.append(.urlNotHTTPS(endpoint: name))
        }
        let method = endpoint.method.uppercased()
        if method != "GET" && method != "POST" {
            result.append(.unsupportedMethod(endpoint: name))
        }
        let script = endpoint.script?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if script.isEmpty {
            result.append(.missingScript(endpoint: name))
        } else if script.count > Self.maxScriptLength {
            result.append(.scriptTooLong(endpoint: name))
        }
        return result
    }
}

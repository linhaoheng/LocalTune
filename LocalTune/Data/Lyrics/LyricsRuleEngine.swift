import Foundation

/// 源配置里那套 `rules` 的执行器 —— **声明式清洗，不跑任意代码**。
///
/// 一个动作（`dropLineContaining`）＋ 两个修饰（`scope` / `minHits`），规则按数组顺序
/// 逐条跑，不重排、不优化。两个修饰的缺省值**等于"只有动作"时的行为**，
/// 所以老配置一个字都不用改。
///
/// ## 🔴 判据默认只看「冒号前那截」
///
/// 制作信息行的形状是 `标签：值`。判据不是"整行含某词"，而是**冒号前的标签**含某词：
///
/// ```
/// 制作人：周杰伦       标签 "制作人"  → 命中「制作」
/// 编曲：黄雨勋         标签 "编曲"    → 命中「编曲」
/// 他说：这编曲真好听   标签 "他说"    → 不命中（正文里的词在冒号后面）
/// 作曲：周杰伦         标签 "作曲"    → 不命中（词表里没有「作曲」，署名要留）
/// ```
///
/// 所以词表里写 `"制作"` 一条就够，**不写冒号** —— 写 `"制作："` 的话「制作人：」会漏
/// （冒号不紧跟「制作」），而「制作人：」「制作助理：」逐条列是列不完的。
///
/// ## 🔴 `scope: line` 是"只看标签"的唯一例外
///
/// 「腾讯音乐享有本歌词翻译权」「未经许可不得翻唱或使用」这类整句**没有冒号**，
/// 拿标签去比永远撞不中。这类规则要显式写 `"scope": "line"` 才看整行 ——
/// **不默认整行**，因为整行比会误杀正文（`他说：这编曲真好听`）。
///
/// ## 🔴 `minHits` 给"散着好几个词"的行用
///
/// 版权声明的词是散在一句话里的：`未经许可，不得翻唱或使用` —— 单条词都撞不中，
/// 但 7 个词里中 4 个就够判定。`minHits` 就是这个门槛，缺省 1（命中任一）。
///
/// ## 🔴 匹配前先剥标记（KRC 布局的字之间夹着 `<…>`）
///
/// 酷狗解密出来是 KRC 布局：
///
/// ```
/// [1250,300]<0,100,0>编<100,100,0>曲<200,100,0>：<300,100,0>黄雨勋
/// ```
///
/// 这里既没有连续的 `"编曲"`、也没有连续的 `"编曲："`（每个字之间隔着标记）。
/// 直接在原始行上 `contains` ⇒ 对密文源一行都删不掉，而且不报错，用户只会看见
/// 制作信息照旧铺在最上面。所以先剥掉行首方括号和所有行内 `<…>`，拿纯文字去判，
/// 命中则丢**原始行**（原文一个字都不动）。LRC 没有这些标记，剥完等于原文
/// ⇒ 两种格式共用一套规则，不分叉。
///
/// ## 🔴 繁简归一 + 大小写不敏感，词表只写一份
///
/// 词表只写简体（`编曲`），繁体源档（`編曲：黃雨勳`）由**代码**转 —— 用系统的 ICU 转写，
/// 不带词表。所以不用在 JSON 里把每个词再写一遍繁体：
///
/// - 繁体列不完：`製作` 能列，`製作助理` `混音師` `母帶工程師` 这些变体的繁体形态列不全，
///   漏一条就是漏删一整类；简体侧靠 `"制作"` 一条前缀就全盖住；
/// - 两边能力不对等 ⇒ 迟早会有人只补了简体、忘了繁体。
///
/// 英文署名（`Lyrics: X`、`Mixed by: X`）同理：大小写归一后写 `Mixed` 就撞得上 `mixed`。
///
/// 归一后的文本**两侧用同一套**（词条和待判文本都过 `normalized`）—— 只归一一边
/// 就会出现"写了繁体却永远匹配不上"的静默失效。
///
/// ## 🔴 每行只算一次
///
/// 剥标记、找冒号、繁简归一都是**逐行**的事，跟有几条规则无关 —— 所以整份预处理放在
/// 规则循环外面，每条规则只做 `contains`。多条规则时不会重复剥同一行。
///
/// 纯函数、零 UIKit、能离线单测。
enum LyricsRuleEngine {

    /// 一次替换掉两种标记（两个分支，顺序无所谓）：
    ///
    /// - `^\s*(?:\[[^\]]*\]\s*)+` —— 行首方括号，**可以连着好几个**：KRC 布局的 `[起,长]`、
    ///   LRC 的 `[mm:ss.xx]`、属性行的 `[ti:]`、LRC 复句的 `[00:01][00:05]`。
    ///   只剥一个的话，剩下那个 `[00:05.00]` 里的冒号会被当成标签分隔符，标签变成 `[00`。
    /// - `<[^<>]*>` —— 行内尖括号：KRC 布局的 `<相对起,长[,flag]>`、LRC 的 `<mm:ss.xx>`。
    ///   用宽匹配是因为两种格式写法不同，而**歌词正文里不会有尖括号**
    ///   （`LyricsTextSerializer.krcLayoutIssue` 明确把含 `<` / `>` 的正文判成"写不了 KRC 布局"）。
    private static let markerPattern = try? NSRegularExpression(
        pattern: #"^\s*(?:\[[^\]]*\]\s*)+|<[^<>]*>"#
    )

    /// 把规则按顺序过一遍；`rules` 缺省或为空 ⇒ **原文逐字节返回**。
    ///
    /// 全删光时返回空串 —— 由调用方（`LyricsSourceClient.checked`）转成「没找到」，
    /// 不会往库里存一份空歌词。
    static func apply(_ rules: [LyricsRule]?, to text: String) -> String {
        guard let rules, !rules.isEmpty, !text.isEmpty else { return text }

        // 预处理：每行只剥一次标记、只归一一次繁简大小写、只找一次冒号。
        var rows = text.components(separatedBy: "\n").map(makeRow)

        for rule in rules {
            let keywords = rule.activeKeywords.map(normalized)
            guard !keywords.isEmpty else { continue }
            let scope = rule.effectiveScope
            let minHits = rule.effectiveMinHits
            rows = rows.filter { !drops($0, keywords: keywords, scope: scope, minHits: minHits) }
        }
        return rows.map(\.line).joined(separator: "\n")
    }

    // MARK: - 私有

    /// 一行预处理完的样子 —— `line` 是原文（命中后原样丢），另两个是判据用的。
    private struct Row {
        /// 原始行。删行时丢它，所以标记 / 时间戳一个字都不动。
        let line: String
        /// 剥掉标记、繁简归一、大小写归一之后的**整行**。`scope: line` 比这个。
        let text: String
        /// `text` 里第一个冒号之前那截（已归一）。没有冒号 ⇒ `nil`，默认 `scope` 直接放行。
        let label: String?
    }

    private static func makeRow(_ line: String) -> Row {
        let text = normalized(stripped(line))
        let label = text.firstIndex(where: isColon).map { String(text[..<$0]) }
        return Row(line: line, text: text, label: label)
    }

    /// 这一行该不该删：取对应范围的文本，数命中几个词，够门槛就删。
    ///
    /// `minHits` 数的是**命中的词条个数**，不是出现次数 —— `["制作", "制作人"]`
    /// 在同一行上算 2 个（词条本身就重叠，属于配置写法问题，不是引擎的事）。
    private static func drops(
        _ row: Row,
        keywords: [String],
        scope: LyricsRuleScope,
        minHits: Int
    ) -> Bool {
        // `scope: label` 下没有冒号的行**不是制作信息行**，直接放行。
        guard let haystack = scope == .line ? row.text : row.label else { return false }
        let hits = keywords.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
        return hits >= minHits
    }

    /// 繁简 + 大小写归一（ICU 转写，不带词表）。已经规范时原样返回。
    ///
    /// 两侧必须用同一个函数：词条过它、待判文本也过它。
    private static func normalized(_ text: String) -> String {
        let simplified = text.applyingTransform(
            StringTransform(rawValue: "Traditional-Simplified"),
            reverse: false
        ) ?? text
        return simplified.lowercased()
    }

    /// 剥掉行首方括号与所有行内标记，只留文字。
    private static func stripped(_ line: String) -> String {
        guard let markerPattern else { return line }
        return markerPattern.stringByReplacingMatches(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length),
            withTemplate: ""
        )
    }

    /// 全角 `：` 半角 `:` 都算分隔符 —— 在**切点**上认，不用先把整行替换一遍。
    private static func isColon(_ character: Character) -> Bool {
        character == ":" || character == "："
    }
}

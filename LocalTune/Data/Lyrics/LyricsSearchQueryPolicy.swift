import Foundation

/// 拿**哪个词**去酷狗搜 —— 纯函数、零 UIKit、能离线单测。
///
/// ## 🔴 它是真搜索引擎（与 AMLL 的根本差别）
///
/// AMLL 那个接口是**单个词的模糊匹配**，实测 `晴天 周杰伦`、`晴天周杰伦`、`周杰伦`
/// **全是 0 条** ⇒ 走 AMLL 就**绝不能**把歌名与艺人拼成一串搜。
/// 酷狗**支持多词**⇒ 预填直接写「**歌名 艺人**」。
///
/// ## 回落顺序（酷狗源版）
///
/// `歌名 艺人` → **歌名** → **歌名的「主干」**（去括号尾巴、去 `feat.` 署名）。
///
/// - 第一个是**最准的**：实测 `晴天 周杰伦` 首条就是原唱；
/// - 后两个是**同一次的另一种写法**：本地标签常常写着 `晴天 (Live)`，库里存的是 `晴天`；
///   极端的（`Live Forever` 这种）连主干都得试。
///
/// ⚠️ 只在这一串**都真的没找到**时才往下试。「连不上」不往下试 ——
/// 那不是"这首没词"的证据（Cosmos `LookupOutcome` 那条纪律）。
enum LyricsSearchQueryPolicy {

    /// 依次要试的词（去空 ＋ 去重，顺序即优先级）。
    ///
    /// - Parameters:
    ///   - title: 本地这一首的歌名。
    ///   - artist: 本地这一首的艺人；没有就传空串（那一档自然消失）。
    static func candidates(title: String, artist: String) -> [String] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        var raw: [String] = []
        if !trimmedTitle.isEmpty && !trimmedArtist.isEmpty {
            raw.append("\(trimmedTitle) \(trimmedArtist)")
        }
        raw.append(trimmedTitle)
        raw.append(mainPart(trimmedTitle))

        var result: [String] = []
        for keyword in raw where !keyword.isEmpty {
            // ⚠️ 只跟已经收下的比 —— 通常是「歌名」与「主干」撞上。
            guard !result.contains(keyword) else { continue }
            result.append(keyword)
        }
        return result
    }

    /// 一个名字的**主干** —— 去掉括号尾巴与 `feat.` 署名之后剩的那一段。
    ///
    /// ```
    /// 晴天 (Live)          → 晴天
    /// 晴天【现场版】        → 晴天
    /// 晴天 feat. 张三       → 晴天
    /// 夜曲 - Live          → 夜曲
    /// 晴天                 → 晴天   （本来就干净 ⇒ 原样）
    /// ```
    ///
    /// 🔴 **不收 `Live Forever` 这种整词** —— 只砍"跟在后面的尾巴"，不摘词。
    /// 凡是"把歌名里某个词当成版本标记挑出去"的做法（`LyricsCandidateRankingPolicy.normalizedKey`
    /// 就是那么干的，那是**比相似度**要的）在这里都是错的：它会把《Live Forever》削成《Forever》。
    /// 两件事各有各的归一化，别合并。
    static func mainPart(_ raw: String) -> String {
        var text = raw
        // 🔴 `range.lowerBound != startIndex` 这一问不能省：署名从句是**后缀**，前面得有歌名。
        // 不拦"在开头"的话，`FT Island` 这种歌名会被整条砍成空的（离线台跑出来的反例）。
        if let range = text.range(of: Self.featurePattern, options: .regularExpression),
           range.lowerBound != text.startIndex {
            text = String(text[text.startIndex..<range.lowerBound])
        }
        // 半角 / 全角括号，方括号 / 全角方括号，以及"空格的横杠"（版本名的典型写法）。
        for cutter in ["(", "（", "[", "【", " - ", " – ", " — "] {
            if let range = text.range(of: cutter) {
                text = String(text[text.startIndex..<range.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 署名从句的起点长什么样 —— 两条收紧都是**离线台跑出来的反例逼的**：
    ///
    /// - **`ft` 必须带点**：不带点的 `FT` 会命中 `FT Island` 这种**歌名自己**；
    /// - **`feat` / `featuring` 认完整一个词**（前后要有分隔）：宁可少砍 ——
    ///   少砍只是"多试一个词"，错砍是"拿着半截歌名去搜"，后者会搜出一个完全不相干的版本。
    private static let featurePattern = #"(?i)(?:\b(feat|featuring)\b|\bft\.)"#
}

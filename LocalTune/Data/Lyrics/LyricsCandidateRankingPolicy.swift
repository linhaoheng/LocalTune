import Foundation

/// 搜索候选**怎么排** —— 纯函数、零 UIKit、能离线单测。
///
/// ## 🔴 为什么只能排、不能筛（与 Cosmos 的根本差别）
///
/// 参考工程 Cosmos 是**全自动定夺**（它必须自己选一条），所以它有一整套严格闸门
/// （艺人相似度 `< 0.5` 毙掉、歌名 `< 0.34` 毙掉、时长差 `> 25s` 毙掉）＋"够
/// `confidentMatchScore` 就停手"。
/// 我们是**把候选摆给用户挑**——
/// 只要排得合理就行，**偷偷删掉不像的候选反而会挡掉用户真正想找的那个版本**。
/// ⇒ **三道闸一条都不搬**（只取它的**加权配比**与**时长这一维的函数**）。
///
/// ## 打分口径（照 Cosmos `LyricsManager.matchScore:856`）
///
/// `歌名 × 0.45 ＋ 艺人 × 0.35 ＋ 时长 × 0.20`
/// （Cosmos 还有一档「专辑相似度 `>= 0.8` ⇒ `＋0.05`」的加分，我们**不采** ——
/// 专辑名是投稿人自己填的，当排序项会把"同名不同专辑"的候选顺序搅乱。）
///
/// 同分**维持服务端返回的顺序** —— 那是站点自己的相关度，别用一次不稳定的排序把它搅乱。
///
/// ⚠️ AMLL 源的搜索返回里**没有时长字段**，用不上这一维；
/// 酷狗**带时长** ⇒ 这一维回来了。
enum LyricsCandidateRankingPolicy {

    /// 歌名在总分里的权重（Cosmos 原值）。
    static let titleWeight = 0.45

    /// 艺人在总分里的权重（Cosmos 原值）。
    static let artistWeight = 0.35

    /// 时长在总分里的权重（Cosmos 原值）。
    static let durationWeight = 0.2

    // MARK: - 排序

    /// 候选按与本曲的相似度**降序**；同分保持传进来的顺序。
    ///
    /// - Parameters:
    ///   - candidates: 服务端返回的顺序。
    ///   - title: 本地这一首的歌名。
    ///   - artists: 本地这一首的艺人。
    ///   - durationSeconds: 本地这一首的时长（**秒**）；`nil` ⇒ 时长那一维**不参与**
    ///     （见 `durationScore` —— 它会给所有人同一个中性分，等于不影响排序）。
    static func ranked(
        _ candidates: [LyricsSearchResult],
        title: String,
        artists: [String],
        durationSeconds: Double?
    ) -> [LyricsSearchResult] {
        // ⚠️ 写成显式循环、不写成一条链：链式 `enumerated().map{…}.sorted{…}` 会让
        // 类型推断爆掉（"unable to type-check this expression in reasonable time"）。
        var rows: [Row] = []
        rows.reserveCapacity(candidates.count)
        for (order, candidate) in candidates.enumerated() {
            let value = score(
                candidate, title: title, artists: artists, durationSeconds: durationSeconds
            )
            rows.append(Row(order: order, candidate: candidate, score: value))
        }
        // ⚠️ Swift 的 `sorted` **不保证稳定**，所以同分得自己拿服务端序号兜。
        rows.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.order < rhs.order : lhs.score > rhs.score
        }
        return rows.map { $0.candidate }
    }

    /// 一条候选与本曲的总分（0…1）。
    static func score(
        _ candidate: LyricsSearchResult,
        title: String,
        artists: [String],
        durationSeconds: Double?
    ) -> Double {
        similarity(title, candidate.title) * titleWeight
            + bestArtistSimilarity(artists, candidate.artists) * artistWeight
            + durationScore(
                candidateSeconds: candidate.durationSeconds, targetSeconds: durationSeconds
            ) * durationWeight
    }

    // MARK: - 时长这一维（照 Cosmos `LyricsManager.durationScore`）

    /// 两条时长差多少 ⇒ 0…1。**单位都是秒**。
    ///
    /// 照 Cosmos 原样：
    /// - 任何一边没有时长 ⇒ **中性 `0.5`**（"没有证据就别罚"，不是拿 `0` 顶上）；
    /// - 差 `≤ 2s` ⇒ `1`；差 `≥ 15s` ⇒ `0`；中间线性下滑。
    ///
    /// ⚠️ Cosmos 那三道硬闸（`> 25s` ⇒ 整条 `0` 之类）**不搬** —— 我们只排不筛。
    static func durationScore(candidateSeconds: Int, targetSeconds: Double?) -> Double {
        guard let targetSeconds, targetSeconds > 0, candidateSeconds > 0 else { return 0.5 }

        let delta = abs(Double(candidateSeconds) - targetSeconds)
        if delta <= 2 { return 1 }        // Cosmos 自己给的那档容差
        if delta >= 15 { return 0 }
        return 1 - ((delta - 2) / 13)
    }

    // MARK: - 相似度

    /// 两串的相似度：完全相等 `1.0` · 一方含另一方 `0.9` · 否则按词的 Jaccard。
    ///
    /// 归一化（小写 / 去变音符 / 剥 `feat.` 从句与 `live`、`remaster` 一类修饰 /
    /// 非字母数字转空格）照 Cosmos 的 `matchKey` 思路 —— 那边是为了**自动定夺**，
    /// 我们只为**排序**，所以阈值宽松、不做毙掉。
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalizedKey(lhs)
        let right = normalizedKey(rhs)
        if left.isEmpty || right.isEmpty { return 0 }
        if left == right { return 1 }
        if left.contains(right) || right.contains(left) { return 0.9 }

        let leftWords = tokens(of: left)
        let rightWords = tokens(of: right)
        let union = leftWords.union(rightWords)
        guard !union.isEmpty else { return 0 }
        return Double(leftWords.intersection(rightWords).count) / Double(union.count)
    }

    /// 归一化：`"晴天 (Live) feat. 张三"` → `"晴天"` 这一类的形式。
    static func normalizedKey(_ raw: String) -> String {
        var text = raw.folding(
            options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
            locale: Locale(identifier: "zh_Hans_CN")
        )
        // `feat.` / `ft.` / `with` 从句之后全是对歌名无用的署名。
        text = text.replacingOccurrences(
            of: #"(?i)\b(feat|ft|featuring|with)\b.*$"#, with: " ", options: .regularExpression
        )
        // 版本修饰词：只是同一个名字的不同录音，不该把相似度拉低。
        text = text.replacingOccurrences(
            of: #"(?i)\b(remaster(ed)?|remix|live|version|edit|mix|acoustic|instrumental|demo|cover)\b"#,
            with: " ", options: .regularExpression
        )
        let mapped = text.map { character -> Character in
            (character.isLetter || character.isNumber) ? character : " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    // MARK: - 私有

    private struct Row {
        let order: Int
        let candidate: LyricsSearchResult
        let score: Double
    }

    /// 两边艺人集合里**最像的一对** —— 合唱曲目只要有一个对得上就算数。
    ///
    /// 有一边**完全没有艺人** ⇒ `0`：没有证据表明是同一个版本，不如把有艺人的那几条排前面。
    private static func bestArtistSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        let left = lhs.filter { !$0.isEmpty }
        let right = rhs.filter { !$0.isEmpty }
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        var best = 0.0
        for one in left {
            for other in right {
                best = max(best, similarity(one, other))
            }
        }
        return best
    }

    /// 切成"词"。**中日韩文字逐字拆开** —— 中文歌名基本不含空格，整串当一个词的话
    /// Jaccard 只可能算出 0（既不相等也不互相包含时），等于白算。
    private static func tokens(of key: String) -> Set<String> {
        var result: Set<String> = []
        for chunk in key.split(separator: " ") {
            var latin = ""
            for character in chunk {
                if isCJK(character) {
                    if !latin.isEmpty {
                        result.insert(latin)
                        latin = ""
                    }
                    result.insert(String(character))
                } else {
                    latin.append(character)
                }
            }
            if !latin.isEmpty { result.insert(latin) }
        }
        return result
    }

    /// 汉字 / 假名 —— 这些文字要逐字算。
    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)      // 汉字扩展 A
                || (0x4E00...0x9FFF).contains(scalar.value)   // 基本汉字
                || (0x3040...0x30FF).contains(scalar.value)   // 平假名 / 片假名
                || (0xF900...0xFAFF).contains(scalar.value)   // 兼容汉字
        }
    }
}

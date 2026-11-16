import Foundation

/// 拿**哪个词**去封面源搜 —— 纯函数、零 `UIKit`、能离线单测。
///
/// ## 🔴 它跟歌词那份**不是一回事**（`获取封面设计.md` §十一 已定 2）
///
/// 两边都叫"回落"，但**降级的理由正好相反**：
///
/// | | 版本标记（`(Live)` / `feat.`）算什么 | 所以怎么回落 |
/// |---|---|---|
/// | 歌词 | **噪声** —— 要的是"这一版"的词，标记只会让搜索跑偏 | 三档：`歌名 艺人` → 歌名 → **歌名主干**（剥掉标记） |
/// | 封面 | **信息** —— `晴天` 与 `晴天 (Live)` 的**封面本来就不是同一张** | 两档：`歌名 艺人` → 歌名（**不剥**） |
///
/// ⇒ 这就是"各写一份"的实质：**不是凑合，是两件事本来就不同**。
/// 共用一份的话，要么歌词搜不准，要么封面把 Live 版那张图配到录音室版上。
///
/// ⚠️ 回落**只在"真没搜到"时往下走**。「连不上」不往下试 ——
/// 那不是"这首没封面"的证据（`CoverSearchError` 那条纪律）。
enum CoverSearchQueryPolicy {

    /// 依次要试的词（去空 ＋ 去重，顺序即优先级）。
    ///
    /// - Parameters:
    ///   - title: 本地这一首的歌名。
    ///   - artist: 本地这一首的艺人；没有就传空串（那一档自然消失）。
    static func candidates(title: String, artist: String) -> [String] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        var raw: [String] = []
        // 第一个是**最准的**：实测酷狗搜「晴天 周杰伦」第一条就是 `叶惠美` 原版。
        if !trimmedTitle.isEmpty && !trimmedArtist.isEmpty {
            raw.append("\(trimmedTitle) \(trimmedArtist)")
        }
        // 第二个是**兜底**：本地标签里的艺人是错的 / 空的时，只拿歌名再试一次。
        // ⚠️ 到此为止 —— 不再往下剥版本标记（见上面那张表）。
        raw.append(trimmedTitle)

        var result: [String] = []
        for keyword in raw where !keyword.isEmpty {
            guard !result.contains(keyword) else { continue }
            result.append(keyword)
        }
        return result
    }
}

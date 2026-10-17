import Foundation

/// 酷狗**搜歌**返回里的一条候选 —— 值，零行为。
///
/// ## 🔴 主键是 `hash`（不是别的）
///
/// 搜词与下载都要它，而 `Lyricify` 那边"不带 `hash` 搜词会搜出另一批候选"
/// ⇒ 它一路带到下载。
///
/// ## 🔴 时长是新拿到的东西
///
/// 酷狗搜索**带时长**（`duration`，**整数秒**），而 AMLL 那条路**没有**
/// —— 没有这一维时，「同名不同版本（live / 翻唱）」没有任何技术闸，只能靠专辑名让用户自己认。
/// 现在时长进了排序，列表也显示它。
///
/// ## 艺人的拆法
///
/// 按 `、` 拆开，显示时再用 `、` 拼回去（两个方向一致，看不出差别）——
/// 跟 `Lyricify` 的做法一致。
struct LyricsSearchResult: Equatable {

    /// 搜词与下载的键。空串 ⇒ 这条不可用（列表置灰）。
    let hash: String

    /// 歌名（`songname`）。**空标题的条目一律不收**（`init?(json:)` 里就挡掉）。
    let title: String

    /// 艺人（`singername`，按 `、` 拆开）。可能多个（合唱），也可能为空。
    let artists: [String]

    /// 专辑（`album_name`）。空串 = 没填。
    let album: String

    /// 时长（`duration`，**整数秒** —— 搜歌结果给的就是秒，不是毫秒）。
    let durationSeconds: Int

    /// 这一条**能不能取词** —— 列表拿它决定置不置灰。
    var isDownloadable: Bool { !hash.isEmpty }

    /// 搜词时要带上的时长（毫秒）—— 那边的接口吃毫秒。
    var durationMs: Int { durationSeconds * 1000 }

    /// 列表副行：`艺人 · 专辑 · 时长`（缺哪个省哪个）。
    var subtitle: String {
        var parts: [String] = []
        let joinedArtists = artists.filter { !$0.isEmpty }.joined(separator: "、")
        if !joinedArtists.isEmpty { parts.append(joinedArtists) }
        if !album.isEmpty { parts.append(album) }
        if durationSeconds > 0 { parts.append(durationText) }
        return parts.joined(separator: " · ")
    }

    /// 时长的显示形态：`4:29`。
    var durationText: String {
        String(format: "%d:%02d", durationSeconds / 60, durationSeconds % 60)
    }
}

// MARK: - 从站点 JSON 里读出来

extension LyricsSearchResult {

    /// 搜歌返回里的一条（`data.info[]` 的一条）→ 值。
    /// **读不出歌名 ⇒ `nil`**（宁可不显示，也不显示一条空的）。
    init?(json: [String: Any]) {
        guard let title = Self.text(json["songname"]), !title.isEmpty else { return nil }

        let singer = Self.text(json["singername"]) ?? ""
        self.hash = Self.text(json["hash"]) ?? ""
        self.title = title
        self.artists = singer.components(separatedBy: "、").filter { !$0.isEmpty }
        self.album = Self.text(json["album_name"]) ?? ""
        self.durationSeconds = (json["duration"] as? NSNumber)?.intValue ?? 0
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

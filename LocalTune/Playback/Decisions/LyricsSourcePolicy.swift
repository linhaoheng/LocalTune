import Foundation

/// 「这首歌现在该显示哪一份歌词」—— **唯一的判断处**。
///
/// ## 优先级
///
/// 1. `customLyrics` —— 「编辑歌词」页写的自定义层（**非空即优先**）；
/// 2. 内嵌 `lyrics` —— 音频标签里读到的那一份。
///
/// 空串 ＝ **没有自定义层**（落回内嵌）。v2 只有这一列；不另加「有没有层」的 flag。
///
/// 🔴 **没有 `.lrc` 侧车层**：还有一种做法是加一层 `.lrc` 侧车、排在中间，我们**明确不做**
/// （既有口径 —— 只保留内嵌歌词 ＋ 自定义层），所以这里只有两级。
///
/// **为什么单独一个类型**：它是一处**判断**，按宪法 §三·判断归位要写成**纯函数**、能脱离 UIKit 单测；
/// 而且**只有这一处**知道"两份歌词谁优先" —— 播放页、锁屏、以后任何地方都从这儿取，不各写各的。
enum LyricsSourcePolicy {

    /// 取这一刻该显示的歌词原文。
    ///
    /// - 判空**按 trim 后**算（全空白 ＝ 没有），但**返回原文**（不 trim 掉用户的排版）。
    /// - 返回 `nil` ＝ **一句都没有**（界面该走空态）。
    static func text(customLyrics: String, lyrics: String?) -> String? {
        if !customLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customLyrics
        }
        let embedded = lyrics ?? ""
        if !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return embedded
        }
        return nil
    }

    /// 便捷：从「一首歌 ＋ 它的内嵌歌词」里取（`track` 为 `nil` ＝ 没有歌）。
    ///
    /// ⚠️ **内嵌那份要由调用方单独给** —— 它住在侧表（`TrackLyrics`），**不在 `Track` 上**
    /// `Track` 是窄行；`customLyrics` 那一半还在 `Track` 上。
    /// 🔴 判断本身**一个字没变** —— 还是上面那个吃两个字符串的重载。
    static func text(for track: Track?, lyrics: TrackLyrics?) -> String? {
        guard let track else { return nil }
        return text(customLyrics: track.customLyrics, lyrics: lyrics?.lyrics)
    }
}

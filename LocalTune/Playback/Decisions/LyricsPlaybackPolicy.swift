import Foundation

/// 「现在该高亮第几行」。
///
/// 纯函数：吃一组行 + 一个播放时间，吐一个行号 —— 不订播放器、不碰界面
/// 播放时间由调用方从 `PlayManager.position` 取。
///
/// 抄的是 **primuse** `LyricPlaybackPositionPolicy`
/// （`PrimuseKit/Sources/PrimuseKit/LyricRowFrameBatchPolicy.swift:59`）。
enum LyricsPlaybackPolicy {

    /// 现在该高亮第几行 —— 「最后一个时间 ≤ 播放时间」的那一行。
    ///
    /// 播放时间还没到第一句 → `nil`（第一句之前不该有高亮）。
    /// `lookahead`（提前量）让高亮早一点点跳，唱起来更跟手。
    ///
    /// 传进来的行**必须已经按时间排好**（`LyricsParser` 保证）。
    static func activeLineIndex(
        in lyrics: [LyricsLine],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0
    ) -> Int? {
        guard !lyrics.isEmpty else { return nil }

        let target = playbackTime + lookahead
        var lower = lyrics.startIndex
        var upper = lyrics.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lyrics[middle].timestamp <= target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > lyrics.startIndex else { return nil }
        return lower - 1
    }

    /// 同一个判据的**编辑器侧那一份** —— 吃的是「行顺序 ＋ 可能还没打轴（`nil`）」。
    ///
    /// 为什么不能二分：编辑器的行是**文档顺序**、而且夹着 `nil`（没打轴的行）；
    /// 二分要的"全体有序"两条都不成立 ⇒ 只能线性扫。
    /// 判据本身与上面那条**是同一条**：**最后一个时间 ≤ 播放时间**的行；一个都没到 ⇒ `nil`。
    ///
    /// （`nil` 的行跳过、继续往后扫 —— 文档顺序里未打轴的行不该截断后面的判断。）
    static func activeLineIndex(
        inOrderedTimestamps timestamps: [TimeInterval?],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0
    ) -> Int? {
        let target = playbackTime + lookahead
        var result: Int?
        for (index, time) in timestamps.enumerated() {
            guard let time, time <= target else { continue }
            result = index
        }
        return result
    }
}

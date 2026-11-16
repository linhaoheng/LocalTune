import Foundation

/// 小组件歌词的纯判断与排表 —— 只吃值、吐值，不碰流、不碰盘（可单测）。
///
/// 它是**小组件入口自己的判断**：
/// 吃吐都是小组件通道自己的 `WidgetLyricLine` / 展示行，主 App 和扩展都要用，
/// 所以跟通道模型住在 `App/Widget/`。
///
/// ⚠️ 「播放域歌词行 → 通道行」的翻译（只留同步行）在**发布者**那侧 ——
/// 它吃的是播放域的 `LyricsLine`，翻译完了才上通道，本文件不认识播放域的值。
enum WidgetLyricsPolicy {

    /// 某一时刻该从第几行往后看。
    ///
    /// 返回**最后一个** `time <= 播放时刻` 的行号；还没唱到第一句时给 `0`
    /// —— 窗口从第一行开始等着，比空着好；没行可给才返回 `nil`。
    static func currentIndex(at time: TimeInterval, in lines: [WidgetLyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        var result = 0
        for (index, line) in lines.enumerated() where line.time <= time {
            result = index
        }
        return result
    }

    /// 从当前行往后取最多 `maxLines` 行正文：剔空白行、剔译文注音
    /// （`WidgetLyricLine` 里本来就没有）。
    static func displayWindow(
        from lines: [WidgetLyricLine],
        currentIndex: Int?,
        maxLines: Int
    ) -> [String] {
        guard let currentIndex else { return [] }
        return lines.dropFirst(currentIndex)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxLines)
            .map { $0 }
    }

    // MARK: - 时间线排表

    /// 未来歌词切换的**绝对时刻表**（升序，最多 `limit` 个）。
    ///
    /// 锚点换算：快照落盘那一刻（`savedAt`）播放头在 `elapsed` 秒，那么
    /// 「歌词第 `line.time` 秒」在墙上的绝对时刻就是 `savedAt + (line.time − elapsed)`。
    /// 已经唱过（不晚于 `after`）的行不排 —— 排进去只会被系统立刻跳过。
    static func upcomingSwitchTimes(
        lines: [WidgetLyricLine],
        elapsed: TimeInterval,
        savedAt: Date,
        after: Date,
        limit: Int
    ) -> [Date] {
        guard limit > 0 else { return [] }
        return lines
            .map { savedAt.addingTimeInterval($0.time - elapsed) }
            .filter { $0 > after }
            .sorted()
            .prefix(limit)
            .map { $0 }
    }

    /// 一批时间线 entry 的排法：`dates` 升序（首项是 `now`），
    /// `nextBatchAfter` 是这一批用完后请系统再来取的时刻 —— `nil` 表示
    /// 后面的切换已经排完，接下来交给主 App 的事件驱动 reload。
    ///
    /// 多取一个当探针，才知道 `maxEntries` 是"排完了"还是"刚好截断"。
    static func timelineBatch(
        lines: [WidgetLyricLine],
        elapsed: TimeInterval,
        savedAt: Date,
        now: Date,
        maxEntries: Int
    ) -> (dates: [Date], nextBatchAfter: Date?) {
        let upcoming = upcomingSwitchTimes(
            lines: lines,
            elapsed: elapsed,
            savedAt: savedAt,
            after: now,
            limit: maxEntries + 1
        )
        let batch = Array(upcoming.prefix(maxEntries))
        let dates = [now] + batch
        guard upcoming.count > maxEntries else {
            return (dates: dates, nextBatchAfter: nil)
        }
        return (dates: dates, nextBatchAfter: batch.last)
    }
}

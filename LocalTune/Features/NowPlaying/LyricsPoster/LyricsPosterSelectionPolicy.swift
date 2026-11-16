import Foundation

/// 为什么这一行**接不进**当前选段。界面拿它给一句人话，而不是默默没反应
enum LyricsPosterSelectionRejection: Hashable {
    /// 选段已经满 `LyricsPosterSelectionPolicy.maximumLines` 行。
    case limitReached
    /// 海报只放**一段连续**的话；点的这一行跟当前选段不挨着。
    case notAdjacent
}

/// 一次点选之后的结果：新的选段 ＋（可能的）拒绝原因。
struct LyricsPosterSelectionResult: Hashable {
    let selection: [String]
    let rejection: LyricsPosterSelectionRejection?

    init(selection: [String], rejection: LyricsPosterSelectionRejection? = nil) {
        self.selection = selection
        self.rejection = rejection
    }
}

/// 把一份歌词文档收成"能上海报的一段"。
///
/// 选段**刻意限制成一段连续的话**：拼几句不相干的话上海报，读起来像一句从没那样唱过的
/// 引语；动态海报的时间线也没法跳过中间的空档。
enum LyricsPosterSelectionPolicy {

    /// 一张海报的上限。再多，字号就掉到分享出去的截图看不清了。
    static let maximumLines = 8

    /// 能上海报的行：有正文的才算。纯文本歌词照样能选 —— 只是它带不动动态时间线。
    static func selectableLines(from lyrics: [LyricsLine]) -> [LyricsPosterLine] {
        var result: [LyricsPosterLine] = []
        for line in lyrics {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result.append(LyricsPosterLine(index: result.count, line: line))
        }
        return result
    }

    /// 从播放页进来时默认选哪句：**当前正唱的那句**；还没开播就选第一句。
    static func defaultSelection(
        in lines: [LyricsPosterLine],
        playbackPosition: TimeInterval
    ) -> [String] {
        guard let anchor = anchorIndex(in: lines, playbackPosition: playbackPosition) else {
            return []
        }
        return [lines[anchor].id]
    }

    static func anchorIndex(
        in lines: [LyricsPosterLine],
        playbackPosition: TimeInterval
    ) -> Int? {
        guard !lines.isEmpty else { return nil }
        var anchor = 0
        for (index, line) in lines.enumerated()
        where line.isSynchronized && line.timestamp <= playbackPosition {
            anchor = index
        }
        return anchor
    }

    /// 加上或去掉 `id`，始终让选段保持一段连续。
    ///
    /// 取消选段**内部**的一行会把它劈成两段，所以点内部时改成"向短的一侧裁"。
    static func toggling(
        _ id: String,
        in lines: [LyricsPosterLine],
        selection: [String]
    ) -> LyricsPosterSelectionResult {
        guard let target = lines.firstIndex(where: { $0.id == id }) else {
            return LyricsPosterSelectionResult(selection: selection)
        }
        guard let range = selectedRange(in: lines, selection: selection) else {
            return LyricsPosterSelectionResult(selection: [lines[target].id])
        }

        if range.contains(target) {
            if range.count == 1 {
                return LyricsPosterSelectionResult(selection: [])
            }
            let trimmed: ClosedRange<Int>
            if target == range.lowerBound {
                trimmed = (range.lowerBound + 1)...range.upperBound
            } else if target == range.upperBound {
                trimmed = range.lowerBound...(range.upperBound - 1)
            } else if target - range.lowerBound <= range.upperBound - target {
                // 点内部：留下更长的那半，一下点击不该把辛苦拼好的一段丢掉大半。
                trimmed = target...range.upperBound
            } else {
                trimmed = range.lowerBound...target
            }
            return LyricsPosterSelectionResult(selection: ids(of: trimmed, in: lines))
        }

        guard target == range.lowerBound - 1 || target == range.upperBound + 1 else {
            return LyricsPosterSelectionResult(selection: selection, rejection: .notAdjacent)
        }
        guard range.count < maximumLines else {
            return LyricsPosterSelectionResult(selection: selection, rejection: .limitReached)
        }
        let extended = min(range.lowerBound, target)...max(range.upperBound, target)
        return LyricsPosterSelectionResult(selection: ids(of: extended, in: lines))
    }

    /// 点这一行会不会把选段接长。选句页据此压暗够不着的行。
    static func canExtend(
        to id: String,
        in lines: [LyricsPosterLine],
        selection: [String]
    ) -> Bool {
        guard let target = lines.firstIndex(where: { $0.id == id }) else { return false }
        guard let range = selectedRange(in: lines, selection: selection) else { return true }
        if range.contains(target) { return true }
        guard range.count < maximumLines else { return false }
        return target == range.lowerBound - 1 || target == range.upperBound + 1
    }

    /// 把选中的那一段收成海报要画的内容。
    static func content(
        songTitle: String,
        artistName: String?,
        albumTitle: String?,
        year: Int?,
        lines: [LyricsPosterLine],
        selection: [String]
    ) -> LyricsPosterContent {
        let selected: [LyricsPosterLine]
        if let range = selectedRange(in: lines, selection: selection) {
            selected = Array(lines[range])
        } else {
            selected = []
        }
        return LyricsPosterContent(
            songTitle: songTitle,
            artistName: artistName?.isEmpty == false ? artistName : nil,
            albumTitle: albumTitle?.isEmpty == false ? albumTitle : nil,
            year: year,
            lines: selected
        )
    }

    /// `selection` 覆盖的那一段。认不出的 id 直接忽略 —— 换歌之后残留的旧选段
    /// 不能把已经不存在的行又变出来。
    static func selectedRange(
        in lines: [LyricsPosterLine],
        selection: [String]
    ) -> ClosedRange<Int>? {
        let selectedIDs = Set(selection)
        let indices = lines.indices.filter { selectedIDs.contains(lines[$0].id) }
        guard let first = indices.first, let last = indices.last else { return nil }
        return first...last
    }

    private static func ids(of range: ClosedRange<Int>, in lines: [LyricsPosterLine]) -> [String] {
        range.map { lines[$0].id }
    }
}

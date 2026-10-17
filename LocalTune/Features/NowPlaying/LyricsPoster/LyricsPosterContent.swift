import Foundation

/// 海报上的一行歌词。
///
/// 时间戳留着是为了动态海报能按歌曲原来的节奏逐句点亮；静态海报用不到，
/// 但两档共用同一份内容，所以一并带着。
struct LyricsPosterLine: Identifiable, Hashable {

    /// 在这一份快照里的位置。快照是**值**、开着面板时用户切歌也不变，
    /// 所以序号本身就是稳定身份 —— 不需要另外编一个 id。
    let id: String

    let text: String
    let timestamp: TimeInterval
    /// 这一行唱到几秒结束。行级歌词推不出来才是 `nil`（`LyricsLine` 只给整行的起点）。
    let endTimestamp: TimeInterval?
    /// 这一行有没有真实时间。纯文本歌词没有 —— 动态海报只能给它均分的节奏。
    let isSynchronized: Bool

    /// 从我们的一行歌词取下来。**剥掉逐字明细**：海报按整行点亮，用不到逐字。
    ///
    /// ⚠️ 空白行不进来（由 `LyricsPosterSelectionPolicy.selectableLines` 过滤），
    /// 所以这里拿到的 `text` 一定有内容。
    init(index: Int, line: LyricsLine) {
        let syllables = line.syllables ?? []
        self.id = String(index)
        self.text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timestamp = line.timestamp
        // 逐字行里最后一个音的结束时间就是这一行的结束；行级歌词没有这个信息。
        self.endTimestamp = syllables.last.map(\.end)
        self.isSynchronized = line.isSynchronized
    }
}

/// 一张歌词海报要画的全部内容 —— 一份**快照**，不回头读播放器。
///
/// 🔴 为什么是快照：面板开着的时候用户可能继续听歌、切歌，海报上的词不该跟着变 ——
/// 用户挑的是刚才那几句。所以风格实现里**不许**出现任何对播放状态的访问。
struct LyricsPosterContent: Hashable {

    let songTitle: String
    let artistName: String?
    let albumTitle: String?
    let year: Int?
    let lines: [LyricsPosterLine]

    /// 一句都没选。面板据此显示占位、导出按钮据此置灰。
    var isEmpty: Bool { lines.isEmpty }

    /// 选中的每一句都有真实时间。动态海报没有它就只能均分。
    var isSynchronized: Bool {
        !lines.isEmpty && lines.allSatisfy(\.isSynchronized)
    }
}

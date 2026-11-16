import Foundation

/// 「一行歌词里的一个逐字块」—— 编辑页画条子用的**投影**。
///
/// ## 🔴 它不是模型的一部分
///
/// 真数据是 `LyricSyllable`（装在 `LyricsLine.syllables` 里）。这个值只是把它搬成界面上要的
/// 那几个字段（`LyricsEditorViewModel.syllables(inRow:)` 一行 `map` 出来），
/// **不进 `Snapshot`、不缓存** —— 所以不存在"两份表示谁保证一致"的问题。
///
/// ⚠️ 它以前还带正文里的字符范围（`fullRange` / `markerRange`），因为那时是"从正文现解析、
/// 改完把正文写回去"。2026-11-17 起编辑页直接改模型，那两个范围没人读 ⇒ 删。
struct LyricsEditorSyllable: Equatable {

    /// 这个词的字面。**句尾那一格是空串**（正文里不写符号，写进去播放页 / 海报都会冒出来）。
    var text: String

    /// 这个词的起点（秒）。句尾那一格就是「这一句唱到几秒」。
    var start: TimeInterval

    /// 这一项是不是「这一行的结束」那一格，而不是一个字。
    ///
    /// 判据与 `LyricSyllable.isLineEnd` **同一条**：没有文字。只写两处是因为它们是
    /// 两个类型（模型 / 编辑侧投影），不是在两个地方各判一遍业务。
    var isLineEnd: Bool { text.isEmpty }
}

/// 「这一个字的 `±` 还能不能动」的结论 —— `LyricsSyllableTimingPolicy.nudgeRoom` 吐它。
///
/// 判断（`Decisions/LyricsSyllableTimingPolicy.swift`）产它、界面（打轴页 / 逐行页的细条）吃它
/// ⇒ 归 `Model/`（跟 `LyricsLineBlankness` 同一族）。
///
/// ⚠️ 两支键各管一个方向、**互相独立** ⇒ 用「四种组合」的 enum 表达，不吐一对 `Bool`
/// （具名判断的出口返回 enum，不是实现步骤）。
enum NudgeAvailability: Equatable {
    /// 两支都能按。
    case both
    /// 只有「提前」那支能按 —— 上界（后一个字）顶住了。
    case decreaseOnly
    /// 只有「延后」那支能按 —— 下界（前一个字 / 句子时间）顶住了。
    case increaseOnly
    /// 两支都到界了。
    case none

    /// 「提前」那支能不能按。
    var canDecrease: Bool { self == .both || self == .decreaseOnly }

    /// 「延后」那支能不能按。
    var canIncrease: Bool { self == .both || self == .increaseOnly }
}

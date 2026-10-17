import Foundation

/// 「一行正文里的一个逐字标记」—— 从一个 `<mm:ss.xx>` 切出来的一个词。
///
/// ## 🔴 它不是模型的一部分
///
/// `LyricsEditorLine` **只有 `time` + `text`**，
/// 逐字**不进模型**。这个值只是**从那一行正文现解析出来的一张脸**，用完就扔 ——
/// 所以不存在"两份表示谁保证一致"的问题（铁律那条一致性不变量）。
///
/// ⚠️ 因此它**不进 `Snapshot`、不缓存**：界面每次重画现算一遍。
struct LyricsEditorSyllable: Equatable {

    /// 这个词的字面（标签后面那段文字，两端空白已去掉）。
    var text: String

    /// 这个词的起点（秒）。
    var start: TimeInterval

    /// **整段**（含开头的 `<mm:ss.xx>` 标签）在这一行正文里的范围 —— 界面上点它 = 跳到这个字。
    var fullRange: NSRange

    /// **只含** `<mm:ss.xx>` 标签的范围 —— 改时间就是换掉这一段字节，别的一个不动。
    var markerRange: NSRange
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

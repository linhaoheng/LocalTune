import Foundation

/// 「编辑歌词」页里的一行 —— **只有「时间 + 正文」**。
///
/// 🔴 **只有这两个字段是刻意的**：
/// 常见的逐字歌词模型会挂着 `isKaraoke` / `karaokeData` 一类「逐字模型」字段 ——
/// 那是**改参考工程时自己加的、`export` 里根本没用上**（纯冗余），**一件都不抄**。
///
/// ⚠️ 「逐字标记」不会因为模型窄就丢：行内那些 `<mm:ss>` 标签被当成**正文原样保留**
/// （`LyricsEditorPolicy.parse` 只剥**行首那一个** `[mm:ss.xx]`），所以 4d 的逐字显示不受影响。
///
struct LyricsEditorLine: Equatable {

    /// 行首时间轴的**秒数**；`nil` ＝ **这一行还没打轴**。
    ///
    /// 🔴 用 `TimeInterval?`、不用 `0` 兜：「没有时间」和「时间是 0」是两件事 ——
    /// 打轴面板上「N 句未打轴」那一行、保存前的问题清单，全靠这个 `nil` 才认得出来。
    var time: TimeInterval?

    /// 正文 —— **原样保留**：行内标签、空格、标点，一个都不动。
    var text: String
}

/// 一行歌词可能有的问题。
///
/// 🔴 **只有这四种**：空 / 未打轴 / 时间倒序 / 时间重复。
///
/// ⚠️ 参考工程里还有第五种「带时间轴」（行内有逐字 `<时间>` 标签就报一条）—— 那是自加的逐字模型
/// 的一部分，**不要**：我们的做法是**原样保留**行内标记，本来就没什么可报的。
enum LyricIssueKind: Equatable, CaseIterable {

    /// 整行全是空白。
    case empty

    /// 有正文，但这一行还没打轴。
    case untimed

    /// 时间比**上一句已打轴的**还早。
    case reversed

    /// 时间（按厘秒量化之后）跟前面某一行**撞了**。
    case duplicate

    /// 行内角标上那个词，也是保存确认弹窗里每条问题的词。
    ///
    /// ⚠️ 别的实现里 CN 文案用「线」（「N线，未打轴」），我们**统一说「行」** ——
    /// 跟本工程其它地方的说法一致。
    var label: String {
        switch self {
        case .empty: return "歌词为空"
        case .untimed: return "未打轴"
        case .reversed: return "时间倒序"
        case .duplicate: return "时间重复"
        }
    }
}

/// 「这一行有没有正文」的结论 —— `LyricsEditorPolicy.isBlank` 吐它。
///
/// 判断（`Decisions/LyricsEditorPolicy.swift`）产它 ⇒ 归 `Model/`（跟 `LyricIssueKind` 同一族）。
///
/// ⚠️ 这里**只有一种「没有」**（全是空白）—— 仍返回 enum（具名判断的出口，不是实现步骤）。
enum LyricsLineBlankness: Equatable {
    /// 整行全是空白。
    case blank
    /// 有正文。
    case hasText
}

/// 「用户实际改过没有」的结论 —— `LyricsEditorPolicy.isEdited` 吐它。
///
/// 判断（`Decisions/LyricsEditorPolicy.swift`）产它、界面（`LyricsEditorViewModel` 的「保存」键 /
/// 关页确认）吃它 ⇒ 归 `Model/`。
///
/// ⚠️ 这里**只有一种「改过」** —— 按宪法 §三·判断归位 2 仍返回 enum（具名判断的出口，非实现步骤）。
enum LyricsEditState: Equatable {
    /// 跟打开时一模一样 —— 没有要保存的东西。
    case unchanged
    /// 动过了。
    case edited
}

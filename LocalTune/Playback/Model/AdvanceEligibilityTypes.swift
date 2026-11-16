import Foundation

/// 「一首放完了，该不该往后走」的结论 —— `advanceEligibility` 吐它。
///
/// 判断（`Decisions/AdvanceEligibilityPolicy.swift`）产它、执行（`PlayManager.handleFinished`）吃它
/// ⇒ 归 `Model/`。
///
/// 🔴 **为什么不是一个 `Bool`**：两种「不走」的含义不同 ——
/// **这一首压根没放成**（`.failed`）和**已经不在播了**（暂停 / 停过 / 还没起）。
/// 它们在排查时指向完全不同的方向，压成一个 `false` 就分不出来了。
///
/// 📌 往后加「音频打断 / 拔耳机 / 引擎卡死」这类分支时，往这里加 case，
/// 不要回到 `PlayManager` 里堆 `guard`。
enum AdvanceEligibility: Equatable {
    /// 往后走一首。
    case advance
    /// 不走 —— 这一轮里先收到了「放不了」，别替用户做他没做的决定。
    case blockedByFailure
    /// 不走 —— 已经不在播了（暂停 / 停过 / 还没起 / 什么都没装）。
    case notPlaying
}

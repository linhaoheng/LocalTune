import Foundation

/// 「一首播完了，该不该往后走」。
///
/// 🔴 **这个判断存在的唯一理由**：库里报「播完」的时候，**我们这边的状态可能已经被别的事改掉了** ——
/// 同一轮里先收到过「放不了」（`.failed`）、用户已经按了暂停、或者这事本来就落在装载中。
/// 那时候再往下走一首，就是**替用户做了他没做的决定**。
///
/// ⚠️ 它只管**自动播完**这一条路；用户按键走 `playNext()`（那条回绕），不经过这里。
///
/// 纯函数：不碰引擎、不碰界面，一个值进、一个值出 —— **能在测试里不带引擎跑一遍**。
/// 吐的 `AdvanceEligibility` 在 `Playback/Model/AdvanceEligibilityTypes.swift`。
func advanceEligibility(status: PlayerState.Status) -> AdvanceEligibility {
    switch status {
    case .playing:
        return .advance
    case .failed:
        // 「听不了」停在原地 —— 和「听完了」是两件事（见 `Status.failed` 的注释）。
        return .blockedByFailure
    case .idle, .loading, .paused, .stopped:
        return .notPlaying
    }
}

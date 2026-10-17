import Foundation

/// 连着几首放不了之后怎么办 —— 输入是值、输出是 enum，**能单测**。
///
/// ⚠️ **为什么不看错误类型**：`PlayerService` 报上来的 `Error` 是引擎自己的错误域，
/// 它的取值我们**还没逐个核过** —— 没核过的东西不拿来当判据（那就成了"凭印象写分支"）。
/// 所以这里用的是**行为**判据：一首坏是意外，连着几首都坏就是环境。
///
/// 吐的 `PlaybackFailureRecovery` 在 `Playback/Model/PlaybackFailureTypes.swift` ——
/// 它**判断和执行都要用**（`PlayManager` 拿它决定跳不跳），所以归最底的 `Model/`。
///
/// - Parameters:
///   - consecutiveFailures: **连着**几首没放成（有一首真的播起来了就归零）。
///   - canAdvance: 队列里还有没有下一首可跳。
///   - limit: 连着几首就放弃。
func playbackFailureRecovery(
    consecutiveFailures: Int,
    canAdvance: Bool,
    limit: Int
) -> PlaybackFailureRecovery {
    guard canAdvance, consecutiveFailures < limit else { return .giveUp }
    return .skipToNext
}

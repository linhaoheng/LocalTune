import Foundation

/// 「库换过去的那首，是不是队列现在说的下一首」。
///
/// 只有**现在排着的那张**、而且它的歌跟队列的下一首一致才认。其余都是**孤儿**：
/// 库在最后约 0.37 秒已经把它取出来解码了（撤不回来），之后用户才改了下一首 ——
/// 队列说了算，所以改道。
///
/// 纯函数：不碰引擎、不碰界面。
/// 吐的 `SuccessorHandover` 在 `Playback/Model/SuccessorHandoverTypes.swift`。
func successorHandover(
    isArmed: Bool,
    armedTrackID: Track.ID?,
    queueNextID: Track.ID?
) -> SuccessorHandover {
    guard isArmed, let armedTrackID, armedTrackID == queueNextID else { return .redirect }
    return .accept
}

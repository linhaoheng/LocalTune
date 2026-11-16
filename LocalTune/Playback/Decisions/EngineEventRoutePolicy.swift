import Foundation

/// 「引擎这条事件是谁的」—— 按号分路。
///
/// 🔴 判据只有号的大小，因为号是**单调递增**发的（`PlayManager` 一个计数器发到底）：
/// 立即播放领一张、排下一首也领一张 ⇒ 比当前小的一定是过去的，比当前大的一定是排过的下一首。
///
/// 纯函数：不碰引擎、不碰界面。
/// 吐的 `EngineEventRoute` 在 `Playback/Model/EngineEventRouteTypes.swift`。
///
/// - Parameters:
///   - ticket: 事件身上贴的号。
///   - current: 正在放的那首的号。
///   - armed: 现在排着的下一首的号；没排 ⇒ `nil`。
func engineEventRoute(ticket: Int, current: Int, armed: Int?) -> EngineEventRoute {
    if ticket < current { return .stale }
    if ticket == current { return .current }
    return .successor(isArmed: ticket == armed)
}

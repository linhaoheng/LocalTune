import Foundation

/// 引擎**报来**的播放态 —— 只有这三种。
///
/// 🔴 **为什么在 `Model/` 而不是 `Decisions/`**：执行（`Player/PlayerService.swift` 把库的
/// `PlaybackState` 翻成它）和判断（`Decisions/PlaybackStatusPolicy.swift` 收它当输入）
/// **两边都用** ⇒ 抽到最底 `Model/`。
///
/// ⚠️ 别和 `PlayerState.Status` 混了：那个是**我们**的状态（六种，含"装载中""放不了"），
/// 这个是**库**说的（三种）。分开写是有意的 —— 库将来加一个态，`switch` 会当场报错，
/// 提醒我们回来重新想「它算在播还是算停」。
///
/// 数值编码**不抄**：库那边是 `stopped(0) / paused(1) / playing(3)`（注意**没有 2**），
/// 这里就是三个 case，没有一个数字。
enum ReportedPlaybackStatus: Equatable {
    case playing
    case paused
    case stopped
}

import Foundation

/// 「现在能不能给库排下一首」。
///
/// 三条都要成立：
/// - **在播 / 暂停**：装载中不排 —— 当前这首要是打开失败，库会自己滑到排着那首，
///   跟"放不了就跳过"（`PlaybackFailurePolicy`）打架；停了 / 放不了 / 没装就更没有"放完接谁"。
/// - **装着的那首就是队列游标上那首**：用户按了下一首，队列游标先走、引擎后换；
///   这个空档里给**旧的那首**排下一首，排的就是错的。
/// - **睡眠没在「等这首完」**：锁着的时候再排下一首，库会在当前这首结束前把后继接上。
///
/// 纯函数：不碰引擎、不碰界面。吐的 `PreloadEligibility` 在 `Playback/Model/PreloadChangeTypes.swift`。
func canPreloadNext(
    status: PlayerState.Status,
    loadedTrackID: Track.ID?,
    queueCurrentID: Track.ID?,
    holdsSuccessor: Bool = false
) -> PreloadEligibility {
    guard !holdsSuccessor else { return .blockedBySleepHold }
    guard status == .playing || status == .paused else { return .notActive }
    guard let loadedTrackID else { return .nothingLoaded }
    return loadedTrackID == queueCurrentID ? .allowed : .engineBehindQueue
}

/// 「库里排着的那首，要怎么改才跟期望的一致」。
///
/// 只比曲目 id：排着的就是期望的 ⇒ 不动。这也覆盖了"排着的那首提前打开失败"——
/// 期望没变就不会马上再排一次、再失败一次；等当前这首放完，普通的"放不了就跳过"会处理它。
///
/// 纯函数：不碰引擎、不碰界面。吐的 `PreloadChange` 在 `Playback/Model/PreloadChangeTypes.swift`。
///
/// - Parameters:
///   - desired: 现在应该排的那首；`nil` ＝ 不该排任何一首。
///   - armedTrackID: 现在排着的那首；`nil` ＝ 没排。
func preloadChange(desired: Track?, armedTrackID: Track.ID?) -> PreloadChange {
    switch (armedTrackID, desired) {
    case (nil, nil):
        return .keep
    case (nil, let desired?):
        return .arm(desired)
    case (_?, nil):
        return .clear
    case (let armedTrackID?, let desired?):
        return armedTrackID == desired.id ? .keep : .replace(desired)
    }
}

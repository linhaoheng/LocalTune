import Foundation

/// 「这条命令 ＋ 现在这个态 ⇒ 该干什么」—— 纯函数，能单测。
///
/// 收的 `RemoteCommand` 和吐的 `RemoteCommandAction` 在
/// `Playback/Model/RemoteCommandTypes.swift` —— 那两个类型**判断和执行都要用**
/// （执行在 `NowPlayingCenter`），所以归最底的 `Model/`。
///
/// 🔴 **为什么 `play` / `pause` 也要判、不能直接扔给 `togglePlayPause()`**：
/// 那两条是**幂等**的语义 —— 「让我开始播」撞上「已经在播」时**不该变成暂停**。
/// 而 `PlayManager.togglePlayPause()` 干的正是"切一下"，直接转过去就会把歌停掉。
///
/// 循环 / 随机怎么落到四档，见 `RemotePlaybackModePolicy`。
///
/// ⚠️ 每个 `switch` 都**列全、不写 `default`** —— `Status` 将来多一个态，这里当场编译不过，
/// 逼我们回来重新想「那个态下这几条命令算什么」。
func remoteCommandAction(
    for command: RemoteCommand,
    status: PlayerState.Status,
    playbackMode currentMode: PlaybackMode
) -> RemoteCommandAction {
    switch command {
    case .nextTrack:
        return status == .idle ? .noActionableItem : .next

    case .previousTrack:
        return status == .idle ? .noActionableItem : .previous

    case .togglePlayPause:
        return status == .idle ? .noActionableItem : .togglePlayPause

    case .play:
        switch status {
        case .idle:
            return .noActionableItem
        case .playing, .loading:
            return .ignore
        case .paused, .stopped, .failed:
            return .togglePlayPause
        }

    case .pause:
        switch status {
        case .idle:
            return .noActionableItem
        case .playing:
            return .togglePlayPause
        case .loading, .paused, .stopped, .failed:
            return .ignore
        }

    case .changePlaybackPosition(let time):
        guard status != .idle else { return .noActionableItem }
        guard time.isFinite else { return .ignore }
        return .seek(time)

    case .like(let wantsFavorite):
        return status == .idle ? .noActionableItem : .setFavorite(wantsFavorite)

    case .changeRepeatMode(let face):
        guard status != .idle else { return .noActionableItem }
        return .setPlaybackMode(playbackMode(afterRemoteRepeat: face, current: currentMode))

    case .changeShuffleMode(let face):
        guard status != .idle else { return .noActionableItem }
        return .setPlaybackMode(playbackMode(afterRemoteShuffle: face, current: currentMode))
    }
}

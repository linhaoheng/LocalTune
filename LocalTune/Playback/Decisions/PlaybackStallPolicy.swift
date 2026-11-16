import Foundation

/// 一次进度读数对「在播但卡住」窗的结论。
///
/// 出处：Cosmos `noteObservedPlaybackTime`；设计：`播放错误与卡死恢复设计.md` §4.2。
///
/// - Parameters:
///   - intentPlaying: 上层意图是否在播（`PlayerState.status == .playing`）。
///   - successorArmed: 是否已给库排了后继（换歌边界位置停住是正常的）。
///   - lastTime: 上次记下的秒数；没有观察过用负数。
///   - currentTime: 这一拍的秒数。
///   - lastAdvanceAt: 上次位置真的前进的时刻。
///   - now: 这一拍的时刻。
///   - window: 多久不动算卡死。
///   - epsilon: 小于这个差不算动了。
func stallTick(
    intentPlaying: Bool,
    successorArmed: Bool,
    lastTime: TimeInterval,
    currentTime: TimeInterval,
    lastAdvanceAt: Date,
    now: Date,
    window: TimeInterval,
    epsilon: TimeInterval
) -> StallTick {
    guard intentPlaying, !successorArmed else { return .ignore }

    if lastTime < 0 || abs(currentTime - lastTime) > epsilon {
        return .advanced
    }
    if now.timeIntervalSince(lastAdvanceAt) < window {
        return .watching
    }
    return .stalled
}

/// 冷却窗内不许再自动重建 —— 防重建本身再卡住时空转。
///
/// 吐的 `StallRecoveryDecision` 在 `Playback/Model/PlaybackErrorTypes.swift`。
func shouldAttemptStallRecovery(
    lastRecoveryAt: Date?,
    now: Date,
    cooldown: TimeInterval
) -> StallRecoveryDecision {
    guard let lastRecoveryAt else { return .rebuild }
    return now.timeIntervalSince(lastRecoveryAt) >= cooldown ? .rebuild : .coolingDown
}

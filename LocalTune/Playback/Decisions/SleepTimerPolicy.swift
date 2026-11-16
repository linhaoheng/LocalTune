import Foundation

/// 到期时看开关：立刻停，还是等当前这首放完。
func sleepExpireAction(finishAfterSong: Bool) -> SleepExpireAction {
    finishAfterSong ? .holdCurrent : .pauseNow
}

/// 「等这首完」锁的是 `held`。用户刚点的是 `new`。
/// 点的不是锁着的那首 ⇒ 这把锁作废（primuse：切歌取消曲终锁）。
func sleepAfterUserStarted(held: Track.ID, new: Track.ID) -> SleepTrackChangeAction {
    held == new ? .keep : .cancelHold
}

/// 自然播完的是 `finished`。锁着的是 `held`。对上才停。
func sleepFinishedAction(held: Track.ID, finished: Track.ID?) -> SleepFinishedAction {
    guard let finished, held == finished else { return .advance }
    return .stopHere
}

/// 页面上那串倒计时该显示几秒。`nil` = 关着，不画。
///
/// hold 时剩余已经是 0，显示 `00:00`。
func sleepDisplayedRemaining(now: Date, phase: SleepPhase) -> TimeInterval? {
    switch phase {
    case .idle:
        return nil
    case .countingDown(let end, _):
        return max(0, end.timeIntervalSince(now))
    case .holding:
        return 0
    }
}

/// 自定义 / 预设分钟必须大于 0。0 或负数不当作开。
///
/// 吐的 `SleepMinutesCheck` 在 `Playback/Model/SleepTimerTypes.swift`。
func sleepMinutesAreValid(_ minutes: Int) -> SleepMinutesCheck {
    minutes > 0 ? .valid : .notPositive
}

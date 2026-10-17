import Foundation

/// 睡眠定时的预设分钟。数值就是分钟数。
enum SleepPreset: Int, CaseIterable {
    case m15 = 15
    case m30 = 30
    case m60 = 60
    case m90 = 90

    var title: String { "\(rawValue)分钟" }
}

/// 用户点的那一档。
enum SleepSelection: Equatable {
    case off
    case preset(SleepPreset)
    case custom(minutes: Int)

    var title: String {
        switch self {
        case .off: "关闭"
        case .preset(let preset): preset.title
        case .custom: "自定义时间"
        }
    }
}

/// 定时此刻处在哪一段。
enum SleepPhase: Equatable {
    /// 没开。
    case idle
    /// 倒计时。`end` 是墙上时钟。
    case countingDown(end: Date, selection: SleepSelection)
    /// 分钟到了，等这首自然结束。
    case holding(trackID: Track.ID, selection: SleepSelection)
}

/// 睡眠定时的一份快照。界面只订这个。
struct SleepTimerSnapshot: Equatable {
    var selection: SleepSelection
    var phase: SleepPhase
    var finishAfterSong: Bool
}

/// 到期该立刻停，还是锁住当前这首。
enum SleepExpireAction: Equatable {
    case pauseNow
    case holdCurrent
}

/// 用户点了另一首：这把「等这首完」的锁还要不要。
enum SleepTrackChangeAction: Equatable {
    case keep
    case cancelHold
}

/// 一首自然播完：该停在这儿，还是照常往下走。
enum SleepFinishedAction: Equatable {
    case stopHere
    case advance
}

/// 「这个分钟数能不能当开用」的结论 —— `sleepMinutesAreValid` 吐它。
///
/// 判断（`Decisions/SleepTimerPolicy.swift`）产它、执行（`SleepTimerSession`）吃它 ⇒ 归 `Model/`。
///
/// ⚠️ 这里**只有一种「不行」**（0 / 负数）—— 仍返回 enum（具名判断的出口，不是实现步骤）。
enum SleepMinutesCheck: Equatable {
    /// 可以当「开」。
    case valid
    /// 0 或负数 —— 用户没真正设一个时长，不当作开。
    case notPositive
}

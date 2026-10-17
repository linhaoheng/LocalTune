import Foundation

/// 这一拍进度读数，对「真实听时累计 / 要不要记一次播放」意味着什么。
///
/// 🔴 **判断归位**：「这拍算听过吗、满没满 30 秒」是看情况决定的事，
/// 写成纯函数、返回 enum —— 不碰引擎、不碰库，能在测试里不带播放器跑一遍。
///
/// 执行（`PlayCountTracker`）只负责：把值送进来 → 拿回结果 → 改累计字段 / 调 `recordPlay`。
enum PlayCountTick {

    /// 不在播 / 歌对不上 / 本趟已记过 ⇒ 累计字段不动。
    case ignore

    /// 听时增加了，还没满阈值。带着新的累计秒数和本拍采样点回去。
    case accumulate(listened: TimeInterval, lastSample: TimeInterval)

    /// 累计已满阈值 —— 调用方该写库 +1；写成功后再钉「本趟已记」。
    case thresholdReached(listened: TimeInterval, lastSample: TimeInterval)
}

/// 真实听时阈值（秒）—— 本趟只记一次；显示开关关着也照记。
let playCountThresholdSeconds: TimeInterval = 30

/// 两次进度读数之间超过这个间隔 ⇒ 当成跳过 / 拖进度，不算「听过」。
///
/// 正常 10Hz 读数间隔约 0.1s；拖进度条或 seek 会一下子跳好几秒。
let playCountMaxListeningDelta: TimeInterval = 1

/// 进度读数来了 → 这一拍对播放次数累计意味着什么。
///
/// 🔴 **用相邻两次读数的正向小增量**，不用「进度条位置 ≥ 30」：
/// 拖到 0:31 不算听过；暂停期间也不加。
func playCountTick(
    position: TimeInterval,
    isPlaying: Bool,
    trackMatches: Bool,
    alreadyCounted: Bool,
    listenedSeconds: TimeInterval,
    lastSample: TimeInterval?
) -> PlayCountTick {
    guard isPlaying, trackMatches, !alreadyCounted else { return .ignore }

    var listened = listenedSeconds
    if let last = lastSample {
        let delta = position - last
        if delta > 0, delta < playCountMaxListeningDelta {
            listened += delta
        }
    }

    if listened >= playCountThresholdSeconds {
        return .thresholdReached(listened: listened, lastSample: position)
    }
    return .accumulate(listened: listened, lastSample: position)
}

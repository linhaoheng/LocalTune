import Foundation

/// 「在播但进度不动」的看门狗 —— 🔴 **只回决定，不动引擎**。
///
/// 它管的是三笔**跟时间有关的小账**：上次读到的秒数 · 上次位置真的前进的时刻 ·
/// 上次自动重建的时刻。
///
/// 「这一拍算不算卡死」是**判断**，在 `Decisions/PlaybackStallPolicy.swift`（纯函数、能单测）；
/// 这里只**记账 + 收结论**。
///
/// 🔴 **为什么不顺手把重建也做了**：重建要 `session.prepareForPlayback()` ＋ `service.play(…)`
/// ＋ 换号 ＋ 落 `.loading` —— 那是**动引擎**，归 `PlayManager`。
/// 这一层一旦开始动引擎，它就不再是「能单测的小账」了（和 `PlayCountTracker` 同一条界线）。
///
/// 线程：跟 `PlayManager` 一样**全在主线程**（喂进来的是 `PlayerService` 的进度读数，
/// 它统一回主线程再发）。
struct StallWatchdog {

    /// 这一拍的结论。
    enum Outcome: Equatable {
        /// 什么都不用做（没在播 / 已排后继 / 还在窗内 / 冷却中）。
        case none
        /// 卡死了，该**同曲重建**、并从这一秒接回去。
        case rebuild(resumeAt: TimeInterval)
    }

    /// 上次记下的秒数；**没有观察过用负数**（判断层靠这个认「第一次」）。
    private var lastTime: TimeInterval = -1

    /// 上次位置真的前进的时刻。
    private var lastAdvanceAt = Date()

    /// 上次自动重建的时刻；冷却窗内不再刺。
    private var lastRecoveryAt: Date?

    /// 喂一拍进度读数。
    ///
    /// - Parameters:
    ///   - seconds: 这一拍的秒数。
    ///   - isPlaying: 上层意图是不是在播（`PlayerState.status == .playing`）。
    ///   - successorArmed: 是否已给库排了后继 —— 换歌边界位置停住是**正常**的。
    ///   - now: 这一拍的时刻。
    /// - Returns: 该不该重建。**回 `.rebuild` 不等于真的重建了** ——
    ///   调用方可能因为「现在没有当前曲」而放弃，那时要**调 `noteRebuildHappened()`** 才算数。
    mutating func note(
        seconds: TimeInterval,
        isPlaying: Bool,
        successorArmed: Bool,
        now: Date = Date()
    ) -> Outcome {
        switch stallTick(
            intentPlaying: isPlaying,
            successorArmed: successorArmed,
            lastTime: lastTime,
            currentTime: seconds,
            lastAdvanceAt: lastAdvanceAt,
            now: now,
            window: AppMetrics.playbackStallWindow,
            epsilon: AppMetrics.playbackStallEpsilon
        ) {
        case .ignore:
            reset(now: now)
            return .none

        case .advanced:
            lastTime = seconds
            lastAdvanceAt = now
            return .none

        case .watching:
            return .none

        case .stalled:
            // 🔴 **先拨窗、再问该不该重建** —— 恢复本身慢的时候，不拨窗会让每一拍都连发一次。
            lastTime = seconds
            lastAdvanceAt = now
            // 冷却窗内不许再自动重建（防重建本身又卡住时空转）。
            guard shouldAttemptStallRecovery(
                lastRecoveryAt: lastRecoveryAt,
                now: now,
                cooldown: AppMetrics.playbackStallRecoveryCooldown
            ) == .rebuild else { return .none }
            return .rebuild(resumeAt: seconds)
        }
    }

    /// 真的重建了 —— 记下这一刻（冷却窗从这儿起算），并把窗口拨回去。
    mutating func noteRebuildHappened(now: Date = Date()) {
        lastRecoveryAt = now
        reset(now: now)
    }

    /// 把窗口拨回「没观察过」。
    ///
    /// 换歌 / 跳进度 / 暂停 / 恢复 / 冷恢复后都要调 ——
    /// 不调的话，上一首的时间账会串到这一首身上（第一拍就判「没动」）。
    mutating func reset(now: Date = Date()) {
        lastTime = -1
        lastAdvanceAt = now
    }
}

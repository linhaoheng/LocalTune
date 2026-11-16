import Foundation

/// 对外只认这三种播放失败 —— 库的 `Error` 进判断层翻成这个。
///
/// 出处：`播放错误与卡死恢复设计.md` §4.1 · `播放器设计.md` §3.7。
/// 本类型只分流「跳过 / 停机」；**给用户看的那句话**在 `PlaybackError+Display`
/// （短词）＋ 播放页（拼句），见 `播放错误提示设计.md`。
enum PlaybackError: Equatable {
    /// 文件不在了 → 跳过。
    case fileMissing
    /// 格式不支持 → 跳过。
    case unsupportedFormat
    /// 引擎真坏了 → 停下（不跳歌）。
    case engineFailed
}

/// 400ms 宽限之后，引擎还活不活。
enum EngineErrorAfterGrace: Equatable {
    /// `isPlaying || isPaused` —— 库自己恢复了。
    case recovered
    /// 双假 —— 当真死。
    case fatal
}

/// 一次进度观察对卡死窗的结论。
enum StallTick: Equatable {
    /// 不在播 / 有后继预载 / 不该看 —— 窗应重置。
    case ignore
    /// 位置动了。
    case advanced
    /// 还在 1.5s 窗内。
    case watching
    /// ≥ 窗长不动 → 该重建。
    case stalled
}

/// 「这次卡死要不要动手重建」的结论 —— `shouldAttemptStallRecovery` 吐它。
///
/// 判断（`Decisions/PlaybackStallPolicy.swift`）产它、执行（`PlayManager.rebuildAfterStall`）吃它 ⇒ 归 `Model/`。
///
/// ⚠️ 这里**只有一种「不动手」**（冷却窗内）—— 仍返回 enum（具名判断的出口，不是实现步骤）。
enum StallRecoveryDecision: Equatable {
    /// 可以重建。
    case rebuild
    /// 冷却窗内 —— 再刺一下只会更乱，等下次。
    case coolingDown
}

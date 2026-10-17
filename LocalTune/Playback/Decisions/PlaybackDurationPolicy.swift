import Foundation

/// 进度条总长：引擎报的优先，库里的 `durationMs` 兜底。
///
/// 时长要等解码器起来引擎才算得出来，装载期它一直是 0。
/// 库那份是导入时读标签得来的，撑过那一瞬间。两份都拿不到就是 0 —— 进度整条不画。
///
/// 播放页和迷你条用这一份，不许各写各的。
func resolvedPlaybackDuration(engine: TimeInterval, library durationMs: Int?) -> TimeInterval {
    if engine > 0 { return engine }
    guard let durationMs, durationMs > 0 else { return 0 }
    return Double(durationMs) / 1000
}

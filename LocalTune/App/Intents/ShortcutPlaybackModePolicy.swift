import Foundation

/// 快捷指令「随机 / 重复」两个参数 → 我们四档播放模式的**纯判断**。
///
/// | 快捷指令 | `PlaybackMode` |
/// |---|---|
/// | 随机 = 歌曲 | `.shuffle`（盖过重复参数） |
/// | 随机关 + 重复关 | `.sequential` |
/// | 随机关 + 单曲 | `.one` |
/// | 随机关 + 全部 | `.all` |
///
/// 🔴 **为什么独立**：随机 / 重复是两条轴，我们只有一档 —— 这层对照要能脱离引擎单测，
/// 不许缠进入口的起播副作用里。
///
/// 🔴 **为什么归 `App/Intents/`（而不是 `Playback/Decisions/`）**：输入是 `ShortcutShuffleMode` /
/// `ShortcutRepeatMode` —— **快捷指令的词汇**，干的是把入口参数翻成播放域的值（`PlaybackMode`）——
/// **入口翻译**，不是播放域的决策。消费者 `LocalTuneIntentBridge` 也在 App 层。
///
/// 输入值在同目录 `MediaPlayTypes.swift`。
func shortcutPlaybackMode(shuffled: Bool, repeatMode: ShortcutRepeatMode) -> PlaybackMode {
    if shuffled { return .shuffle }
    switch repeatMode {
    case .off: return .sequential
    case .one: return .one
    case .all: return .all
    }
}

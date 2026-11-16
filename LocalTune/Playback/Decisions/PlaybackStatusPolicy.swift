import Foundation

/// 「引擎报了 X，我们现在是 Y —— 该变成什么？」
///
/// 🔴 这个判断存在的理由有两个，方向相反：
///
/// **一、引擎说的「在播」不一定真的在播。** 库在 `play()` 里**引擎一启动就报「在播」**
/// （`Libraries/SFBAudioEngine/Sources/CSFBAudioEngine/Player/AudioPlayer.mm`），而那一刻
/// 解码器**还没打开** —— 文件可能是坏的、可能根本不在。⇒「还在装载中」的时候，那句「在播」
/// **不算数**；真正的「在播」要等解码器起来（`PlayerService.Event.ready`）。
///
/// **二、引擎说的「停」不一定就是「放完了」。** 系统把音频抢走时（通话、别的 App 播放），
/// 库也只报一条「停」；可用户回来还想**接着放**。这两件事必须落在不同的状态里 ——
/// `.stopped` 的语义是「放完了」，在它上面按播放键是「从头再放一遍」。
///
/// 纯函数：不碰引擎、不碰界面，几个值进、一个值出 —— **能在测试里不带引擎跑一遍**。
///
/// 收的 `ReportedPlaybackStatus` 在 `Playback/Model/PlaybackStatusTypes.swift` ——
/// 它**判断和执行都要用**（`PlayerService` 产它），所以归最底的 `Model/`。
///
/// - Parameter interruptionPaused: 当前这个「暂停」是**被打断**留下的（不是用户按的）——
///   用来认不认引擎随后自己续回来的那条「在播」。
func playbackStatus(
    after reported: ReportedPlaybackStatus,
    current: PlayerState.Status,
    interruptionPaused: Bool
) -> PlayerState.Status {
    switch (reported, current) {
    case (_, .failed):
        // 已经判过「这一首放不了」—— 引擎随后还会补一条「停了」（它把"解码器没了"也当成
        // 一次收尾），那一条不许洗掉这句话：「**听不了**」和「**听完了**」是两件事。
        return .failed
    case (.playing, .loading):
        // 引擎转起来了，但文件还没打开 ⇒ 继续等解码器。
        return .loading
    case (.paused, .loading):
        // 续播：`play` 后立刻 `pause` 等 ready 再 seek —— 装载中的「暂停」不是用户点的。
        return .loading
    case (.playing, .paused):
        // 用户按的暂停 ⇒ 引擎迟到的「在播」不抢回去（否则界面会自己弹回播放）。
        // 打断留下的暂停相反：这条「在播」是引擎自己续回来的，认。
        return interruptionPaused ? .playing : .paused
    case (.playing, _):
        return .playing
    case (.paused, _):
        return .paused
    case (.stopped, .playing), (.stopped, .loading), (.stopped, .paused):
        // 🔴 引擎把「在播 / 暂停」报成了「停」，而**这不是我们叫的停** —— 我们主动停机之前
        // 状态都已经先落成 `.stopped` / `.failed` / `.idle`（放完到头 / 放不了 / 队列清空）。
        // ⇒ **系统把音频抢走了**。报 `.paused`（还能接着放）而不是 `.stopped`（放完了）：
        // 报错的话，用户回来按播放会被当成「再放一遍」，从零开始。
        return .paused
    case (.stopped, _):
        // 上面三种都不是 ⇒ 就是我们自己收的尾。
        return .stopped
    }
}

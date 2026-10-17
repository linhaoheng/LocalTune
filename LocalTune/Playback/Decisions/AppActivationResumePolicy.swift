import Foundation

/// 回到前台：被打断那一首是不是**该**自己续回来。
///
/// ## 为什么需要它
///
/// 我们**有意不接** `interruptionNotification`（三条理由见 `AudioSessionController` 顶上那一节）——
/// 代价是：**打断结束、但系统不让恢复**时，SFB 一声不吭（`AudioPlayer.mm:2702` 那条 `return`），
/// 我们**分不出**「打断结束了」和「还在打断中」。于是「打断结束了」这件事**没有出口**，
/// 挂着的那首歌一直没人管，直到用户手动点播放。
///
/// 出口是：借一个**与打断无关**的既有生命周期事件（回到前台）去**核对一次**。
/// 这个函数就是那一次的判据 —— 纯函数、不带引擎、不带会话，能单测
/// （`AppActivationResumePolicyTests`，四项真值）。吐 `AppActivationResumeDecision`、不吐 `Bool`
///
/// ## 两条判据（对应 primuse 的四条，另两条免费）
///
/// | primuse 的判据 | 这里的等价物 |
/// |---|---|
/// | 有票（`pendingTicket != nil`） | `isAwaitingInterruptionEnd` |
/// | 意图一致（`playbackIsIntended`） | **由票的存活性免费提供** —— 票只由「在播 / 在装时报停」压，换歌 / 用户按播放都销票 |
/// | 同一首（`ticket.itemID == currentItemID`） | **同上** —— 换歌必走 `start` ⇒ `holds.clearAll()` ⇒ **票还在 ⟺ 没换歌** |
/// | 别的 App 没在放（`!otherAudioIsPlaying`） | `otherAudioIsPlaying` |
///
/// ⇒ 只剩两条要判。逐项对账与出处：`播放中断与恢复设计.md` §10.2·2。
///
/// ## 为什么不抄 primuse 那个有界重试（250 ms × 4）
///
/// 它重试治的是「**最后一条会话通知比场景激活晚**」—— 它订了 `interruptionNotification`
/// 才有那个时序竞争。我们**没订**⇒ 回前台那一刻**现读** `isOtherAudioPlaying`
/// 就是那一刻的真相。加个循环 ＝ 给一个不存在的问题做保险。
func appActivationResumeDecision(
    isAwaitingInterruptionEnd: Bool,
    otherAudioIsPlaying: Bool
) -> AppActivationResumeDecision {
    guard isAwaitingInterruptionEnd, !otherAudioIsPlaying else { return .keepHeld }
    return .resume
}

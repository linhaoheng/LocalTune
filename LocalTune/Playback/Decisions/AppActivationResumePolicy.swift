import Foundation

/// 回到前台：被打断那一首是不是**该**自己续回来。
///
/// ## 什么时候轮到它
///
/// **2026-11-12 起它是兜底**：`AudioSessionController` 已订 `interruptionNotification`，
/// 系统发 `.ended` 时由 `PlayManager.handleInterruptionEnded` 按 `shouldResume` 直接了结
/// （不许可 ⇒ 销票），轮不到这里。
///
/// 只有**长挂起后系统不再补发 `.ended`** 时，票才会留到回前台这一刻 —— 此函数判的就是
/// 那一次：**票还在** ＋ **别的 App 没在放**。吐 `AppActivationResumeDecision`、不吐 `Bool`，
/// 纯函数、不带引擎、不带会话，能单测（`AppActivationResumePolicyTests`）。
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
/// ## 为什么仍然不抄 primuse 那个有界重试（250 ms × 4）
///
/// 那条重试治的是「最后一条会话通知比场景激活晚」。我们只在**没收到 `.ended`** 时才走
/// 这条兜底，回前台那一刻**现读** `isOtherAudioPlaying` 就是那一刻的真相 ——
/// 加个循环 ＝ 给一个不存在的问题做保险。
func appActivationResumeDecision(
    isAwaitingInterruptionEnd: Bool,
    otherAudioIsPlaying: Bool
) -> AppActivationResumeDecision {
    guard isAwaitingInterruptionEnd, !otherAudioIsPlaying else { return .keepHeld }
    return .resume
}

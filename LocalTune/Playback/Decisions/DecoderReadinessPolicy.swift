import Foundation

/// 「解码器走到这一步，算不算这一首**真的开始了**」（`PlayerService.Event.ready`）。
///
/// - **立即播放的那首**（号 == 在响的号）：**开始解码**就算 —— 它打断了别的，解码器一起来就是它在响。
///   等出声再报会让「装载中」多挂一个输出延迟。
/// - **排着的下一首**（号 > 在响的号）：要等**第一帧出声**才算 —— 它在当前这首结束前约 0.37 秒
///   就开始解码了，那时拿它当"换歌了"，界面会比耳朵早换。
/// - 号比在响的小：过期的，什么都不算。
///
/// 纯函数：不碰引擎、不碰界面。吃的 `DecoderMilestone`、吐的 `DecoderReadiness`
/// 都在 `Playback/Model/DecoderMilestone.swift`。
///
/// ⚠️ 返回 `DecoderReadiness` 而不是 `Bool`：三种「不算」是**三件不同的事**，
/// 各自的含义写在那个 enum 上。号比在响的小 = 过期，先按它挡掉，再看是哪种里程碑。
func decoderMilestoneMeansReady(
    _ milestone: DecoderMilestone,
    ticket: Int,
    audibleTicket: Int
) -> DecoderReadiness {
    guard ticket >= audibleTicket else { return .stale }
    switch milestone {
    case .decodingStarted:
        return ticket == audibleTicket ? .started : .notAudibleYet
    case .renderingStarted:
        return ticket > audibleTicket ? .started : .alreadyCounted
    }
}

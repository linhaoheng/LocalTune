import Foundation

/// 一个解码器走到了哪一步 —— 只列我们用来判断「这一首真的开始了」的两步。
///
/// 执行（`Player/` 收库的回调）产它、判断（`decoderMilestoneMeansReady`）吃它 ⇒ 归 `Model/`。
/// ⚠️ 这是**我们自己的名字**，库的类型不出现在这里。
enum DecoderMilestone: Equatable {
    /// 开始解码（库的 `decodingStarted`）。
    case decodingStarted
    /// 第一帧真正出声（库的 `renderingStarted`）。
    case renderingStarted
}

/// 「这个里程碑算不算这一首真的开始了」的结论 —— `decoderMilestoneMeansReady` 吐它。
///
/// 判断（`Decisions/DecoderReadinessPolicy.swift`）产它、执行（`DecoderTickets`）吃它 ⇒ 归 `Model/`。
///
/// 🔴 **为什么不是一个 `Bool`**：这四种「不算」的含义各不相同 ——
/// 「**再等一等**」（排着的那首还没出声）和「**已经算过了**」（立即播放那首的第二次里程碑）
/// 和「**过期事件**」（号比在响的小）对执行是**三件不同的事**，压成一个 `false` 就分不出来了。
enum DecoderReadiness: Equatable {
    /// 算 —— 这一首真的开始了，让它成为在响的那首。
    case started
    /// 排着的下一首只走到「开始解码」：还没出声，要等 `renderingStarted`。
    case notAudibleYet
    /// 立即播放那首的「开始出声」：开始解码时已经算过一次，不重复认。
    case alreadyCounted
    /// 号比在响的小 —— 过期事件，永远不算。
    case stale
}

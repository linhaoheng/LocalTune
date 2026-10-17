import Foundation

/// 「现在能不能给库排下一首」的结论 —— `canPreloadNext` 吐它。
///
/// 判断（`Decisions/NextTrackPreloadPolicy.swift`）产它、执行（`PlayManager.syncPreload`）吃它 ⇒ 归 `Model/`。
///
/// 🔴 **为什么不是一个 `Bool`**：五种结论里四种都是「不能」，
/// 但**卡在哪一条**决定了「以后会不会自己好」—— 装载中会自己好、睡眠锁着要等用户、
/// 引擎落后队列是换歌那一瞬的过渡。压成一个 `false` 就全糊在一起了。
enum PreloadEligibility: Equatable {
    /// 能排。
    case allowed
    /// 睡眠锁着「等这首完」—— 再排，库会在当前这首结束前把后继接上。
    case blockedBySleepHold
    /// 不是「在播 / 暂停」（装载中 / 停了 / 放不了 / 没装）：没有"放完接谁"这回事。
    case notActive
    /// 引擎还没装任何一首。
    case nothingLoaded
    /// 引擎装着的那首跟队列游标上那首对不上（按了下一首、引擎还没换完的那一瞬）。
    case engineBehindQueue
}

/// 给库排着的下一首，这次要怎么改。
///
/// 判断（`preloadChange`）产它、执行（`PlayManager`）照着动引擎 ⇒ 归 `Model/`。
enum PreloadChange: Equatable {
    /// 排着的就是该排的（或者本来就都没有）—— 不用跟库再说一遍。
    case keep
    /// 撤掉排着的，不排新的。
    case clear
    /// 原来没排，排上这一首。
    case arm(Track)
    /// 撤掉排着的，换成这一首。
    case replace(Track)
}

import Foundation

/// **号** —— 「交给引擎的那件活」的身份。
///
/// ## 为什么要有号
///
/// 引擎（`PlayerService`）是异步的：叫它播 / 排下一首，事情过一会儿才发生，回来的还是一句
/// 不带主语的「好了 / 失败了」。要认出「这条回来说的是我说的哪一件事」，就得在**说的时候**
/// 给它一个身份 —— 这个类型只管这一件事。
///
/// 号有两个用途，**共用同一个计数器**（分开记就会出现"两个号谁大"没法比）：
///
/// | 用途 | 字段 | 什么时候换 |
/// |---|---|---|
/// | 正在放的那首 | `current` | 立即播放（`start`）· 重建（`rebuildAfterStall`）· 库无缝接上（`acceptSuccessor`） |
/// | 排给库的下一首 | `armed` | `syncPreload` 说「排这一首」时领一张记下来；说「别排了」时清 |
///
/// ## 🔴 单调 ⇒ 分路
///
/// 只增不减：**比当前小** ⇒ 过去的事（丢掉），**比当前大** ⇒ 排过的下一首
/// （判据在 `Decisions/EngineEventRoutePolicy.swift`）。
///
/// ## 🔴 `armed` 不是第二份真相
///
/// 「下一首是谁」**永远只问队列**。`armed` 记的是「**我们对库说过什么**」，
/// 只用来认两件事：要不要再跟库说一遍（`preloadChange`）、库换过去的是不是这张
/// （`successorHandover`）—— 出处 `无缝接歌设计.md` §三、§六。
///
/// ## 线程
///
/// **只在主线程用**（`PlayManager` 持有它，而 `PlayManager` 全在主线程）。
/// 它不是线程安全的类型，也不打算是 —— 没有第二个线程碰它。
@MainActor
final class TicketIssuer {

    /// 「我们对库说过：接着放这一首」—— 说的时候领的那张号 ＋ 那首歌的编号。
    struct Preload: Equatable {
        let ticket: Int
        let trackID: Track.ID
    }

    /// 发出去的最后一张号。**只增不减** ⇒ 外面只拿它跟 `current` 比大小。
    private var lastIssued = 0

    /// 正在放的那首的号。
    var current = 0

    /// 给库排着的下一首（`nil` ＝ 没排 / 已经让它别排了）。
    var armed: Preload?

    /// 领一张新号 —— **全工程只有这里发号**。
    func next() -> Int {
        lastIssued += 1
        return lastIssued
    }

    /// 记下「我们对库说过：排这一首」。号由调用方用 `next()` 领（引擎那通调用要用同一张号）。
    func arm(trackID: Track.ID, ticket: Int) {
        armed = Preload(ticket: ticket, trackID: trackID)
    }
}

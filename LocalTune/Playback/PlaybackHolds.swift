import Foundation

/// 「**用户想听，但环境不让出声**」时压下的**两张一次性票** ＋ 蓝牙那条的看门狗。
///
/// ## 为什么两张票住在一个类型里
///
/// 它们**语义是一对** —— 都是「意图还在，只是这一下出不了声」：
///
/// | 票 | 什么时候压 | 什么时候销 |
/// |---|---|---|
/// | **打断票**（`isAwaitingInterruptionEnd`） | 引擎在我们**在播 / 在装载**时报「停」 ⇒ 这一下**不是我们叫的**，是被抢了 | 引擎自己续回来（认下那条「在播」）· 换歌 · 用户按播放 |
/// | **HFP 票**（`heldTrackID`） | 用户点了播放，而蓝牙此刻被别的 App 抢成通话档 ⇒ **不去抢麦**，先把这一首记下来 | 回到能放的档（续播）· 判据说作废 · 换歌 / 外接丢失 |
///
/// 🔴 **判断层要的 `playbackIsIntended` 就是它俩的并集**（外加「现在真的在响」，那一半归
/// `PlayerState`）。分成两个字段散在调用方，等于让每个调用点自己拼一遍 —— 早晚有一处漏掉其中一张。
///
/// ## 谁做判断
///
/// **这里一个判据都没有**：该不该暂停 / 该不该续，全在 `Decisions/AudioRoutePolicies.swift`
/// （纯函数、能单测）。这里只**记票 / 销票 / 按结论转告**。
/// 看门狗每一拍要问的那句「现在能不能兑现」，用闭包**问出去** ——
/// 判据要用**现读**的路由和当前状态，那些不归这儿管（和 `SleepTimerSession.bind` 同一个路子）。
///
/// ## 看门狗
///
/// 系统**不保证**通话档退出时补发 `routeChange` ⇒ 有界轮询（20 × 500 ms）。
/// ⚠️ 轮完**不**清票 —— 之后再来的那次 `routeChange` 照样能把它兑现。
///
/// ## 线程
///
/// **全在主线程**（跟 `PlayManager` 同）：票由主线程的动作读写，看门狗也挂在主队列上。
@MainActor
final class PlaybackHolds {

    /// 「这一趟暂停是**被打断**留下的」。
    ///
    /// 它只影响一件事：把「打断留下的暂停」和「用户按的暂停」分开（判断在 `PlaybackStatusPolicy`）——
    /// 前者引擎随后自己续回来的那条「在播」**要认**，后者那条是迟到的、不许抢回去。
    ///
    /// 🔴 **为什么不直接订 `interruptionNotification` 来记这张票** —— 见
    /// `AudioSessionController` 顶上那一节：**有意不接**（SFB 内部已接，
    /// 我们要的 `shouldResume` 已经在引擎档位里了）。
    private(set) var isAwaitingInterruptionEnd = false

    /// HFP 那张票钉着的歌 —— 「用户刚才想放的那一首」。
    ///
    /// ⚠️ **不是第二份真相**：它不记播放状态，只记「我们压了一趟续播」。
    private(set) var heldTrackID: Track.ID?

    /// 看门狗本体。`DispatchWorkItem` ⇒ 必须显式 `cancel`（`deinit` 兜一道）。
    private var watchdog: DispatchWorkItem?

    /// 看门狗最多轮询这么多次、每次隔这么久（与 primuse 同：20 × 500 ms）。
    private static let watchdogAttempts = 20
    private static let watchdogInterval: TimeInterval = 0.5

    /// 看门狗每一拍问外面一句：「现在能不能兑现这张票」。
    ///
    /// 判据要用**现读**的路由 ＋ 当前状态 ⇒ 不归这儿管，收成一口注入进来。
    var evaluateHold: (() -> BluetoothDeferredResumeDecision)?

    /// 兑现这张票 ＝ 续播 ＝ **要动引擎** ⇒ 也只回一口。
    var resumeHeld: (() -> Void)?

    /// 手里还有没有没销的票。
    ///
    /// ⚠️ 它**只是**「意图」的一半 —— 另一半是「现在真的在响 / 在装」，那个归 `PlayerState`。
    /// 调用方把两半并起来用（本类型**不认识** `PlayerState`）。
    var hasPendingHold: Bool { isAwaitingInterruptionEnd || heldTrackID != nil }

    deinit {
        // 看门狗的块被 GCD 持有 ⇒ 必须显式退掉（代码标准第 13 条）。
        watchdog?.cancel()
    }

    // MARK: - 打断票

    /// 压票：引擎在**在播 / 在装载**时报「停」⇒ 这不是我们叫的停。
    func noteInterruptionPause() {
        isAwaitingInterruptionEnd = true
    }

    /// 销票：引擎真的又响了 / 用户按了播放 / 换了歌。
    func consumeInterruption() {
        isAwaitingInterruptionEnd = false
    }

    // MARK: - HFP 票

    /// 压下续播票并起看门狗 —— 「用户点了播放，但蓝牙此刻在通话档」。
    ///
    /// ⚠️ 传进来的必须是**用户想放的那一首**（不是"现在装着的那一首"）——
    /// 兑现时靠它认「票主还是不是当前曲」，对不上就作废。
    func hold(trackID: Track.ID) {
        heldTrackID = trackID
        scheduleWatchdog()
    }

    /// 清掉 HFP 票和它的看门狗。
    ///
    /// 三条路都走它：票被**兑现**了 / 判据说**作废** / 环境变了（换歌 · 外接丢失）。
    func clearHold() {
        heldTrackID = nil
        watchdog?.cancel()
        watchdog = nil
    }

    /// 两张票一起清 —— **换歌走这条**（要接着放的是**新**那一首，旧票一律作废）。
    func clearAll() {
        consumeInterruption()
        clearHold()
    }

    // MARK: - 看门狗

    /// 起 / 续一轮轮询。
    ///
    /// ⚠️ 票在挂起期间**换了主**（换歌 / 外接丢失）⇒ 这一趟直接作废，不接着轮。
    private func scheduleWatchdog(attempt: Int = 0) {
        watchdog?.cancel()
        guard let trackID = heldTrackID, attempt < Self.watchdogAttempts else {
            watchdog = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.heldTrackID == trackID else { return }
            if self.poll() { return }
            guard self.heldTrackID == trackID else { return }
            self.scheduleWatchdog(attempt: attempt + 1)
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogInterval, execute: work)
    }

    /// 轮询一趟：问一句、按结论办。
    ///
    /// - Returns: 这一趟是否已把票**了结**（续播 / 作废）—— 是就不用再轮了。
    private func poll() -> Bool {
        // 没人注入判据 ⇒ 当作「再等等」，票留着（不猜）。
        switch evaluateHold?() ?? .wait {
        case .wait:
            return false

        case .discard:
            clearHold()
            return true

        case .resume:
            clearHold()
            resumeHeld?()
            return true
        }
    }
}

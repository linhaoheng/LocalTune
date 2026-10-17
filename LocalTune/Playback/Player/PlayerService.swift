import AVFAudio
import Foundation
import SFBAudioEngine

/// 播放引擎薄壳 —— 全工程只有 `Playback/Player/` 碰 SFB **播放侧**
/// （本文件 + `PlayerServiceDelegate` + `DecoderTickets`；读标签在 `MetadataReader`）。
/// 不存播放状态、不碰界面、不认识队列；库回调收成四个 `onEvent`，由 `PlayManager` 算状态。
///
/// 🔴 **≤ 400 行**（铁律十二条 ③）—— ⚠️ 加 `discardEngineAfterMediaServicesReset()`
/// 之后**约 422 行**；超行不用管。
/// EQ / 变速 / ReplayGain **不许**挂本文件 extension
///
/// - `play` / `prepareNext`·`clearNext`：立即播 vs 无缝下一首。
/// - 引擎调用走串行 `queue`；事件回主线程。
/// - 错：曲失败立刻 `.failed`；引擎异步错走 400ms 宽限。
final class PlayerService {

    /// 引擎那边发生的事 —— 已经翻译成我们自己的说法，**库的类型不出现在这里**。
    struct Event {
        /// 这件事属于**哪一张号**（`PlayManager` 发的；立即播放、排下一首各领一张）。
        ///
        /// 🔴 为什么事件要带它：库是异步的，而且无缝接歌时**同时有两首在路上**。
        /// 没有它，上一首迟到的事、下一首提前的事都会被写进当前这首的账上 ——
        /// 界面写着 B、耳朵里响的是 A。
        let ticket: Int
        let kind: Kind

        enum Kind {
            /// 引擎报的播放态变了。⚠️ **只有三种** —— `idle` / `loading` / `failed`
            /// 是**我们自己**加的（库不认识它们）。
            case status(ReportedPlaybackStatus)
            /// 这一首**真的开始了**，时长现在也知道了（`nil` ＝ 这一份算不出时长）。
            ///
            /// 立即播放的那首：解码器起来了；排着的下一首：它**开始出声**了 ⇒ 这就是换歌的那一刻。
            case ready(TimeInterval?)
            /// **全都放完了**（≠ 被停掉）。
            case finished
            /// 这一首**放不了**（文件没了 / 格式不支持 / 建不起来）。原始错误往外给，
            /// 由 `PlayManager` 决定对用户怎么说。
            case failed(Error)
        }
    }

    /// 「现在播到哪儿了」的一份读数，带着它属于哪一张号。
    struct Position {
        let ticket: Int
        let seconds: TimeInterval
    }

    /// 事件出口 —— `PlayManager` 在这儿接。**保证在主线程上叫**（见上面「线程」）。
    ///
    /// 🔴 类型上标 `@MainActor`：接它的是 `PlayManager`（整个类是主线程的），
    /// 而这个口子由 `deliver(_:)` 回主线程之后再叫 —— 两件事**本来就该是同一件**，
    /// 现在由编译器看着。
    var onEvent: (@MainActor (Event) -> Void)?

    /// 位置出口 —— **只在真的在播的时候**发，**保证在主线程上叫**。
    ///
    /// 10Hz。⚠️ **不是"事件"**：它不像上面那四个（一件事发生一次），
    /// 它是**一直有的一个读数** —— 所以单独一个口子，不塞进 `Event` 里
    /// （塞进去就等于每秒给"事件"这条路上灌十次假事件）。
    var onPosition: (@MainActor (Position) -> Void)?

    /// 引擎只在这条队列上碰。
    private let queue = DispatchQueue(label: "com.localmusic.player.engine", qos: .userInitiated)

    /// 位置读数世代。`seek` **同步** +1，作废「seek 前已采样、还在去主线程路上」的旧读数。
    /// ⚠️ 主线程与 `queue` 都会碰 ⇒ 用锁，不靠「只在 queue 上」。
    private let positionSerialLock = NSLock()
    private var positionSerial: UInt64 = 0

    /// 引擎对象。第一次要播的时候才建，之后一直复用（换歌是同一个引擎换源）。
    /// ⚠️ **只在 `queue` 上读写**。
    private var player: AudioPlayer?

    /// 解码器 → 号。登记在 `queue` 上，库的回调线程上查（它自己带锁）。
    private let tickets = DecoderTickets()

    /// 回调转发器 —— 库要的 delegate 是个 ObjC 对象，`PlayerService` 不是。
    private let forwarder: PlayerServiceDelegate

    /// EQ / 变速节点图。第一次建引擎时装上；数字以 Session 为准，这里只记「还没建引擎时的最后一次」。
    private let graph: EffectsGraph

    /// 引擎还没建时 Session 已经改过的数字。第一次 `engine()` 按这份 apply。
    /// ⚠️ **只在 `queue` 上读写**。
    private var pendingEQ = EQGains.flat
    private var pendingRate = PlaybackRate.x1

    /// 宽限世代：换歌 / `stop` 时 +1，到期复查对不上就丢（过期事件）。
    /// ⚠️ **只在 `queue` 上读写**。
    private var engineErrorGeneration = 0

    /// 未到期的宽限任务。⚠️ **只在 `queue` 上读写**。
    private var pendingEngineErrorGrace: DispatchWorkItem?

    /// 连线结果往外送（主线程）。装配层交给 `EffectsSession.noteConnect`。
    var onConnectOutcome: (@MainActor (EQConnectOutcome) -> Void)?

    init(graph: EffectsGraph = EffectsGraph()) {
        self.graph = graph
        forwarder = PlayerServiceDelegate(tickets: tickets)
        forwarder.onEvent = { [weak self] event in self?.deliver(event) }
        forwarder.onEngineError = { [weak self] error in self?.noteEngineError(error) }
        forwarder.onReconnect = { [weak self] engine, mixer, format in
            guard let self else { return mixer }
            let result = self.graph.reconnect(engine: engine, mixer: mixer, format: format)
            self.deliverConnect(result.outcome)
            return result.head
        }
    }

    /// 把 Session 给的数字转给两个 unit。引擎队列上跑；节点已 attach 就能改，不必在播。
    func apply(eq: EQGains, rate: PlaybackRate) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingEQ = eq
            self.pendingRate = rate
            guard self.graph.isInstalled else { return }
            self.graph.apply(eq: eq, rate: rate)
        }
    }

    /// 打断现在的，装上这一首并开始播。
    ///
    /// - Parameters:
    ///   - url: 沙盒里那个音频文件的**绝对路径**（`Track.path` 是相对路径，调用方先解好）。
    ///   - ticket: `PlayManager` 给这一首发的号，会原样贴在回来的事件上。
    ///   - pauseAfterStart: `true` ⇒ `play` 后立刻 `pause`（同一条引擎队列、紧挨着）。
    ///     续播 seek 必须走这条：库只在 **未在播** 时于 `decodingStarted` 发布可 seek 快照
    ///     （`AudioPlayer.mm` `processDecodingStartedEvent`）；边播边在 ready 上 seek 会因快照未建而静默失败，从头出声。
    func play(url: URL, ticket: Int, pauseAfterStart: Bool = false) {
        queue.async { [weak self] in
            self?.startPlayback(url: url, ticket: ticket, pauseAfterStart: pauseAfterStart)
        }
    }

    /// 在引擎队列上：打断旧的、装这一首、开始播。（`play` 只负责派发到这里。）
    private func startPlayback(url: URL, ticket: Int, pauseAfterStart: Bool) {
        bumpEngineErrorGeneration()
        do {
            let decoder = try AudioDecoder(url: url)
            // 🔴 号要在**交给库之前**登记 —— 交出去库就可能开始回调，那些回调要认得它。
            tickets.registerImmediate(decoder, ticket: ticket)
            try engine().play(decoder)
            if pauseAfterStart {
                player?.pause()
            }
        } catch {
            // 点了新的一首 ⇒ 不管新的能不能放，旧的都不该再响
            // （库在解码器建不起来时根本不动引擎，上一首会接着唱）。
            //
            // 🔴 **先报失败、再停引擎**：两条都会进状态层，而"停机"那条有歧义
            // （也可能是系统把音频抢走了）。结论先到，它就只会被读成「我们自己收的尾」。
            deliver(Event(ticket: ticket, kind: .failed(error)))
            player?.stop()
        }
    }

    /// 给库排好**下一首**：当前这首放完，库自己无缝接上它。
    ///
    /// ⚠️ 只排一首：调用方每次改主意都先 `clearNext()` 再排（`PlayManager.syncPreload` 管这件事）。
    /// 文件建不起来 ⇒ 报一条这张号的 `.failed`，由上面决定怎么办（它不会打断当前这首）。
    func prepareNext(url: URL, ticket: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let decoder = try AudioDecoder(url: url)
                self.tickets.registerQueued(decoder, ticket: ticket)
                try self.engine().enqueue(decoder)
            } catch {
                self.deliver(Event(ticket: ticket, kind: .failed(error)))
            }
        }
    }

    /// 撤掉排着的下一首。
    ///
    /// ⚠️ 撤不掉**已经被库取走**的那首：库在当前这首结束前约 0.37 秒就把下一首取出来开始解码了，
    /// 之后只能等它出声时由上面改道。
    func clearNext() {
        queue.async { [weak self] in self?.player?.clearQueue() }
    }

    /// 继续（暂停后从原地接着放）。
    ///
    /// 🔴 先叫库的「继续」，它自己会报**真假**：引擎没在跑时它是**无声失败**
    /// （`if (!engine_.isRunning) return false;`）⇒ 返回 false 就重新起引擎 ——
    /// 解码器和播放位置都还在，`play()` 从当前位置接着出声。
    func resume() {
        queue.async { [weak self] in
            guard let self, let player = self.player else { return }
            // 🔴 拿 `isStopped` 当先行判据**不行**：那面旗子只由引擎自己的起停维护，
            // 会话被系统从背后收走时（别的 App 抢音频）它**不更新** —— 拿它分流就会
            // 「看着还在跑、实际早停了」，然后走进无声失败那条（装机实测的回归）。
            // 判据就是库返回的那个真假，读一次、只此一处。
            if player.resume() { return }
            do {
                try player.play()
            } catch {
                // 引擎重新起不来 ⇒ 交给和别的引擎错同一条路（400ms 宽限后报给用户），
                // 不在这儿自己编一句话 —— 文案归界面。
                self.noteEngineError(error)
            }
        }
    }

    func pause() {
        queue.async { [weak self] in self?.player?.pause() }
    }

    /// 停引擎、不保留位置（当前曲没了）。再听得重新 `play(url:ticket:)`。
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.bumpEngineErrorGeneration()
            self.player?.stop()
        }
    }

    /// **媒体服务重启**（`mediaserverd` 崩了又起）—— 手里那台引擎**和挂在它上面的节点**全部作废，
    /// 一起丢掉，下次 `engine()` 从零重造。
    ///
    /// 🔴 **不是** `stop()` ＋ `play()`：那还指着**死对象**（对象已经死了，`stop` / `play` 都是空谈）。
    ///
    /// 🔴 **必须连节点一起丢**（`graph.discardNodes()`）—— 只丢引擎的话，新引擎的 `install`
    /// 会因为 `isInstalled` 还是 `true` **跳过 attach**，EQ / 变速**静默失效**
    /// （Apple QA1749：连同 `AVAudioEngine` **和它的节点**一起重造）。出处见 `播放中断与恢复设计.md` §10.1·2。
    ///
    /// 🔴 **不碰 `DecoderTickets`**：它自己那条「在响的号前进 ⇒ 比它小的全丢」已经够 ——
    /// 重建后新号必比旧号大、旧条目自然出局。再补一套清理就是**第二套规则**。
    ///
    /// ⚠️ 位置世代**不在这儿 bump**：接下来的 `start` / `seek` 各自会 bump（已有）。
    /// ⚠️ 引擎错误世代**也不在这儿 bump**：`player = nil` 之后，旧宽限到期头一句
    /// `guard … let player` 自己就返回、不会误报；要续播时 `start` 本来就 bump。
    /// **给不会发生的事设防＝保险**。
    /// ⚠️ 丢的时候**不接错误**：QA1749 明写「Any errors returned during disposing can safely be ignored」。
    func discardEngineAfterMediaServicesReset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopPositionReporting()
            self.graph.discardNodes()
            self.player = nil
        }
    }

    /// 跳到指定秒。不返回结果（失败时下次 10Hz 读数拉回真位置，见播放页设计）。
    ///
    /// 🔴 **先同步作废旧读数再进队列**：10Hz 是 queue→主线程异步；只在 queue 上 seek 的话，
    /// 路上「seek 前位置」仍会盖掉乐观进度（条子闪回旧处）。世代不对的在 `reportPosition` 丢。
    func seek(to seconds: TimeInterval) {
        bumpPositionSerial()
        queue.async { [weak self] in self?.player?.seek(time: seconds) }
    }

    // MARK: - 引擎异步错（400ms 宽限）

    /// Delegate 报来的 `encounteredError`。**回落到 `queue` 上**再调度宽限。
    private func noteEngineError(_ error: Error) {
        queue.async { [weak self] in
            guard let self else { return }
            let ticket = self.tickets.audibleTicket
            let generation = self.engineErrorGeneration
            self.pendingEngineErrorGrace?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.finishEngineErrorGrace(error: error, ticket: ticket, generation: generation)
            }
            self.pendingEngineErrorGrace = work
            self.queue.asyncAfter(
                deadline: .now() + AppMetrics.engineErrorGrace,
                execute: work
            )
        }
    }

    /// 宽限到期：还活着就放过；双假才报 `.failed`。**只在 `queue` 上调。**
    private func finishEngineErrorGrace(error: Error, ticket: Int, generation: Int) {
        pendingEngineErrorGrace = nil
        guard generation == engineErrorGeneration, let player else { return }
        switch engineErrorAfterGrace(isPlaying: player.isPlaying, isPaused: player.isPaused) {
        case .recovered:
            return
        case .fatal:
            deliver(Event(ticket: ticket, kind: .failed(error)))
        }
    }

    /// 换歌 / 停机 ⇒ 作废未到期的宽限。**只在 `queue` 上调。**
    private func bumpEngineErrorGeneration() {
        engineErrorGeneration += 1
        pendingEngineErrorGrace?.cancel()
        pendingEngineErrorGrace = nil
    }

    // MARK: - 私有

    /// 建（或复用）引擎对象。**只在 `queue` 上调。**
    private func engine() -> AudioPlayer {
        if let player { return player }
        let created = AudioPlayer()
        created.delegate = forwarder
        player = created
        created.modifyProcessingGraph { [weak self] engine in
            guard let self else { return }
            let outcome = self.graph.install(
                engine: engine,
                source: created.sourceNode,
                mixer: created.mainMixerNode
            )
            self.graph.apply(eq: self.pendingEQ, rate: self.pendingRate)
            self.deliverConnect(outcome)
        }
        return created
    }

    /// 连线结果回主线程。`reconfigure` 不在主线程，不能在那儿碰 Session。
    private func deliverConnect(_ outcome: EQConnectOutcome) {
        DispatchQueue.main.async { [weak self] in
            self?.onConnectOutcome?(outcome)
        }
    }

    /// 回主线程把事件发出去。
    private func deliver(_ event: Event) {
        // 位置报告跟着**引擎的档位**走：报在播就开始搬、报别的就停。
        //
        // 🔴 用它、**不用 `PlayManager` 的状态**：那边是**乐观更新**的（按了暂停立刻改状态、
        // 不等引擎回报），拿它驱动定时器会在「状态说停了、引擎还在响」那个窗口里搬错东西。
        // 引擎自己报的档位没有这个时间差。
        queue.async { [weak self] in self?.updatePositionReporting(for: event.kind) }

        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    /// 「引擎报了这一条 ⇒ 位置报告该开还是该关」。**只在 `queue` 上调。**
    private func updatePositionReporting(for kind: Event.Kind) {
        switch kind {
        case .status(let reported):
            reported == .playing ? startPositionReporting() : stopPositionReporting()
        case .finished:
            // 🔴 放完之后**没有**「停了」可等：库认了 `endOfAudio` 就不再补发（见 `PlayerServiceDelegate`）。
            stopPositionReporting()
        case .ready, .failed:
            // 不改档位。`.failed` 尤其不能停：排着的下一首提前打开失败时，当前这首还在响。
            // 真正"没东西可放了"的那种失败，库会自己补一条「停了」（`AudioPlayer.mm` 里
            // `processDecoderCanceledEvent` 末尾），走上面 `.status` 那条。
            return
        }
    }

    // MARK: - 位置

    /// 多久读一次「播到哪儿了」。
    ///
    /// **10Hz** —— 进度条要跟得上手。
    /// ⚠️ **只在真的在播的时候跑**：暂停 / 停下 / 放完都会把它停掉，不然就是每秒十次白叫。
    private static let positionInterval: TimeInterval = 0.1

    /// 正在跑的位置定时器 —— **只在 `queue` 上读写**。
    private var positionTimer: DispatchSourceTimer?

    /// 开始定期把位置报出去。**只在 `queue` 上调。**
    ///
    /// ⚠️ 重复调是安全的（旧的先停掉）：引擎会把「在播」报不止一次，别让定时器越堆越多。
    private func startPositionReporting() {
        stopPositionReporting()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: Self.positionInterval,
            leeway: .milliseconds(20)
        )
        timer.setEventHandler { [weak self] in self?.reportPosition() }
        positionTimer = timer
        timer.resume()
    }

    /// 读一次位置送出。**只在 `queue` 上调。**
    ///
    /// 🔴 前后各读一次解码器，同一才算数（换歌边界两读可能各属一首）。
    /// `currentTime` 无值不报（不拿 0 冒充）。送达主线程前对世代：不对 ⇒ seek 前采的，丢。
    private func reportPosition() {
        let serial = lockedPositionSerial()
        guard let player,
              let decoderBefore = player.currentDecoder,
              let seconds = player.currentTime,
              let decoderAfter = player.currentDecoder,
              decoderBefore === decoderAfter,
              let ticket = tickets.ticket(for: decoderBefore)
        else { return }

        let position = Position(ticket: ticket, seconds: seconds)
        DispatchQueue.main.async { [weak self] in
            guard let self, serial == self.lockedPositionSerial() else { return }
            self.onPosition?(position)
        }
    }

    private func bumpPositionSerial() {
        positionSerialLock.lock()
        positionSerial &+= 1
        positionSerialLock.unlock()
    }

    private func lockedPositionSerial() -> UInt64 {
        positionSerialLock.lock()
        defer { positionSerialLock.unlock() }
        return positionSerial
    }

    /// 停掉位置定时器。**只在 `queue` 上调。**
    private func stopPositionReporting() {
        positionTimer?.cancel()
        positionTimer = nil
    }

    deinit {
        // 定时器要显式取消 —— GCD 的源不会因为没人引用就自己停（代码标准第 13 条）。
        // ⚠️ `cancel()` 是线程安全的，`deinit` 落在哪条线程上都行。
        positionTimer?.cancel()
        pendingEngineErrorGrace?.cancel()
    }
}

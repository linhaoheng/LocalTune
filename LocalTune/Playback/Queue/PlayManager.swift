import Foundation
import RxRelay
import RxSwift

/// 播放的**总管** —— 全工程**唯一写 `PlayerState` 的地方**。
///
/// 它站在引擎薄壳（`PlayerService`）和界面之间，接三头：
/// - **往下**：把「播 / 暂停 / 继续 / 下一首」这些动作翻成 `PlayerService` 的调用；
/// - **往上**：把引擎来的事件（`PlayerService.onEvent`）算成新的 `PlayerState` 推出去；
/// - **往旁边**：提供 `removeTracks(fromQueue:)` 口子，装配层盯曲库流之后调它。
///
/// 对外只给两样：**发动作的方法** + **只读的流**（`state` / `position` / `seeks` / `queueSnapshot`）。界面不碰引擎、也不存状态
///
/// ## 队列在这儿，但不在这个文件里
///
/// 「现在排着哪些歌、往后走是哪一首」全在 `PlayQueue`（纯容器，能单测）；
/// 「往后走该走到哪一格」在 `PlayNext`（纯函数）。这个类**只把值送进去、拿回来，
/// 再决定要不要动引擎** —— 它自己不记队列数据，所以没有"两处记着同一件事"的余地。
///
/// ## 线程
///
/// **全在主线程**：动作由界面调（主线程），引擎事件和进度读数由 `PlayerService` 统一回主线程再发。
/// 所以 `stateRelay` / `positionRelay` / `queue` / 那几个计数器都不需要锁 —— 没有第二个线程碰它们。
///
/// 🔴 这一句现在**由编译器看着**（整个类 `@MainActor`）—— 以前它只是句注释。
/// 谁碰这个类，谁就得在主线程上；碰不了的调用点编译器会一条条点出来。
@MainActor
final class PlayManager {

    /// 「谁在播、什么态」的唯一真相 —— 迷你条 / 播放页 / 锁屏各订阅这一份。
    ///
    /// ⚠️ 引擎事件由 `PlayerService` 统一回主线程再发，所以这条流也在主线程上推，
    /// 界面直接订阅就能用，不用再跳线程。
    let state: Observable<PlayerState>

    /// 播放模式变更流 —— 从 `state` 派生，**只在模式真的变了才发**。
    let playbackMode: Observable<PlaybackMode>

    /// 「现在播到哪儿了」（秒）—— 引擎薄壳 10Hz 报上来的读数。
    ///
    /// 🔴 **单独一条流，不塞进 `state`**：它 10Hz 变一次，混进 `PlayerState` 的话，
    /// 每个订阅总状态的界面每秒要重算十几次（`PlayerState` 那条注释里写了）。
    /// 锁屏 / 进度条这类**只关心进度**的订阅方订这条。
    ///
    /// ⚠️ **它不是"事件"** —— 是**一直有的一个读数**，所以底下垫的是 `BehaviorRelay`：
    /// 新订阅方一订上就拿到当前值，不用干等下一次 tick。
    let position: Observable<TimeInterval>

    /// 跳进度这件事 —— **事件**，不是读数。松手 / 点行 / 锁屏拖各发一次。
    ///
    /// 🔴 不能并进 `position`：那条 10Hz 一直在变。锁屏要的是「跳了才再写系统」，
    /// 订这条才订得动，订 `position` 就会按秒刷。
    let seeks: Observable<TimeInterval>

    /// 队列此刻的样子 —— **只有队列页订它**（为什么不并进 `state` 见 `QueueSnapshot`）。
    let queueSnapshot: Observable<QueueSnapshot>

    /// 「刚才那一首为什么没放成」—— 每一次失败发一次，只带**值**、不带文案。
    ///
    /// 🔴 **不是状态的一部分**：失败提示是**一次性的事**（弹完就走），
    /// 跟 `seeks` 一样垫 `PublishRelay` —— 新订户不该补看到旧的失败。
    ///
    /// 🔴 **塞进 `PlayerState.Status.failed` 不行**：那得改状态的形状、牵动所有
    /// `switch status`，而**没有一处需要「持久地看着原因」**。
    ///
    /// ⚠️ 文案不在这儿：播放域只产 `PlaybackError`，「翻成人话」是界面的事
    /// （`PlaybackError+Display` + 播放页拼句）。
    let failureReason: Observable<PlaybackError>

    /// 状态的底 —— **只由 `update` 写**（见那儿）。
    private let stateRelay = BehaviorRelay(value: PlayerState.idle)

    /// 队列快照的底 —— **只由 `mutateQueue` 写**（见那儿）。
    private let queueRelay = BehaviorRelay(value: QueueSnapshot.empty)

    /// 进度读数的底 —— 和 `stateRelay` 一样**只在主线程读写**（`service.onPosition` 在主线程上叫）。
    private let positionRelay = BehaviorRelay<TimeInterval>(value: 0)

    /// 跳进度事件的底。`PublishRelay`：新订户不该当一次假 seek。
    private let seekRelay = PublishRelay<TimeInterval>()

    /// 失败原因的底。`PublishRelay`：同上，失败是事件、不是读数。
    private let failureReasonRelay = PublishRelay<PlaybackError>()

    /// 引擎薄壳。
    private let service: PlayerService

    /// 音频会话 —— 「要开始播了，先把路铺好」。全工程碰 `AVAudioSession` 的只有它。
    ///
    /// 🔴 **由装配层传进来，没有默认值**：`AudioSessionController` 是 `@MainActor` 的，
    /// 而**默认参数表达式是在非隔离上下文里算的** ⇒ 写默认值根本编不过。
    ///
    /// ⚠️ **它自己挂的观察归它自己摘**（它自己的 `deinit`，见那个文件）—— 这里**不收**。
    /// 两个理由：① 观察是它挂的，谁挂谁摘，从别人那儿拆等于同一件事记两处；
    /// ② `deinit` 在 Swift 里**永远是非隔离的**，在这儿根本调不到它的主隔离方法。
    private let session: AudioSessionController

    /// 播放次数 —— 统计不是"放哪首"，所以是独立类型；这里只告诉它「新的一趟」和「进度读数」。
    /// **由装配层注入**（写库那一下在它里面），本类不认识 `LibraryStore`。
    private let playCount: PlayCountTracker

    /// 睡眠定时。到期立刻停走它注入的 `pause`；「等这首完」由这里在播完 / 后继出声时问它。
    private let sleep: SleepTimerSession

    /// 队列本体 —— 只在这个类手里，外面拿不到（要"下一首是谁"就走 `playNext()`）。
    ///
    /// ⚠️ **改它只许走 `mutateQueue`**，直接读（`peek…` / `isEmpty`）可以 ——
    /// 绕过去改一次，队列页上那份就和真队列对不上了。
    ///
    /// ⚠️ 它**只存编号**（见 `PlayQueue` 开头）：要用的时候拿编号来下面这张表里查。
    private let queue = PlayQueue()

    /// 「这首歌现在是什么样」—— **全工程唯一一份**。
    ///
    /// 🔴 队列只存编号、不存歌本身；引擎和界面要的那一份都从这儿取。
    /// 库里那一行变了（歌词被编辑 / 元数据改了），装配层就把**整张表**换掉
    /// （见 `updateTrackTable`）⇒ **不存在"内容变了要通知谁"这回事**，也就漏不了。
    private var trackTable: [Track.ID: Track] = [:]

    /// 订阅的生命 —— 跟这个对象同寿。
    private let disposeBag = DisposeBag()

    /// 号 —— 「交给引擎的活」的身份：正在放的是哪一张、排给库的下一首是哪一张。
    ///
    /// ⚠️ **为什么单独一个类型**：「发号 + 记住谁拿着哪张」是一件事的三面，散成三个字段
    /// 加两个方法，等于让每个调用点自己拼。形状与理由见 `TicketIssuer`。
    private let tickets = TicketIssuer()

    /// 连着几首没放成了 —— 有一首**真的播起来**（`.ready`）就归零。
    private var consecutiveFailures = 0

    /// 连着几首放不了就放弃（判据见 `PlaybackFailureRecovery`）。
    private static let failureLimit = 3

    /// 卡死看门狗 —— 管「在播但进度不动」的时间账。**它只回决定，不动引擎**。
    private var stallWatchdog = StallWatchdog()

    /// stall / 冷恢复首次起播：`play(pauseAfterStart:)` 后等 `.ready` 再 seek→resume。普通从头 `start` 会清掉。
    private var pendingSeekAfterReady: TimeInterval?

    /// 「用户想听、但环境不让出声」时压下的**两张一次性票** ＋ 蓝牙那条的看门狗。
    ///
    /// 🔴 打断票与 HFP 票**住在一起**（理由见 `PlaybackHolds` 顶上）：判断层要的
    /// `playbackIsIntended` 就是它俩的并集 —— 拆成两个字段散在各个调用点，早晚漏掉一张。
    private let holds = PlaybackHolds()

    /// 会话落盘。
    private let sessionPersistence: PlaybackSessionPersistenceCoordinator

    /// 启动恢复生命周期。
    private var restoreLifecycle = PlaybackSessionRestoreLifecycle()

    /// 会话写入世代（单调）。
    private var sessionWriteGeneration: UInt64 = 0

    init(
        playCount: PlayCountTracker,
        sleep: SleepTimerSession,
        service: PlayerService = PlayerService(),
        session: AudioSessionController,
        sessionPersistence: PlaybackSessionPersistenceCoordinator = PlaybackSessionPersistenceCoordinator()
    ) {
        self.playCount = playCount
        self.sleep = sleep
        self.service = service
        self.session = session
        self.sessionPersistence = sessionPersistence
        state = stateRelay.asObservable()
        position = positionRelay.asObservable()
        seeks = seekRelay.asObservable()
        failureReason = failureReasonRelay.asObservable()
        queueSnapshot = queueRelay.asObservable().distinctUntilChanged()
        playbackMode = state.map(\.playbackMode).distinctUntilChanged()
        service.onEvent = { [weak self] event in self?.handle(event) }
        sleep.bind(
            currentTrackID: { [weak self] in self?.stateRelay.value.track?.id },
            pause: { [weak self] in self?.pauseForSleep() }
        )
        sleep.changes
            .subscribe(onNext: { [weak self] _ in self?.syncPreload() })
            .disposed(by: disposeBag)
        // 进度读数是**一直有的**，来了就灌进底里、交给播放次数累计（它已经在主线程上，见上面「线程」）。
        // 只认当前这首的读数：换歌边界上，库可能还在报上一首、或已经在报还没被认下的下一首。
        service.onPosition = { [weak self] reading in
            guard let self, reading.ticket == self.tickets.current else { return }
            // 引擎 currentTime 只在「正在播」时是活读数。
            // loading / paused 时它常是 0 或 seek 前的旧值 —— 若写进 relay，会盖掉
            // start/seek/恢复已经写好的位置（恢复后再开条子停在 0、一点播放才跳，就是这样来的）。
            // 非在播时的位置只由 start / seek / 恢复路径显式写入。
            guard self.stateRelay.value.status == .playing else { return }
            self.positionRelay.accept(reading.seconds)
            let state = self.stateRelay.value
            self.playCount.noteListening(
                at: reading.seconds,
                isPlaying: true,
                playingTrackID: state.track?.id
            )
            self.observeStall(at: reading.seconds)
        }
        // 系统换音频出口（拔耳机 / 蓝牙断开 / 被抢到通话档 / AirPlay 回本机）—— 全工程**唯一**
        // 订 `routeChangeNotification` 的地方在 `AudioSessionController`；这里只接它收好的**值**，
        // 「该暂停 / 重抢 / 续播」走 `Decisions/AudioRoutePolicies.swift`。
        session.startObservingRouteChanges { [weak self] facts in
            self?.handleRouteChange(facts)
        }
        // 媒体服务重启（`mediaserverd` 崩了又起）—— 全工程**唯一**订 `mediaServicesWereReset` 的地方
        // 也在 `AudioSessionController`（观察在那边、接线在这边，和上一根线同一条规矩：
        // 「做决定的那个」在这一层，所以线接在这儿）。
        session.startObservingMediaServices { [weak self] in
            self?.handleMediaServicesReset()
        }
        // 「真·不出声了」这个窗口一开 ⇒ 把会话**还回去**（一处订阅，不是 7 个停机点各补一句 ——
        // 那样漏一处就永不释放）。
        //
        // 🔴 判据 ＝ `audioSessionRelease(for:)`（`SessionPlanPolicy`，纯函数）：
        // **暂停不还**—— 暂停不是停播，用户随时点继续；一还把系统就把引擎从背后停掉，
        // 库的「继续」变成无声失败（「点播放看着在播、没声」就是这么来的）。
        // `skip(1)` 丢掉 `BehaviorRelay` 的初值（idle ⇒ 该还，但那一刻会话从没激活过，
        // 不该去"还"一个没拿过的东西）。
        // ⚠️ 这里只能写 `skip(1)` —— RxSwift **没有** `dropFirst`（那是别的框架的叫法）。
        // ⚠️ 为什么 `activate`（`prepareForPlayback`）仍留在动作里、不并到这条订阅：
        // 它必须跑在引擎被叫起来**之前**（几毫秒的窗口），订阅是异步的 ⇒ 两边时机要求不同，
        // 不是"同一个决定两处实现"。
        // ⚠️ 代价：`setActive(false)` 是**同步跨进程调用**（蓝牙 / AirPlay 下可能拖几百毫秒），
        // 跑在主线程。记在这儿，免得日后当成"卡顿"重查。
        stateRelay
            .map(\.status)
            .map { audioSessionRelease(for: $0) }
            .distinctUntilChanged()
            .skip(1)
            .subscribe(onNext: { [weak self] release in
                guard release == .release else { return }
                self?.session.deactivate()
            })
            .disposed(by: disposeBag)
        // 看门狗每一拍的两口：**问判据**、**兑现续播**。
        // 判据本身不在这两口里 —— 它们只把「现读的路由 ＋ 当前状态」凑齐交出去。
        holds.evaluateHold = { [weak self] in
            self?.currentBluetoothDeferredDecision() ?? .wait
        }
        holds.resumeHeld = { [weak self] in
            self?.resumeHeldTrack()
        }
    }

    // MARK: - 动作

    /// 播一整列，从 `track` 那一首开始。
    ///
    /// - Parameters:
    ///   - track: 用户点的那一首。
    ///   - list: 他点的时候**看到的那一列**（按当时的排序、去掉搜索没命中的那些）。
    ///     往后走就照这一列 —— 所以"搜了周杰伦、点一首"，播完接着放的是周杰伦，
    ///     而不是跳回整个曲库。
    func play(_ track: Track, in list: [Track]) {
        restoreLifecycle.supersedeForPlaybackIntent()
        if let index = list.firstIndex(where: { $0.id == track.id }) {
            mutateQueue { $0.replace(with: list.map(\.id), startingAt: index) }
        } else {
            // 点的那首不在给的列表里 —— 那就只播这一首，
            // 别让队列的第一首变成别的歌（不然"下一首"会跳到一首他没点过的）。
            mutateQueue { $0.replace(with: [track.id], startingAt: 0) }
        }
        start(track)
    }

    /// 曲库第一份到手后调一次：冷恢复队列 / 曲 / 进度 / 暂停。**不**装引擎、**不**自动开播。
    ///
    /// - Returns: 是否恢复成功（失败 / 已被点播作废 ⇒ `false`）。
    @discardableResult
    func restoreSessionIfNeeded(availableIDs: Set<Track.ID>) -> Bool {
        guard let token = restoreLifecycle.begin() else { return false }
        guard let snapshot = sessionPersistence.load(),
              let plan = playbackSessionRestorationPlan(
                snapshot: snapshot,
                availableIDs: availableIDs
              ) else {
            restoreLifecycle.complete(token: token)
            return false
        }
        return applyRestoration(plan, token: token)
    }

    /// 进程可能没了时落盘 —— 挂起与终止两个时机都要接：`sceneDidDisconnect` / `applicationWillTerminate`。
    /// 进后台**不**写（进程还活着，真相在内存）。
    func persistSession() {
        sessionWriteGeneration &+= 1
        let generation = sessionWriteGeneration
        let snapshot = playbackSessionSnapshot(
            hasCurrentTrack: stateRelay.value.track != nil,
            capture: queue.sessionCapture,
            playbackMode: stateRelay.value.playbackMode,
            isPlaying: stateRelay.value.status == .playing,
            position: positionRelay.value,
            now: Date()
        )
        if let snapshot {
            sessionPersistence.enqueue(.save(snapshot), generation: generation)
            restoreLifecycle.didPersistCurrentSession()
        } else if restoreLifecycle.permitsEmptySessionClear {
            sessionPersistence.enqueue(.clear, generation: generation)
        } else {
            return
        }
        sessionPersistence.drainSynchronously()
    }

    /// 下一首 —— 迷你条 / 播放页按键。
    ///
    /// ⚠️ 按键**回绕**（`PlayNext.userSkipMode`）。到头停只约束自动播完，见 `handleFinished`。
    func playNext() {
        guard let id = mutateQueue({ $0.advance(mode: PlayNext.userSkipMode) }),
              let next = trackTable[id] else { return }
        start(next)
    }

    /// 现在装着的那一首 —— **只读**。
    ///
    /// ⚠️ **不是第二份真相**：直接从 `stateRelay` 里读，跟 `hasCurrentTrack` / `status` 一个路子。
    /// 「换一首」走 `start`；「同一首内容变了」**不用谁去通知** —— 表一换它就跟着新（见 `updateTrackTable`）。
    var currentTrack: Track? { stateRelay.value.track }

    /// 现在有没有装着一首歌 —— **读** `PlayerState.track`，不是另存一份。
    ///
    /// 用途：打开播放页的门闩（`AppRouter.presentNowPlaying`）。无歌不许弹页
    /// （跟 `showPlayView` 那个 `currentTrack != nil` 门闩一个效果）。
    var hasCurrentTrack: Bool { currentTrack != nil }

    /// 现在在不在播 —— **读一次**用的口子（`isPlaybackActive`：装载中也算在播）。
    ///
    /// 用途：给订阅方做**初值**（页面刚建好、还没收到第一次推送时该画成什么样）。
    /// ⚠️ **要"跟着播停变"就去订 `state` 那条流** —— 这个是给"读一次"的场景用的。
    var stateRelayCurrentIsPlaying: Bool { stateRelay.value.isPlaybackActive }

    /// 这一秒的进度读数 —— **读一次**用的口子。
    ///
    /// ⚠️ **要"跟着进度走"就去订 `position` 那条流**；这个是给"按一下、读一次"的场景用的
    /// （编辑歌词页的「打点」要"现在几秒"），**别拿它当流轮询**（拿 0.1 s Timer 轮询就是这么来的）。
    var currentPosition: TimeInterval { positionRelay.value }

    /// 库里的行**整张换掉** —— 「这首歌现在是什么样」只有这一处进得来。
    ///
    /// 🔴 **谁调它**：装配层（`AppServices`）盯曲库流之后调。这个类**不认识 `LibraryStore`** ——
    /// 「库里现在有哪些歌、各是什么样」是装配层喂进来的，跟 `removeTracks(fromQueue:)` 是同一条规矩。
    ///
    /// 🔴 **为什么是"整张换"而不是"换一条"**：队列只存编号（见 `PlayQueue` 开头），
    /// 「歌是什么」只有这张表一处 ⇒ 表一换，**所有**要用到它的地方自动就是新的。
    /// 换成"谁变了通知谁"的话，就得记住"队列里那几份也要跟着换" —— 漏一处就是那个坑。
    ///
    /// ⚠️ 换完顺手把 `state.track` 也刷成表里那一份（当前曲还在表里的话）——
    /// 这是**唯一**一处刷新当前曲的地方，而且**无条件**（不判断"是不是当前曲"）。
    /// 推出去之后 `LyricsManager` 会因为 `state.track` 变了而重取歌词。
    func updateTrackTable(_ tracks: [Track]) {
        trackTable = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })

        guard let current = stateRelay.value.track,
              let fresh = trackTable[current.id],
              fresh != current else { return }
        update { $0.track = fresh }
    }

    /// 现在这个态 —— 锁屏远程命令用（判断在 `RemoteCommandPolicy`）。
    var status: PlayerState.Status { stateRelay.value.status }

    var currentPlaybackMode: PlaybackMode { stateRelay.value.playbackMode }

    /// 队列里的**编号**换成歌 —— 查表只有这一处。
    ///
    /// ⚠️ 查不到就是 `nil`：那只可能是"歌刚被删、队列还没剔"那一瞬，调用方照 `nil` 处理。
    private func queued(_ id: Track.ID?) -> Track? {
        guard let id else { return nil }
        return trackTable[id]
    }

    /// 看一眼下一首是谁 —— **不动队列**。预览跟按键同一条回绕规则。
    func peekNextTrack() -> Track? {
        queued(queue.peekNext(mode: PlayNext.userSkipMode))
    }

    /// 看一眼上一首是谁 —— **不动队列**。同上。
    func peekPreviousTrack() -> Track? {
        queued(queue.peekPrevious(mode: PlayNext.userSkipMode))
    }

    /// 把指定这首歌排到「下一首」—— 列表行菜单里那项「下一首播放」。
    ///
    /// - 如果现在**没在播任何歌**（队列空），就直接从这一首开始播；
    /// - 否则把它排进插队区（`PlayQueue.insertNext`），播完当前这首就轮到它。
    ///   连点多首按点的先后排，先点的先播。
    func playNext(_ track: Track) {
        if queue.isEmpty {
            play(track, in: [track])
        } else {
            mutateQueue { $0.insertNext(track.id) }
        }
    }

    /// 上一首 —— 按键回绕，同 `playNext`。
    func playPrevious() {
        guard let id = mutateQueue({ $0.previous(mode: PlayNext.userSkipMode) }),
              let previous = trackTable[id] else { return }
        start(previous)
    }

    /// 队列页点了第 `index` 行。
    ///
    /// - 点的是**正在播的那一格**：在播 / 在装 ⇒ 什么都不做；否则交给 `togglePlayPause`
    ///   （暂停 ⇒ 接着放；播完 / 放不了 ⇒ 这首从头放）。**不从头重播在播的歌**。
    /// - 点的是**别的行** ⇒ 跳过去播。
    ///
    /// 🔴 带上那一行的歌曲 id 再核一次：页面画的那份快照和真队列之间隔着一次推送，
    /// 位置对不上就说明这一下是**过期**的，丢掉。
    func playQueueItem(at index: Int, trackID: Track.ID) {
        let ids = queue.trackIDs
        guard ids.indices.contains(index), ids[index] == trackID else { return }

        guard index != queue.currentIndex else {
            if !stateRelay.value.isPlaybackActive { togglePlayPause() }
            return
        }
        guard let id = mutateQueue({ $0.jump(to: index) }), let track = trackTable[id] else { return }
        start(track)
    }

    /// 队列页 × 掉第 `index` 行 —— **只移出队列**，歌还在库里。
    ///
    /// 删的是正在播的那一格 ⇒ 跟曲库删当前曲同一条规矩（`continueAfterCurrentRemoved`）。
    /// 过期判断同 `playQueueItem`。
    func removeQueueItem(at index: Int, trackID: Track.ID) {
        let ids = queue.trackIDs
        guard ids.indices.contains(index), ids[index] == trackID else { return }

        // ⚠️ 先记下"删的是不是当前格" —— `remove` 会把游标往前挪，之后再问就问不出原值了。
        let wasCurrent = index == queue.currentIndex
        mutateQueue { $0.remove(at: index) }
        guard wasCurrent else { return }
        continueAfterCurrentRemoved()
    }

    /// 换播放模式（互斥四档）。进出 `.shuffle` 时同步队列洗牌。
    func setPlaybackMode(_ mode: PlaybackMode) {
        mutateQueue { $0.setShuffled(mode == .shuffle) }
        update { $0.playbackMode = mode }
    }

    /// 播放 / 暂停来回切 —— 迷你条和播放页共用这一个口子。
    ///
    /// 五种态各是什么行为：
    /// - 在播 → 暂停；
    /// - 暂停 → 从原地接着放；
    /// - 播完了 / 放不了 / 没装 → **有歌就把这一首从头放**（没装就什么都不做）；
    /// - 正在装载 → 什么都不做。
    func togglePlayPause() {
        switch stateRelay.value.status {
        case .playing:
            // 乐观更新：界面**立刻**显示「暂停」，不等引擎回调跨「引擎队列 → 主线程」两个 hop 才变色。
            // 引擎真的暂停了会回报 `.paused`，和这里对上；那一下慢了或丢了，按钮也不再卡半拍。
            update { $0.status = .paused }
            stallWatchdog.reset()
            service.pause()

        case .paused:
            // 🔴 **HFP 门闩**：蓝牙此刻被别的 App 抢成通话档（微信语音等）时，去激活我们的
            // 非混音会话会把对方刚开的录音打断。压一张一次性续播票、保持暂停，等回到能放的档再续。
            // ⚠️ 挡在**所有**「要出声」的动作之前（含下面那条冷恢复起播）。
            if session.isCurrentRouteBluetoothHFP {
                if let trackID = stateRelay.value.track?.id { holds.hold(trackID: trackID) }
                return
            }
            // 冷恢复后引擎还没装：不能 resume，要按钉住的进度起播。
            if stateRelay.value.engineNeedsPrepare {
                guard let track = stateRelay.value.track else { return }
                let resumeAt = positionRelay.value
                start(track, resumeAt: resumeAt)
                return
            }
            // 恢复票用掉：用户这一下就是「接着放」，被打断那件事到此结束。
            holds.consumeInterruption()
            // 真的要点播放了 ⇒ HFP 那张票（如果有）也用不着了。
            holds.clearHold()
            // 续播同样是「要出声了」，会话得先在 —— 打断 / 通话会把它收走，和 `start` 同一条规矩。
            session.prepareForPlayback()
            // 乐观更新：立刻显示「播放」（同上）。
            update { $0.status = .playing }
            stallWatchdog.reset()
            service.resume()

        case .stopped, .failed, .idle:
            // 🔴 「现在装的是哪一首」**只从状态里读** —— 不另存一个字段。
            // 另存一份就是"同一个事实有两个人记着"，而这里根本不需要：
            // `stateRelay.value` 本来就是**同步**读的，不用绕。
            //
            // ⚠️ `.failed` 也走这条：再点一下就再试一次（用户可能刚把文件放回去）。
            if let track = stateRelay.value.track { start(track) }

        case .loading:
            // 正在装载 —— 按了不动。别把刚点的那一下打断
            // （再点同一首只会让它从头再装载一遍，用户看到的还是"没反应"）。
            break
        }
    }

    /// 跳到指定位置（秒）—— 播放页进度条松手 / 点歌词行、编辑页点时间，都走它。
    ///
    /// 🔴 **先改进度、再叫引擎**（顺序不能反）：进度那条流的下一份读数最多 100 ms 才来，
    /// 先改的话滑块**立刻**停在手指松开的地方；反过来它会先跳回旧位置、再跳到新位置 —— 闪一下。
    /// 跟 `togglePlayPause` 里那个乐观更新是同一套道理。
    ///
    /// ⚠️ 路上已有的旧读数由 `PlayerService.seek` 同步作废（位置世代），不靠这里再挡一层。
    ///
    /// 秒数在 `clampedSeekPosition` 夹住：锁屏没有滑杆量程，判断只许这一处做。
    func seek(to seconds: TimeInterval) {
        guard let target = clampedSeekPosition(
            requested: seconds,
            duration: stateRelay.value.duration
        ) else { return }
        positionRelay.accept(target)
        seekRelay.accept(target)
        stallWatchdog.reset()
        // 冷恢复后引擎未装：只改展示进度，首次点播放用 relay 里的值起播。
        if !stateRelay.value.engineNeedsPrepare {
            service.seek(to: target)
        }
    }

    // MARK: - 引擎事件

    /// 引擎来的事件先按号分路（`Decisions/EngineEventRoutePolicy.swift`）。
    private func handle(_ event: PlayerService.Event) {
        switch engineEventRoute(
            ticket: event.ticket,
            current: tickets.current,
            armed: tickets.armed?.ticket
        ) {
        case .stale:
            return
        case .current:
            handleCurrent(event.kind)
        case .successor(let isArmed):
            handleSuccessor(event.kind, ticket: event.ticket, isArmed: isArmed)
        }
    }

    /// 当前这首的事件 → 新状态。**只会改 `status` / `duration`** ——
    /// 「装的是谁」只有 `start(_:)` 和 `acceptSuccessor` 能定，别让引擎事件悄悄把歌给换了。
    private func handleCurrent(_ kind: PlayerService.Event.Kind) {
        switch kind {
        case .status(let reported):
            applyStatus(reported)
        case .ready(let duration):
            applyReady(duration)
        case .finished:
            handleFinished()
        case .failed(let error):
            handleFailure(error)
        }
    }

    /// 引擎报了态 ⇒ 按判断层算出的下一态落状态。
    private func applyStatus(_ reported: ReportedPlaybackStatus) {
        // 「引擎报了 X、我们现在是 Y ⇒ 该变成什么」是**判断**，所以它不在这个类里
        // （`Decisions/PlaybackStatusPolicy.swift`，纯函数、能单测）。这儿只管执行。
        let previous = stateRelay.value.status
        // 引擎在我们**在播 / 正在装载**时报「停」—— 我们主动停机之前都先把状态落好了
        // （见 `PlaybackStatusPolicy` 那条注释），所以这一条不是我们叫的：是**被打断**
        //（通话、别的 App 抢音频）。记一张一次性恢复票，给判断层去认引擎随后可能自己
        // 续回来的那条「在播」；换歌或按播放都会把它用掉/作废。
        if reported == .stopped, previous == .playing || previous == .loading {
            holds.noteInterruptionPause()
        }
        let next = playbackStatus(
            after: reported,
            current: previous,
            interruptionPaused: holds.isAwaitingInterruptionEnd
        )
        // 引擎真的又响了（打断结束 + 系统允许恢复）⇒ 恢复票已经用掉。
        if next == .playing {
            holds.consumeInterruption()
        } else {
            stallWatchdog.reset()
        }
        update { $0.status = next }
    }

    /// 解码器起来了 ⇒ 真的开播：复位失败计数、续播 / stall 先 seek 再进 `.playing`。
    private func applyReady(_ duration: TimeInterval?) {
        // 解码器起来了 —— 到这一步才算**真的**在播（引擎早先那句「在播」不算数，
        // 理由见 `Decisions/PlaybackStatusPolicy.swift`）。
        // 「可以播了」和「时长是多少」是**同一个时刻**的事，所以一次写完。
        //
        // 🔴 失败计数在这儿归零 —— 它数的是"**连着**几首没放成"，
        // 播起来一首就说明"坏的不是环境"。
        consecutiveFailures = 0
        // 🔴 装载中被暂停（路由丢失：拔耳机 / 蓝牙断开）⇒ 解码器起来了也**不许**把它拉回在播：
        // 那一下暂停是「用户拔了设备」的后果，引擎必须保持不出声。只把时长补上就走。
        guard stateRelay.value.status != .paused else {
            if let duration { update { $0.duration = duration } }
            return
        }
        // 续播 / stall：先 seek（作废装载期 currentTime=0），再进 `.playing`。
        // 反过来的话 onPosition 门闩一开，0 会盖掉续播点 —— 迷你条先出现、闪没、再回来。
        if let seekTo = pendingSeekAfterReady {
            pendingSeekAfterReady = nil
            if seekTo > 0 {
                positionRelay.accept(seekTo)
                stallWatchdog.reset()
                // 与 `play(pauseAfterStart:)` 成对：快照在 paused 的 decodingStarted 已发布，
                // seek 后再 resume，才从续播点出声（边播边 seek 会静默失败，见 PlayerService）。
                service.seek(to: seekTo)
                service.resume()
            }
        }
        update { state in
            state.status = .playing
            if let duration { state.duration = duration }
        }
    }

    /// 号比当前大的事件 —— 库自己往后走了。
    private func handleSuccessor(_ kind: PlayerService.Event.Kind, ticket: Int, isArmed: Bool) {
        switch kind {
        case .status, .finished:
            // 播放态 / 全部放完说的是**引擎**，不是某一首；换歌边界那一下它们可能已经贴上了下一首的号。
            handleCurrent(kind)

        case .ready(let duration):
            // 下一首出声了 —— 先验货：是不是队列现在说的那首（`Decisions/SuccessorHandoverPolicy.swift`）。
            if sleep.consumeHoldIfFinished(trackID: stateRelay.value.track?.id) {
                tickets.current = tickets.next()
                stopForSleepHold()
                return
            }
            let queueNextID = queue.peekNext(mode: stateRelay.value.playbackMode)
            let handover = successorHandover(
                isArmed: isArmed,
                armedTrackID: tickets.armed?.trackID,
                queueNextID: queueNextID
            )
            if handover == .accept, let next = queued(queueNextID) {
                acceptSuccessor(next, ticket: ticket, duration: duration)
            } else {
                redirectFromOrphanSuccessor()
            }

        case .failed:
            // 排着的那首提前打开就失败了：什么都不做，当前这首照常放完。
            // 放完后 `handleFinished` 走普通路去播它，真打不开就走"放不了就跳过"—— 失败只有一条处理路径。
            break
        }
    }

    /// 库无缝接上的就是队列说的下一首 ⇒ 状态跟着换。没有 `start`：引擎早就在放它了。
    private func acceptSuccessor(_ track: Track, ticket: Int, duration: TimeInterval?) {
        tickets.current = ticket
        // 排着的那首已经成了当前这首；库的等候队列此刻本来就是空的（它刚把这首取走），不用 `clearNext`。
        tickets.armed = nil
        pendingSeekAfterReady = nil
        stallWatchdog.reset()
        // `peekNext` 和 `advance` 走的是同一条规则（`PlayQueue`），所以这一步落到的就是 `track`。
        mutateQueue { $0.advance(mode: stateRelay.value.playbackMode) }

        // 顺序同 `start`：进度先归零，再改状态。
        positionRelay.accept(0)
        playCount.beginPlay(of: track.id)
        consecutiveFailures = 0
        // 播放态不动：无缝接上不改引擎的档位（边界那一下用户刚好按了暂停，就该还是暂停）。
        update { state in
            state.track = track
            state.duration = duration ?? 0
            state.engineNeedsPrepare = false
        }
    }

    /// 库接上的是**孤儿**（最后约 0.37 秒里用户改了下一首，库已经取走旧的那首撤不回来）
    /// ⇒ 队列说了算：立即播放队列说的那首。
    private func redirectFromOrphanSuccessor() {
        if let id = mutateQueue({ $0.advance(mode: stateRelay.value.playbackMode) }),
           let next = trackTable[id] {
            start(next)
            return
        }
        // 队列到头了：同"放完到头"—— 停下，条子还显示刚才那首。
        // 先换号：孤儿接下来的事件一律过期。
        tickets.current = tickets.next()
        update { $0.status = .stopped }
        service.stop()
    }

    /// 一首播完了 —— 往后走一首；走到头就停在原地。
    private func handleFinished() {
        // 🔴 **只有"真的在播"的时候，播完才算数** —— 判断在 `Decisions/AdvanceEligibilityPolicy.swift`。
        // 正常情况这儿一定是「在播」：库在播完时**只发这一条** —— 它认了 `endOfAudio`
        // 就不再补发「停了」（见 `PlayerServiceDelegate`）。它防的是**状态已经被别的事改掉**
        // 的那一刻：比如同一轮里先收到了「放不了」，那时不该再往下走一首。
        guard advanceEligibility(status: stateRelay.value.status) == .advance else { return }

        if sleep.consumeHoldIfFinished(trackID: stateRelay.value.track?.id) {
            stopForSleepHold()
            return
        }

        guard let id = mutateQueue({ $0.advance(mode: stateRelay.value.playbackMode) }),
              let next = trackTable[id] else {
            // 到头了：停下，但**还装着这一首**（条子还显示它）。
            // 🔴 引擎得我们来停：实现了 `endOfAudio`，库就把收尾交给我们、自己不停（见 `PlayerServiceDelegate`），
            // 只改状态的话引擎会一直空转。
            update { $0.status = .stopped }
            service.stop()
            return
        }
        start(next)
    }

    /// 一首放不了 —— 按 `PlaybackError` 分流。
    private func handleFailure(_ error: Error) {
        let reason = playbackError(from: error)
        // 这一首没放成 ⇒ 先告诉订阅方「为什么」。
        // 🔴 **发在分流之前**：跳过那条路会 `start(next)` 换歌，发晚了标题就变成下一首的了。
        // 也正因为如此，**收成一个发点**（发在分流前）而不是发在那两条 `status = .failed`
        // 出口上 —— 后者会漏掉"跳过"那一种（那是用户最该知道的一种）。
        failureReasonRelay.accept(reason)

        switch reason {
        case .engineFailed:
            // 引擎真坏了：停机，不跳歌（跳只会让条子唰唰跳）。
            //
            // 🔴 **先落状态、再停机**：停机也会让引擎报一条「停」，而那条「停」有歧义
            // （分不清是我们叫的、还是系统把音频抢走了）。状态先落成 `.failed`，
            // 那条「停」就只会被读成「我们自己收的尾」——和 `PlayerService` 的失败收尾同一条规矩。
            update { $0.status = .failed }
            service.stop()

        case .fileMissing, .unsupportedFormat:
            consecutiveFailures += 1

            // 🔴 先**问**有没有下一首、再决定跳不跳 —— 不能先跳了再说。
            // 跳了才发现"该放弃"的话，游标已经白白往前走了一格。
            let recovery = playbackFailureRecovery(
                consecutiveFailures: consecutiveFailures,
                canAdvance: queue.peekNext(mode: stateRelay.value.playbackMode) != nil,
                limit: Self.failureLimit
            )
            // ⚠️ 下面那个 `guard` 靠**短路**：判定是"放弃"时，`advance` 那一步**不会执行**
            // （条件从左往右求值，第一个不成立就停）—— 所以游标不会被白白推走一格。
            guard recovery == .skipToNext,
                  let id = mutateQueue({ $0.advance(mode: stateRelay.value.playbackMode) }),
                  let next = trackTable[id] else {
                update { $0.status = .failed }
                return
            }
            start(next)
        }
    }

    // MARK: - 曲库

    /// 库里这些歌没了 —— 把队列里的它们剔掉。
    ///
    /// 🔴 谁调它：`AppServices` 订曲库流、算 diff 之后调。这个类不自己盯库 ——
    /// "歌被删了"是装配层算出来告诉它的，它只管剔队列、并处理"正在播的那首被剔了"的后果。
    ///
    /// 🔴 **正在播的那首也在被剔名单里**：立刻切到队列里**紧挨的下一首**接着播
    /// （`applyRemoval` 把游标挪到「被删那首的前一格」，再 `advance` 正好落到原下一首）。
    /// 队列空了 / 删的是队尾且后面没有歌 ⇒ 停引擎、清成 idle（播放页因 `!hasTrack` dismiss）。
    ///
    /// ⚠️ 推翻两处错误口径：
    /// - 「立刻停、不播替代曲」；
    /// - 「删完再走带回绕的下一首」（会跳格、队尾回第一首）—— **不照抄**。
    ///
    /// 推进用 `PlayNext.afterRemovalMode`（`.sequential`），见该常量注释。
    func removeTracks(fromQueue removedIDs: Set<Track.ID>) {
        let currentID = stateRelay.value.track?.id
        let currentWasRemoved = currentID.map { removedIDs.contains($0) } ?? false

        mutateQueue { $0.applyRemoval(removedIDs) }

        guard currentWasRemoved else { return }
        continueAfterCurrentRemoved()
    }

    // MARK: - 换出口（routeChange）

    /// 用户**还想不想听** —— 判断层要的「意图」，跟「现在在不在响」是两件事。
    ///
    /// 三种都算想听：在播 / 在装 · 欠一次打断恢复（打断票未销）· 手里压着 HFP 续播票
    /// （用户按了播放、被我们压住的那一下）。
    private var playbackIsIntended: Bool {
        // 一半在这儿（现在真的在响 / 在装），一半在票上（欠一次恢复 / 压着续播）。
        stateRelay.value.isPlaybackActive || holds.hasPendingHold
    }

    /// 系统换了音频出口 —— 判断（`Decisions/AudioRoutePolicies.swift`）说该干什么，这里执行。
    ///
    /// 处理**顺序由判断层钉死**：AirPlay 重抢 → 外接丢失暂停 → 蓝牙延期续播。
    private func handleRouteChange(_ facts: AudioRouteChangeFacts) {
        let action = audioRouteChangeAction(
            facts: facts,
            playbackIsIntended: playbackIsIntended,
            isAwaitingInterruptionEnd: holds.isAwaitingInterruptionEnd,
            isPlaybackActuallyActive: stateRelay.value.isPlaybackActive,
            suspendedTrackID: holds.heldTrackID,
            currentTrackID: stateRelay.value.track?.id
        )
        switch action {
        case .none:
            break
        case .reacquireAfterAirPlay:
            reacquireAfterAirPlayReturn()
        case .pauseForExternalLoss:
            pauseForExternalLoss()
        case .bluetoothDeferred(let decision):
            applyBluetoothDeferredResume(decision)
        }
    }

    /// 外接真丢了（拔耳机 / 蓝牙断开）—— **暂停**，别让歌从扬声器外放。
    ///
    /// 🔴 跟打断暂停**分开**：**不压打断票**（`holds` 里那张语义正好相反）；
    /// 用 `pause` 不用 `stop`（进度、队列都留着，插回去点播放就接着听）。
    private func pauseForExternalLoss() {
        guard stateRelay.value.status == .playing || stateRelay.value.status == .loading else { return }
        // 出口都换了 ⇒ HFP 那张续播票作废。
        holds.clearHold()
        update { $0.status = .paused }
        stallWatchdog.reset()
        service.pause()
    }

    /// AirPlay 回到本机 —— 重抢本地会话焦点并接着放。
    ///
    /// 会话激活没变过时 iOS 不重跑非混音仲裁（别人可能还占着喇叭 / 听筒），所以显式重配一次
    /// 再让引擎出声。🔴 只「重配会话 ＋ 续播」，**不**建 primuse 那套配置恢复机（本地没有那条管线）。
    private func reacquireAfterAirPlayReturn() {
        holds.clearHold()
        session.prepareForPlayback()
        update { $0.status = .playing }
        stallWatchdog.reset()
        service.resume()
    }

    /// 蓝牙那条路的结论落地。
    private func applyBluetoothDeferredResume(_ decision: BluetoothDeferredResumeDecision) {
        switch decision {
        case .wait:
            break
        case .discard:
            holds.clearHold()
        case .resume:
            holds.clearHold()
            resumeHeldTrack()
        }
    }

    /// **把压着的那首续起来** —— 「被打断 / 被环境压住」之后恢复出声的**唯一一处实现**。
    ///
    /// 🔴 两个入口共用它（所以由 `resumeAfterBluetoothHFP` **改名** ——
    /// 它的身体里**一句蓝牙的话都没有**）：
    /// - **HFP 结束**（看门狗轮询或 `routeChange` 兑现）⇒ `applyBluetoothDeferredResume`；
    /// - **回到前台核对通过** ⇒ `resumeAfterAppActivationIfSafe`。
    ///
    /// ⚠️ 不照抄成两份：那正是宪法 §三·明令禁止的「同一概念两处各写一遍」——
    /// 将来改一处忘一处，两条路的恢复行为就不一样了。
    ///
    /// ⚠️ 故意**不动队列**：续的是"现在装着的那一首"，不是"往后走一首"。
    private func resumeHeldTrack() {
        guard let track = stateRelay.value.track else { return }
        holds.consumeInterruption()
        // 冷恢复后引擎还没装：按钉住的进度起播（同 `togglePlayPause` 的 `.paused` 分支）。
        if stateRelay.value.engineNeedsPrepare {
            start(track, resumeAt: positionRelay.value)
            return
        }
        session.prepareForPlayback()
        update { $0.status = .playing }
        stallWatchdog.reset()
        service.resume()
    }

    /// **媒体服务重启**（`mediaserverd` 崩了又起）—— 手里那台引擎**连同挂在它上面的节点**全部作废。
    ///
    /// 现象：极罕见，一发生就**彻底没声**且**不自愈**（那条「停」的回调**根本不来** —— 对象已经死了）。
    /// 根因：「**引擎对象被系统作废**」这件事**没有观察点**（现在有了，见 `init` 里那根线）。
    ///
    /// 做两件事：
    /// 1. **丢掉死对象** —— 交给 `PlayerService`（引擎 ＋ 节点一起重造）；
    ///    **不是**对死对象再按一次播放（`stop()` / `play()` 对一具尸体都是空谈）。
    /// 2. **本来在响 / 在装**才重新起播 —— 判据就是下面那个 `isPlaybackActive`。
    ///
    /// 🔴 **为什么"被打断留下的暂停"不顺手续上**：续播 ＝ **抢回音频输出**，而抢的资格只有两个来源 ——
    /// ① **用户刚点了播放**；② **我们本来就持有输出**（在响 / 在装）。两条都收在这个判据里。
    /// 「被打断的暂停」两个都不满足 ⇒ 它的出口是**回前台核对**（`resumeAfterAppActivationIfSafe`，
    /// 那道闸还多一条"别的 App 没在放"）。在这儿顺手把它续上 ＝ **替用户抢**。
    func handleMediaServicesReset() {
        // 顺序不能反：两句都排进引擎那条**串行**队列，先丢、后放（`order` 由队列保证）。
        service.discardEngineAfterMediaServicesReset()
        guard stateRelay.value.isPlaybackActive, let track = stateRelay.value.track else { return }
        // 回到原位置接着放：`start` 自带铺会话 / 发新号（挡死对象的迟到事件）/ 作废两张票。
        start(track, resumeAt: positionRelay.value)
    }

    /// **回到前台，核对一次**：被打断那首是不是还在等着续。
    ///
    /// 根因：「打断结束了」这件事**没有出口** —— 我们（有意）不接 `interruptionNotification`，
    /// 而 SFB 在「结束但没有 `shouldResume`」时**一声不吭**（`AudioPlayer.mm:2702` 那条 `return`）。
    /// 所以借一个**与打断无关的**既有生命周期事件（回到前台）去核对一次；
    /// **不是**去接那条通知，也**不是**"回前台补一下"（"补"这个说法把根因说反了）。
    ///
    /// 判据只有**两项**（另两项由"票的存活性"免费提供），收在
    /// `Decisions/AppActivationResumePolicy.swift`：**票还在** ＋ **别的 App 没在放**。
    ///
    /// ⚠️ 没通过就**什么都不做**：票留着，用户点播放仍然是出口。
    func resumeAfterAppActivationIfSafe() {
        guard case .resume = appActivationResumeDecision(
            isAwaitingInterruptionEnd: holds.isAwaitingInterruptionEnd,
            otherAudioIsPlaying: session.otherAudioIsPlaying
        ) else { return }
        resumeHeldTrack()
    }

    /// 现读一份路由事实、重跑同一条判据，只取蓝牙那一条分支 —— **看门狗每一拍问的就是它**。
    ///
    /// 系统不保证通话档退出时补发 `routeChange`，所以看门狗只能自己现读着问。
    /// ⚠️ **判据不在这儿**：这里只把值凑齐交给 `audioRouteChangeAction`，拿它蓝牙那一条的结论。
    private func currentBluetoothDeferredDecision() -> BluetoothDeferredResumeDecision {
        let action = audioRouteChangeAction(
            facts: session.currentRouteFacts(),
            playbackIsIntended: playbackIsIntended,
            isAwaitingInterruptionEnd: holds.isAwaitingInterruptionEnd,
            isPlaybackActuallyActive: stateRelay.value.isPlaybackActive,
            suspendedTrackID: holds.heldTrackID,
            currentTrackID: stateRelay.value.track?.id
        )
        guard case .bluetoothDeferred(let decision) = action else { return .wait }
        return decision
    }

    // MARK: - 私有

    /// 正在播的那首刚被移出队列（曲库删了它 / 队列页 × 了它）—— 接着放紧挨的下一首；
    /// 没有下一首就停成 idle（播放页因 `!hasTrack` 关掉）。
    ///
    /// ⚠️ 调用前队列已经剔过了：游标停在被删那首的前一格，`advance` 正好落到它原来的下一首。
    private func continueAfterCurrentRemoved() {
        if let id = mutateQueue({ $0.advance(mode: PlayNext.afterRemovalMode) }),
           let next = trackTable[id] {
            start(next)
            return
        }

        // 没有下一首：换号，挡引擎迟到事件；再停引擎、清成 idle。
        tickets.current = tickets.next()
        pendingSeekAfterReady = nil
        positionRelay.accept(0)
        update {
            $0.track = nil
            $0.status = .idle
            $0.duration = 0
            $0.engineNeedsPrepare = false
        }
        service.stop()
    }

    /// 改队列的**唯一入口** —— 改完立刻把新快照推出去。
    ///
    /// 🔴 推快照只在这一处：要是每个动作各自记得推一次，漏一处就是"队列页上那份是旧的"，
    /// 而且不会报错。排下一首（`syncPreload`）同理。
    @discardableResult
    private func mutateQueue<Result>(_ change: (PlayQueue) -> Result) -> Result {
        let result = change(queue)
        queueRelay.accept(makeQueueSnapshot())
        syncPreload()
        return result
    }

    /// 队列页要的那一份 —— **编号拿去表里换成歌**。
    ///
    /// ⚠️ 队列存编号、表存歌，两份在这一处合起来（队列自己不认识表）。
    /// `compactMap` 会丢掉表里没有的编号 —— 那只可能是"歌刚被删、队列还没剔"那一瞬，
    /// 而装配层那条线是**先剔队列、再换表**，所以那个窗口不存在。
    private func makeQueueSnapshot() -> QueueSnapshot {
        QueueSnapshot(
            tracks: queue.trackIDs.compactMap { trackTable[$0] },
            currentIndex: queue.trackIDs.indices.contains(queue.currentIndex) ? queue.currentIndex : nil
        )
    }

    /// 让库里排着的下一首跟"队列 + 状态"一致 —— 只在两个写口（`mutateQueue` / `update`）的末尾调。
    ///
    /// 🔴 不列"哪些动作之后要记得排一次"：队列或状态一变就重算，漏不了；一样就什么都不做。
    /// 判断全在 `Decisions/NextTrackPreloadPolicy.swift`，这儿只照着动引擎、记下说过什么。
    private func syncPreload() {
        // 冷恢复后引擎未装：不许 prepareNext / clearNext。
        guard !stateRelay.value.engineNeedsPrepare else { return }

        let state = stateRelay.value
        let eligibility = canPreloadNext(
            status: state.status,
            loadedTrackID: state.track?.id,
            queueCurrentID: queue.currentID,
            holdsSuccessor: sleep.holdsSuccessor
        )
        let desired = eligibility == .allowed ? queued(queue.peekNext(mode: state.playbackMode)) : nil

        switch preloadChange(desired: desired, armedTrackID: tickets.armed?.trackID) {
        case .keep:
            return
        case .clear:
            service.clearNext()
            tickets.armed = nil
        case .arm(let track):
            armPreload(track)
        case .replace(let track):
            service.clearNext()
            armPreload(track)
        }
    }

    /// 领一张号、让库排上这一首、记下来。
    ///
    /// ⚠️ **号先领再说话**：引擎那通调用与记下来的必须是**同一张**号（分两次领就等于
    /// 记的不是它排的那一首）—— 所以这里不能分成两步。
    private func armPreload(_ track: Track) {
        let ticket = tickets.next()
        service.prepareNext(url: MusicFileStore.resolve(relativePath: track.path), ticket: ticket)
        tickets.arm(trackID: track.id, ticket: ticket)
    }

    /// 睡眠到期、这首还在响 —— 跟按暂停键同一条乐观更新。
    private func pauseForSleep() {
        guard stateRelay.value.status == .playing || stateRelay.value.status == .loading else { return }
        update { $0.status = .paused }
        service.pause()
    }

    /// 睡眠锁着的这首自然结束了（或后继抢跑）。库已经 endOfAudio，必须 `stop` 才不会空转。
    private func stopForSleepHold() {
        update { $0.status = .stopped }
        service.stop()
    }

    // MARK: - Stall（在播但位置不动）

    /// 进度 tick 喂看门狗；它说该重建就重建。设计：`播放错误与卡死恢复设计.md`。
    ///
    /// ⚠️ **时间账不在这儿**（在 `StallWatchdog`）、**判据也不在这儿**（在 `PlaybackStallPolicy`）——
    /// 这里只剩「拿结论去动引擎」。
    private func observeStall(at seconds: TimeInterval) {
        switch stallWatchdog.note(
            seconds: seconds,
            isPlaying: stateRelay.value.status == .playing,
            successorArmed: tickets.armed != nil
        ) {
        case .none:
            break
        case .rebuild(let resumeAt):
            rebuildAfterStall(resumeAt: resumeAt)
        }
    }

    /// 同曲重新 `play` + 等 ready 再 seek。
    ///
    /// ⚠️ 没有当前曲就**不重建**：那一下不算数，`noteRebuildHappened()` 也不调 ——
    /// 冷却窗不从这儿起算，跟「重建没发生过」一样。
    private func rebuildAfterStall(resumeAt: TimeInterval) {
        guard let track = stateRelay.value.track else { return }

        stallWatchdog.noteRebuildHappened()
        pendingSeekAfterReady = resumeAt
        tickets.current = tickets.next()
        update { $0.status = .loading }
        session.prepareForPlayback()
        service.play(
            url: MusicFileStore.resolve(relativePath: track.path),
            ticket: tickets.current,
            pauseAfterStart: resumeAt > 0
        )
    }

    /// 装上一首、开始播 —— **所有"要出声了"的路都走这儿**。
    ///
    /// - Parameter resumeAt: 冷恢复续播点。`0` ⇒ 从头；`>0` ⇒ 进度保持该值，ready 后再 seek。
    ///
    /// ⚠️ 它**不动队列**：队列该走到哪一格是调用方的事（`playNext` / `handleFinished`），
    /// 这里只管"把这一首交给引擎"。
    private func start(_ track: Track, resumeAt: TimeInterval = 0) {
        restoreLifecycle.supersedeForPlaybackIntent()
        // 换歌 ⇒ **两张票一起作废**：要接着放的是**新**这一首，不是被打断 / 被压住的那一首。
        holds.clearAll()
        sleep.noteUserStarted(trackID: track.id)
        tickets.current = tickets.next()
        stallWatchdog.reset()

        // 换歌 / 从头 ⇒ 进度**先**归零，再改状态。
        // 🔴 顺序不能反：装配层是「状态一变就带上当前位置发一份」（`withLatestFrom`），
        // 先归零才能保证那一份带的是新歌的 0，而不是上一首的读数。
        // 冷恢复续播：保持 relay，ready 后再 seek（禁止先刷 0 再跳）。
        let needsResumeSeek = resumeAt > 0
        if needsResumeSeek {
            pendingSeekAfterReady = resumeAt
            positionRelay.accept(resumeAt)
        } else {
            pendingSeekAfterReady = nil
            positionRelay.accept(0)
        }

        // 新的一趟：听时累计从零开始；同一首歌本趟只记一次。
        playCount.beginPlay(of: track.id)

        // 「装的是谁」和「刚点了这一首」是同一件事的两面 ⇒ **一次**写进去。
        // 🔴 状态要**先**落成「装载中」再叫引擎：引擎一被叫起来就会报「在播」，
        // 那一下要是还停在上一次的「播完了」，界面会闪。
        //
        // ⚠️ 用 `update` 而不是造一份新的 `PlayerState` —— `playbackMode` 得**原样留着**，
        // 换歌不该把它重置回默认值。
        update { state in
            state.track = track
            state.status = .loading
            state.duration = 0
            state.engineNeedsPrepare = false
        }

        // 要出声了，先把音频会话铺好（几毫秒，同步）。
        session.prepareForPlayback()

        // 续播必须 pauseAfterStart：库只在未在播时于 decodingStarted 发布可 seek 快照。
        service.play(
            url: MusicFileStore.resolve(relativePath: track.path),
            ticket: tickets.current,
            pauseAfterStart: needsResumeSeek
        )
    }

    /// 在当前这份状态上改一改、推出去 —— 改状态的唯一入口，末尾跟着排下一首（同 `mutateQueue`）。
    private func update(_ mutate: (inout PlayerState) -> Void) {
        var next = stateRelay.value
        mutate(&next)
        stateRelay.accept(next)
        syncPreload()
    }

    // MARK: - 播放存档

    /// 冷恢复：只灌会话态，不动引擎。出处：`播放存档设计.md` §4.3。
    @discardableResult
    private func applyRestoration(
        _ plan: PlaybackSessionRestorationPlan,
        token: UInt64
    ) -> Bool {
        guard restoreLifecycle.permitsApply(token: token) else { return false }

        // 三份顺序里每个编号都得在表里（存档那会儿的歌可能已经不在库了）——
        // 有一条对不上就整次放弃，跟"灌进去之后才发现某首没了"是同一条规矩。
        let allIDs = plan.trackIDs + plan.originalIDs + plan.upNextIDs
        guard allIDs.allSatisfy({ trackTable[$0] != nil }),
              plan.trackIDs.indices.contains(plan.currentIndex),
              let current = trackTable[plan.trackIDs[plan.currentIndex]] else {
            restoreLifecycle.complete(token: token)
            return false
        }

        let durationSec = TimeInterval(current.durationMs ?? 0) / 1000
        let position = playbackSessionResumePosition(
            raw: plan.position,
            duration: durationSec,
            threshold: AppMetrics.playbackSessionMeaningfulResume
        )

        // 禁止走 `setPlaybackMode`：那会重新洗牌。三份顺序原样灌（队列只存编号，直接灌）。
        mutateQueue {
            $0.restore(
                trackIDs: plan.trackIDs,
                originalIDs: plan.originalIDs,
                upNextIDs: plan.upNextIDs,
                currentIndex: plan.currentIndex,
                isShuffled: plan.playbackMode == .shuffle
            )
        }

        pendingSeekAfterReady = nil
        stallWatchdog.reset()
        positionRelay.accept(position)
        update { state in
            state.track = current
            state.status = .paused
            state.duration = durationSec
            state.playbackMode = plan.playbackMode
            state.engineNeedsPrepare = true
        }
        restoreLifecycle.complete(token: token)
        return true
    }

    // ⚠️ 这里**没有 `deinit`**，是有意的：这个类手上已经没有「必须自己摘」的东西。
    // - 路由 / 媒体服务两条观察 ⇒ 挂在 `AudioSessionController` 上，由**它自己的** `deinit` 摘
    //   （`要显式摘`这条规矩由**挂观察的那个人**履行，见那个文件）。
    // - HFP 看门狗 ⇒ 归 `PlaybackHolds`，也是它自己的 `deinit` 里 `cancel`。
    // 🔴 而且 `deinit` 在 Swift 里**永远是非隔离的**：真在这儿摘，就得对上面两个 `@MainActor`
    //    的方法各绕一道 —— 绕法只有「假设在主线程」（可能是假的）和 `nonisolated(unsafe)`（等于放弃检查）。
    //    归属本来就对，不必绕。
}

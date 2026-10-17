import Foundation
import GRDB
import RxSwift
import UIKit

/// 依赖注入容器 —— **全 App 的服务只在这里创建一次**。
///
/// 谁要用服务：由 `AppRouter` 造页面时注入（`AppServices` → `AppRouter` → 页面）。
///
/// 🔴 **页面里不许出现 `XxxManager.shared`** —— 单例的毛病是：`PlayManager.shared`
/// 被引用上百次、`LibraryStore.shared` 同样上百次，于是「看一个页面的代码，
/// 根本不知道它暗中依赖了谁」。
///
/// 🔴 **这里也不用单例**（不做 `static let shared = AppServices()`）：
/// 由 `SceneDelegate` 建一次、持有整个生命周期，要谁给谁。
///
/// 现在有：曲库出口、导入 / 扫描、删歌、设置、播放器、EQ/变速、睡眠定时、歌词。
///
/// ## 线程
///
/// **只在主线程创建和持有**：`SceneDelegate` 装配一次，之后只读字段交给各层。
/// 各服务自己的并发边界写在各自文件头（库 / 播放器 / 导入），这里不另开队列。
@MainActor
final class AppServices {

    /// 数据库连接 —— **归它持有**。
    ///
    /// `LibraryStore` 只是借用（见那边的说明）；连接的生命周期由这里管。
    private let databaseWriter: any DatabaseWriter

    /// 曲库的唯一出口：增删改查 + 实时观察。
    let library: LibraryStore

    /// 导入 / 扫描的入口（「打开文件」/「扫描本地音频」）。
    ///
    /// ⚠️ 它写库**只经过 `library`**（构造时把曲库出口传进去）——
    /// 数据层里除了 `LibraryStore`，别的东西一律不许自己碰数据库。
    let importService: ImportService

    /// 删歌 —— 删文件 + 删库行两步的编排。
    let trackRemover: TrackRemover

    /// 歌单封面 —— 「换一张 / 生成一张」那两条顺序的编排（见 `PlaylistCoverService`）。
    ///
    /// ⚠️ 跟 `trackRemover` 同一角色：都是 `Data` 层里「跨文件与库两边」的编排者，
    /// 由装配层持有。
    let covers: PlaylistCoverService

    /// 全 App 的设置 —— **业务代码里唯一该碰 `UserDefaults` 的地方**。
    let settings: AppSettings

    /// 播放器 —— 「谁在播」的总管。页面和迷你条从它这儿拿状态、发动作。
    ///
    /// ⚠️ 它**不认识曲库**：队列里的歌被删了由装配层（这个类）盯曲库流算好 diff、
    /// 再调它的 `removeTracks(fromQueue:)`。它只管播。
    /// ⚠️ 它**不认识 EQ / 速率**：那是旁边的 `effects`。
    let playManager: PlayManager

    /// EQ + 变速的活状态。锁屏要速率时从这儿读，不进 `PlayManager`。
    let effects: EffectsSession

    /// 睡眠定时。页面订它；到期停播放由总管在 `init` 里接上。
    let sleep: SleepTimerSession

    /// 取词客户端 —— 去酷狗**搜歌 + 搜词 + 下 KRC**。
    ///
    /// 🔴 **这是本项目唯一联网的东西**，也是**第一个 `Data/Lyrics/` 的服务**：
    /// 它无状态、无生命周期，本来"就地 new 一个"也能跑 —— 放这儿的理由只有一条：
    /// 「依赖从 init 传进来」。装配层显式给，
    /// 页面 / ViewModel 里一律不许自己 new。
    let lyricsClient: LyricsSearchClient

    /// 歌词 —— 「当前这首歌的歌词 ＋ 现在唱到第几行」。
    ///
    /// ⚠️ 它**不是**播放页自己造的：歌词是**播放状态的一条派生流**（订 `playManager.state`
    /// 重解析、订 `playManager.position` 算行号），跟"谁在播"同寿。建在这儿 = 换页不用重建、
    /// 一打开播放页就有歌词（别把这份状态焊在 `PlayManager.currentLyricsManager` 里，
    /// 但我们把它拆出来，**生命周期照样跟播放器走**）。
    ///
    /// ⚠️ 它的存在**不依赖播放页**：没人看歌词时它也只是跟着 `state` / `position` 算，
    /// 不算就不算（行号没变不推）。
    let lyricsManager: LyricsManager

    /// 锁屏 / 控制中心 —— 把播放状态翻成系统要的那一份，并接住系统发来的远程命令。
    ///
    /// ⚠️ 它**不订阅任何流**（订阅是装配层的事，见 `init` 末尾那根线）——
    /// 所以它对外只给两个口子：`update(_:)` 和 `clear()`。
    private let nowPlayingCenter: NowPlayingCenter

    /// Intent / 快捷指令的注入桥 —— 由 `AppDelegate` 建好后传进来（系统入口只有它拿得到构造缝）。
    ///
    /// ⚠️ 这里只是**借用**：桥的生命周期归 `AppDelegate`，本容器只负责把它的闭包指到自己的库 / 播放器。
    private let intentBridge: LocalTuneIntentBridge?

    /// 小组件快照的发布者 —— 订播放流、落 App Group、请求 reload。
    ///
    /// 🔴 独立类型（不是 `PlayManager` 的 extension），生命周期跟容器同寿；
    /// 订阅在它自己的 `init` 里接好。
    private let widgetPublisher: WidgetNowPlayingPublisher

    /// 进程「后台窗口」的记账人 —— 播放期间替进程留一张，退到后台不被立刻挂起。
    ///
    /// ⚠️ 它**不认识播放**（谁想借谁就 `increment` / `decrement`）；把「在播」翻成
    /// 「借一张」的那根线接在这里，是因为「播放态」和「进程生命周期」本就分属两层，
    /// 只有装配层同时看得见两边。
    ///
    /// 🔴 小组件命令那条路（`SceneDelegate` → `WidgetCommandRouter`）也要拿**同一个**
    /// 实例去借窗口，所以它对外可见 —— 由装配层传给系统入口，同「系统入口只能靠构造注入」的规矩。
    let backgroundHandler: BackgroundHandler

    /// 订阅的生命 —— 跟这个容器同寿（装配期接的那几根线挂在这儿）。
    private let disposeBag = DisposeBag()

    /// 上一次见到的曲库 id 集合 —— 用来算"哪些歌被删了"。
    /// 第一次订阅时为空，第一次推完才填上，所以首次不会误删。
    private var knownTrackIDs = Set<Track.ID>()

    /// 启动恢复只做一次（第一份 `allTracks`）。
    private var didAttemptSessionRestore = false

    /// 建服务。
    ///
    /// ⚠️ 会**真的打开（没有就新建）数据库文件并跑迁移** —— 这是启动时唯一一件可能失败的
    /// 重活，所以是 `throws`。失败原因包成 `LibraryDatabaseError`，
    /// 带着「为什么失败 + 怎么办」的说法，界面直接拿去显示就行。
    init(intentBridge: LocalTuneIntentBridge?) throws {
        self.intentBridge = intentBridge
        databaseWriter = try LibraryDatabase.open()
        library = try LibraryStore(writer: databaseWriter)
        // 「最爱的歌曲」那一行缺了就补上 —— 它不是用户建的歌单，而是**收藏这件事在列表里的
        // 入口**，所以不能靠"用户自己建一个"，也不能塞在建库那一步（老库升级上来的就没有）。
        // 幂等，每次启动调一次（见 `LibraryStore.ensureFavoritesPlaylist`）。
        try library.ensureFavoritesPlaylist()
        importService = ImportService(store: library)
        trackRemover = TrackRemover(library: library)
        covers = PlaylistCoverService(
            library: library,
            buildCollage: AppArtwork.playlistCollageJPEG
        )
        settings = AppSettings()
        // 取词客户端：无依赖、无状态，就地建（见属性上那条说明）。
        lyricsClient = LyricsSearchClient()
        backgroundHandler = BackgroundHandler(creator: UIApplication.shared)
        let graph = EffectsGraph()
        let playerService = PlayerService(graph: graph)
        let sleepTimer = SleepTimerSession(settings: settings)
        playManager = PlayManager(
            playCount: PlayCountTracker { [library] trackID in
                try library.increasePlayCount(trackID: trackID)
            },
            sleep: sleepTimer,
            service: playerService,
            // ⚠️ 这个必须**显式传**：`AudioSessionController` 是 `@MainActor` 的，
            // 而默认参数表达式在非隔离上下文里算 ⇒ 那边写不了默认值。
            session: AudioSessionController()
        )
        sleep = sleepTimer
        let effectsSession = EffectsSession(settings: settings) { eq, rate in
            playerService.apply(eq: eq, rate: rate)
        }
        playerService.onConnectOutcome = { [weak effectsSession] outcome in
            effectsSession?.noteConnect(outcome)
        }
        effects = effectsSession
        nowPlayingCenter = NowPlayingCenter(
            playManager: playManager,
            library: library,
            lockScreenArtwork: AppArtwork.lockScreenArtwork
        )
        lyricsManager = LyricsManager(playManager: playManager, library: library)
        widgetPublisher = WidgetNowPlayingPublisher(
            playManager: playManager,
            lyricsManager: lyricsManager,
            artworkJPEG: AppArtwork.widgetArtworkJPEG(artworkPath:)
        )
        // 小组件三键的执行口：小组件词汇 → 播放动作的翻译（入口翻译归装配层）。
        // ⚠️ 闭包里用局部量，不抓 `self`（init 里的闭包必须写清捕获语义）。
        let playerForWidget = playManager
        WidgetIntentExecution.handler = { command in
            switch command {
            case .playPause: playerForWidget.togglePlayPause()
            case .next: playerForWidget.playNext()
            case .previous: playerForWidget.playPrevious()
            }
        }

        // Darwin 兜底路的观察：命令从队列取（回桌面标记跟着一起消费）。
        // 闭包里用局部量，不抓 `self`（init 里的闭包必须写清捕获语义）。
        let commandKeeper = backgroundHandler
        WidgetPlaybackCommand.observeCommands { command in
            WidgetCommandRouter.handleDarwinCommand(command, keeper: commandKeeper)
        }

        // 曲库一变 → 做两件事：① 算"哪些歌被删了"、剔队列；② 把「这一行是什么」**整张**换给播放器。
        // 这两根线放在装配层，不让 PlayManager 自己认识库（它只负责播）。
        //
        // 🔴 **第一份**曲库到手时做一次启动恢复：有档就装上暂停；没有才用设置里的播放模式。
        // 顺序不能反成「先 setPlaybackMode 再恢复」—— 那会盖掉快照里的 mode。
        library.allTracks
            .subscribe(onNext: { [weak self] tracks in
                guard let self else { return }

                // ① 先剔队列、再换表 —— 反过来会有那么一瞬"队列里存着表里查不到的编号"。
                let nowIDs = Set(tracks.map(\.id))
                let removed = self.knownTrackIDs.subtracting(nowIDs)
                self.knownTrackIDs = nowIDs
                if !removed.isEmpty {
                    self.playManager.removeTracks(fromQueue: removed)
                }

                // ② 整张表换掉：库里的行一变（歌词被编辑过、元数据改了），
                // 播放器手里那份「这首歌现在是什么样」就跟着新。
                //
                // 🔴 **队列只存编号** ⇒ 这里**没有"通知队列"这一步**，也就不可能漏。
                // 换成"谁变了通知谁"的话，就得记住"队列里那几份也要跟着换"。
                //
                // 🔴 **走"库流"这一处，不靠编辑器回推**：两个编辑入口（「编辑歌词」和曲库那边的
                // 「编辑歌曲信息」）都只管写库，**谁都不用认识播放器**；而"那一行变了"这件事
                // 只有一个出处。刷新当前曲的门闩在 `PlayManager.updateTrackTable` 里。
                //
                // 效果：在编辑歌词页存完，播放页的歌词**当场**跟着变；**切走再回来也还是新的**。
                self.playManager.updateTrackTable(tracks)

                guard !self.didAttemptSessionRestore else { return }
                self.didAttemptSessionRestore = true
                let restored = self.playManager.restoreSessionIfNeeded(availableIDs: nowIDs)
                if !restored {
                    self.playManager.setPlaybackMode(self.settings.resolvedPlaybackMode())
                }
            })
            .disposed(by: disposeBag)

        // 播放模式镜像：真相在 `PlayManager`，这里只是运到 `AppSettings`。
        //
        // ⚠️ 订阅建在上面那次恢复 / 回落 **之后**的推送上才会写盘；
        // 恢复路径直接改 `PlayerState.playbackMode`，也会走到这儿。
        let storedSettings = settings
        playManager.playbackMode
            .subscribe(onNext: { storedSettings.playbackMode = $0 })
            .disposed(by: disposeBag)

        // 播放状态 → 锁屏 / 控制中心。
        //
        // 🔴 **用 `withLatestFrom`、不用 `combineLatest` 去推 `update`**：进度是 10Hz 变的，
        // 每次 tick 都写锁屏 ⇒ 每秒十次跨进程，正是 `播放器设计.md` §7.3 要避免的。
        // 状态变了（换歌 / 播 / 停 / 播完）带上**当前**位置发一份；中间由系统按
        // `playbackRate` 自己走进度条。
        //
        // ⚠️ `PlayManager.start(_:)` 里**先**把进度归零、**再**改状态 ——
        // 所以这儿取到的位置一定是新那一首的 0，不会是上一首的读数。
        playManager.state
            .withLatestFrom(nowPlayingLatest()) { state, latest in
                (
                    state: state,
                    position: latest.position,
                    lines: latest.lines,
                    favoriteIDs: latest.favoriteIDs
                )
            }
            .subscribe(onNext: { [weak self] latest in
                self?.pushNowPlaying(latest)
            })
            .disposed(by: disposeBag)

        // 锁屏标题换行：政策结果变了才再发。用播放时间现算行号（lookahead 0），
        // 不拿 `snapshot.currentIndex`（那是播放页提前过的）。
        //
        // 🔴 `combineLatest` 会跟着 10Hz 进度跑，但 `distinctUntilChanged` 吃掉「同一句」——
        // 真正写出系统的仍是换行 / seek 跨过第一句边界。进度字段用**此刻**的 position。
        Observable.combineLatest(
            playManager.state,
            lyricsManager.snapshot.map(\.lines),
            playManager.position
        )
        .map { state, lines, position in
            NowPlayingLyricsMetadataPolicy.presentation(
                songTitle: state.track?.title ?? "",
                artist: state.track?.artist ?? "",
                lyrics: lines,
                playbackTime: position
            )
        }
        .distinctUntilChanged()
        .withLatestFrom(nowPlayingLatest())
        .subscribe(onNext: { [weak self] latest in
            self?.pushNowPlaying(latest)
        })
        .disposed(by: disposeBag)

        // 只换档时也重发快照：状态没变，但锁屏进度要按新速率走。
        effects.changes
            .map(\.rate)
            .distinctUntilChanged()
            .skip(1)
            .withLatestFrom(nowPlayingLatest())
            .subscribe(onNext: { [weak self] latest in
                self?.pushNowPlaying(latest)
            })
            .disposed(by: disposeBag)

        playManager.seeks
            .withLatestFrom(nowPlayingLatest()) { position, latest in
                (
                    state: latest.state,
                    position: position,
                    lines: latest.lines,
                    favoriteIDs: latest.favoriteIDs
                )
            }
            .subscribe(onNext: { [weak self] latest in
                self?.pushNowPlaying(latest)
            })
            .disposed(by: disposeBag)

        library.favoriteTrackIDs
            .withLatestFrom(nowPlayingLatest()) { ids, latest in
                (
                    state: latest.state,
                    position: latest.position,
                    lines: latest.lines,
                    favoriteIDs: ids
                )
            }
            .subscribe(onNext: { [weak self] latest in
                self?.pushNowPlaying(latest)
            })
            .disposed(by: disposeBag)

        // 播放态进出 → 进程「后台窗口」借 / 还。
        //
        // 🔴 只在 `.playing` 算：`.loading` 那几百毫秒是「还在装」、不是「在放」——
        // 装到一半被挂起没有损失，真放起来被挂起才是损失。
        // `.distinctUntilChanged()` 把「同一种态反复推」吃掉：计数只该在**真的进出**
        // 那一刻动一下；不然 `state` 每推一次（换行 / 收藏变化都会推）就 `decrement` 一次，
        // 计数会被减穿。
        let keeper = backgroundHandler
        playManager.state
            .map { $0.status == .playing }
            .distinctUntilChanged()
            .subscribe(onNext: { isPlaying in
                if isPlaying {
                    keeper.increment()
                } else {
                    keeper.decrement()
                }
            })
            .disposed(by: disposeBag)

        wireIntentBridge()
    }

    /// 把 Intent 桥的闭包指到本容器的库 / 播放器。
    ///
    /// ⚠️ 桥由 `AppDelegate` 建好传进来，理论上不会是 nil —— 系统一定先建 `AppDelegate`、
    /// 再连场景。真取不到就不接：Intent 侧随后会明确回「LocalTune 还没准备好」，**不假装成功**。
    private func wireIntentBridge() {
        guard let bridge = intentBridge else { return }
        let library = self.library
        let playManager = self.playManager
        bridge.bootstrap(
            allTracks: { library.tracksNow },
            allPlaylists: { library.playlistsNow },
            tracksInPlaylist: { try library.tracks(in: $0) },
            lyricsByTrackID: { try library.lyrics(for: $0) },
            playlistByID: { try library.playlist(id: $0) },
            currentSession: {
                MediaPlaySession(
                    currentTrackID: playManager.currentTrack?.id,
                    isPlaybackActive: playManager.stateRelayCurrentIsPlaying
                )
            },
            playQueue: { tracks, start in
                playManager.play(start, in: tracks)
            },
            ensurePlayingCurrent: {
                guard playManager.currentTrack != nil else { return }
                if !playManager.stateRelayCurrentIsPlaying {
                    playManager.togglePlayPause()
                }
            },
            setPlaybackMode: { playManager.setPlaybackMode($0) }
        )
    }

    /// 拼快照要的此刻那一份。只给 `withLatestFrom` 用，不许直接订 —— 里面有 10Hz 进度。
    private func nowPlayingLatest() -> Observable<(
        state: PlayerState,
        position: TimeInterval,
        lines: [LyricsLine],
        favoriteIDs: Set<Track.ID>
    )> {
        Observable.combineLatest(
            playManager.state,
            playManager.position,
            lyricsManager.snapshot.map(\.lines),
            library.favoriteTrackIDs
        ) { (state: $0, position: $1, lines: $2, favoriteIDs: $3) }
    }

    /// 把「放哪首 / 几倍速 / 锁屏文案 / 收藏」拼成一份快照。速率读 Session，文案走政策。
    private func pushNowPlaying(
        _ latest: (
            state: PlayerState,
            position: TimeInterval,
            lines: [LyricsLine],
            favoriteIDs: Set<Track.ID>
        )
    ) {
        guard let track = latest.state.track else {
            nowPlayingCenter.clear()
            return
        }
        let display = NowPlayingLyricsMetadataPolicy.presentation(
            songTitle: track.title,
            artist: track.artist,
            lyrics: latest.lines,
            playbackTime: latest.position
        )
        nowPlayingCenter.update(
            NowPlayingSnapshot(
                playerState: latest.state,
                position: latest.position,
                rate: float(for: effects.rate),
                title: display.title,
                artist: display.artist,
                isFavorite: latest.favoriteIDs.contains(track.id)
            )
        )
    }
}

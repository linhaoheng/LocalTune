import Foundation
import RxRelay
import RxSwift

/// 播放页的**状态与动作** —— 页面只订阅它两条流、把用户动作交给它。
///
/// ## 它不存状态
///
/// 「谁在播、播到哪儿」**只有** `PlayManager`（`PlayerState`）知道。这个类干的是三件事：
/// **订阅**（那两条流）→ **翻译**（把状态翻成"这一页要画的东西"）→ **转发**（把动作交回播放器）。
/// 它自己**没有** `var currentTrack` 这类字段。
///
/// ## 两条流，节奏差一百倍
///
/// - `content` —— **低频**（换歌 / 播停 / 收藏变了 / 播放模式变了）：整页重画用它；
/// - `progress` —— **高频**（10 Hz，外加拖动时每一帧）：**只有进度条那一块**订它。
///
/// 🔴 分开是硬要求：进度混进 `content` 的话，整页每秒要重画十次
/// （`PlayerState` 顶上那段写了原因）。
///
/// ## 线程
///
/// **状态全在主线程**：`PlayManager` 那两条流本来就保证在主线程上推（引擎事件由
/// `PlayerService` 统一回主线程再发），页面动作也是主线程来的。
/// ⇒ 那一个 `drag`（手指拖到哪儿 + 属于哪一首）**不需要锁** —— 没有第二个线程碰它。
///
/// ⚠️ **唯一离开主线程的是背景取色**（`background`）：读盘 + 聚类放在注入的 `paletteScheduler` 上，
/// 算完回主线程才推出来；它不读写这个类的任何状态。
@MainActor
final class NowPlayingViewModel {

    // MARK: - 推给页面的东西

    /// 这一页低频要画的东西。**`Equatable`** ⇒ 内容没变就不重画（白拿的）。
    struct Content: Equatable {

        /// 正在展示的是哪一首；`nil` ＝ 什么都没在放。
        ///
        /// ⚠️ 它是**身份**、不是展示内容（页面上不画它）—— 收藏要用它，
        /// 而"当前是哪一首"这份状态**不在这个类里**，只能从这儿读回来
        /// （另存一份就是"同一个事实两个人记着"）。
        let trackID: Track.ID?

        let title: String

        /// **艺人** —— `track.artist` 原样，**不做兜底**（空就空着）。
        ///
        /// 🔴 播放页这一行**只显示艺人**（原先跟列表一样显示「艺人 - 专辑」）。
        /// 「空 ⇒ 未知艺人」那条兜底**不跟** —— 跟歌单封面流一致（空就空着）。
        /// ⚠️ 列表行那一行**仍是**「艺人 - 专辑」（`Track.artistAlbumLine`）—— 两处**故意不一样**：
        /// 列表要辨识（哪一首），播放页要聚焦（谁唱的）。别"顺手"改回去。
        let artist: String

        let artworkPath: String?

        /// 音质那一条：**说明文字 ＋ 档位徽章**；标签里什么都没读到就是 `nil`。
        ///
        /// ⚠️ `nil` 只表示**这一条没有内容** —— 那一块**照样占位**（封面不上移），
        /// 见 `NowPlayingQualityView`。也包含"开关关着"那一种（见 `content(from:)`）。
        let quality: AudioQualityLine?

        /// 进度条的总长（秒）。见 `resolvedPlaybackDuration`。
        let duration: TimeInterval

        /// 播放/暂停键画哪一个 —— 用 `isPlaybackActive`（**在装也算在播**），
        /// 跟迷你条同一套：不然换歌那几百毫秒会先闪一下「播放」再跳回「暂停」。
        let isPlaybackActive: Bool

        let playbackMode: PlaybackMode

        let isFavorite: Bool

        /// 封面一侧能切时的预览。`nil` ＝ 这一侧没有邻居，松手回弹。
        ///
        /// `artworkPath` 仍可以是 `nil`（有歌、没图）—— 跟「没有邻居」不是一回事。
        struct CoverNeighbor: Equatable {
            let artworkPath: String?
        }

        /// 右滑预览（上一首）；没有就不提交上一首。
        let previousCover: CoverNeighbor?

        /// 左滑预览（下一首）；没有就不提交下一首。
        let nextCover: CoverNeighbor?

        /// 有没有歌 —— **只作门闩/关页判据**，不是可停留的空页 UI。
        ///
        /// 无歌：`AppRouter` 不 present；页开着变无歌 ⇒ VC dismiss，**不上屏**画空态。
        var hasTrack: Bool { trackID != nil }

        /// 哨兵：VM 初值 / `content(from:)` 在 `track == nil` 时。
        ///
        /// 🔴 **不是可停留界面** —— 不许靠点子条进到这一态；页内到了只触发 dismiss。
        /// 删当前曲但队列还有歌 → `removeTracks` 切下一首，**到不了** idle。
        /// 标题与迷你条共用 `notPlayingTitle`（条子仍显示「未在播放」，只是点不开页）。
        static func idle(playbackMode: PlaybackMode = .sequential) -> Content {
            Content(
                trackID: nil,
                title: MiniPlayerBar.Content.notPlayingTitle,
                artist: "",
                artworkPath: nil,
                quality: nil,
                duration: 0,
                isPlaybackActive: false,
                playbackMode: playbackMode,
                isFavorite: false,
                previousCover: nil,
                nextCover: nil
            )
        }

        static let idle = Content.idle()
    }

    /// 「谁在播 / 什么态」—— 整页订它。
    let content: Observable<Content>

    /// 这一刻的 `Content` —— 切循环档后 HUD 同步读它（唯一真相，不另拼返回值）。
    var contentNow: Content { contentRelay.value }

    /// 「播到哪儿了」—— **只有进度条那一块**订它。
    ///
    /// 🔴 它推的是**这一刻该画在哪儿**（`elapsed`），不是引擎的原始读数：手指在拖的时候推的是
    /// 手指的位置（规则见 `ScrubDisplay`）。
    ///
    /// ⚠️ 顺手把**总长**一起带上：进度条要画比例就得同时知道"到哪儿了"和"一共多长"，
    /// 而总长在 `Content` 里。不带的话，页面就得自己存一份总长再去拼 ——
    /// 那就是"界面自己记着一份状态"（铁律第二节第一条）。
    let progress: Observable<Timeline>

    /// 这一刻的 `Timeline` —— 给**不订流、只问一次**的调用方（同 `contentNow`）。
    ///
    /// 现在只有一处：播放页「更多 → 分享歌词」，用它定位"当前正唱的那句"作海报的默认选段。
    var progressNow: Timeline { progressRelay.value }

    /// 背景该画成什么颜色 —— 跟着**封面文件**走（规则见 `backdrop(forArtworkPaths:palette:on:)`）。
    ///
    /// ⚠️ 单开一条、不塞进 `Content`：它是**异步**算出来的（读盘 + 聚类），
    /// 塞进去的话换歌那一刻 `Content` 就得先推一份"颜色还没算好"的半成品。
    let background: Observable<BackdropGradient>

    /// 「这首歌的歌词 ＋ 现在唱到第几行」—— 竖屏歌词列表订它。
    ///
    /// ⚠️ 这一条**不是这一页算的**，是转发 `LyricsManager` 的（它订 `PlayManager.state`
    /// 重解析、订 `.position` 算行号）。这一页只是把同一个"播放时间"另一条消费路径
    /// 摆到界面上 —— 跟 `background` 一样，**不自造一份状态**。
    ///
    /// ⚠️ 也**不塞进 `Content`**：行号跟着 10Hz 的进度跳，混进低频内容里就等于整页每秒重画十次
    /// （`Content` 的 `Equatable` 那点好处也白搭）。
    ///
    /// 🔴 **它跟 `progress` 是一条时间轴的两个消费者**（进度条看"到哪一秒了"、歌词看"到第几句了"），
    /// 所以两条都从 `PlayManager.position` 派生 —— 不许再引第三条时间来源（三通道打架，
    /// `播放页歌词.md` §D.1 第 5 条）。
    let lyrics: Observable<LyricsManager.Snapshot>

    /// 「**原样的**播放时间」—— 只有逐字卡拉OK（4d）订它。
    ///
    /// 🔴 它就是 `PlayManager.position` **原封不动**转发出来的那一条，**不是** `progress`：
    /// `progress` 推的是"进度条这一刻该画在哪儿"（手指在拖的时候是手指的位置），
    /// 而逐字要的是**引擎真的播到哪儿**（跟唱的位置不能跟着手指跑）。
    ///
    /// ⚠️ 也**不扩 `LyricsManager` 的职责**：它明说做两件事（行表、行号），
    /// 逐字要的那条时间流从这儿出。
    ///
    /// ⚠️ 更**不 `distinctUntilChanged`** —— 逐字要的就是不去重的时间
    /// （口径同 `PlayManager.position` 那条流本身）。
    let karaokeTime: Observable<TimeInterval>

    /// 要跟用户说的一句话（收藏没存上）。
    ///
    /// 单开一条流、不塞进 `Content`：它是**一次性的事**，不是"这一页现在长什么样"
    /// —— 塞进 `Content` 就得在状态里存一句展示文字，而"内容没变就不重画"那条也就废了。
    let notice: Observable<Notice>

    /// 进度条要的东西：**这一刻画在哪儿** + **一共多长**。
    ///
    /// ⚠️ 名字**不叫 `Progress`**：`Foundation` 里就有一个 `Progress` 类，
    /// 同一个文件里两个同名类型，读的人（和自动补全）都会问你到底指哪个。
    struct Timeline: Equatable {
        let elapsed: TimeInterval
        let duration: TimeInterval

        static let idle = Timeline(elapsed: 0, duration: 0)
    }

    /// 要跟用户说的一句话 + 这句话的**性质**。
    ///
    /// ⚠️ 性质直接复用 `HUD.Style`，不自造一个同形状的枚举：自造的话页面里就要写一层映射，
    /// 而映射就是"同一件事两处记着"。
    struct Notice: Equatable {
        let text: String
        let style: HUD.Style
    }

    // MARK: - 依赖

    private let playManager: PlayManager
    private let library: LibraryStore

    /// 偏好设置 —— 这一页只用到**音质显示开关**那一条。
    ///
    /// ⚠️ 开关的真相在 `AppSettings`（它还要管列表行那一小枚），这一页**不自己存一份**
    private let settings: AppSettings

    /// 删当前曲 —— 只走 `TrackRemover`，不直接碰库行。
    private let trackRemover: TrackRemover

    // MARK: - 内置状态

    private let contentRelay = BehaviorRelay<Content>(value: .idle)
    private let progressRelay = BehaviorRelay<Timeline>(value: .idle)
    private let noticeRelay = PublishRelay<Notice>()
    private let disposeBag = DisposeBag()

    /// 手指拖到了哪儿（秒）＋ **这次拖动属于哪一首**；`nil` ＝ 没在拖。
    /// **只在主线程读写**（见类型顶上「线程」）。
    ///
    /// 🔴 **为什么要连曲目 id 一起记**：拖动是**属于某一首**的 —— 手还按在屏幕上、歌已经换成
    /// 下一首时，上一首那个秒数对新歌毫无意义（拿它去 `seek` 就是把新歌跳到不相干的秒数上）。
    /// 带上 id 之后，`ScrubDisplay` 一比对就**自动作废**，不再需要"换歌时去清一下这个字段"
    /// 那条订阅 —— 那样正确性会挂在**订阅顺序**上：清晚一步，就会先按旧手指位置推一帧出去。
    private var drag: (trackID: Track.ID?, position: TimeInterval)?

    /// - Parameters:
    ///   - artworkPalette: 「这个封面文件取出来是哪三个色」—— 装配层给（`AppArtwork.palette`），
    ///     页面不认识封面存在哪。取不出来给 `nil`。⚠️ 会在 `paletteScheduler` 上被调用，**不许碰主线程的东西**。
    ///   - paletteScheduler: 取色在哪条线程上跑（装配层给一条后台的）。
    ///   - lyricsManager: 歌词那条流**不是这里造的** —— 它是播放状态的一条派生流，
    ///     由装配层建一次、跟播放器同寿（`AppServices`）。⚠️ 这里**不存它**：
    ///     存了就等于"这个页面在管歌词的生命周期"，而那一页关上时歌还在放、歌词还得在。
    init(
        playManager: PlayManager,
        library: LibraryStore,
        settings: AppSettings,
        trackRemover: TrackRemover,
        lyricsManager: LyricsManager,
        artworkPalette: @escaping (String?) -> ArtworkPalette?,
        paletteScheduler: SchedulerType
    ) {
        self.playManager = playManager
        self.library = library
        self.settings = settings
        self.trackRemover = trackRemover

        content = contentRelay.asObservable()
        progress = progressRelay.asObservable()
        notice = noticeRelay.asObservable()
        lyrics = lyricsManager.snapshot
        karaokeTime = playManager.position
        background = Self.backdrop(
            forArtworkPaths: content.map(\.artworkPath),
            palette: artworkPalette,
            on: paletteScheduler
        )

        // 「谁在播」＋「哪些歌被收藏了」＋「音质开不开」→ 这一页要画的东西。
        // ⚠️ 用 `combineLatest` 而不是各订各的：收藏一变、换歌、开关一翻，都要**整份重算** ——
        // 分几条流下去，页面就得自己记"这几件事谁后到的"。
        //
        // 🔴 **开关也是一份来源**：关掉的那一刻音质条就该空掉。让页面自己去看那个开关的话，
        // "有没有音质信息"就有两个出处了（`Content.quality` 一个、开关一个）。
        Observable.combineLatest(
            playManager.state,
            library.favoriteTrackIDs,
            settings.showAudioQualityChanges
        ) { [playManager] state, favorites, showQuality in
            Self.content(
                from: state,
                favorites: favorites,
                showQuality: showQuality,
                previous: playManager.peekPreviousTrack(),
                next: playManager.peekNextTrack()
            )
        }
        .distinctUntilChanged()
        .subscribe(onNext: { [weak self] content in self?.contentRelay.accept(content) })
        .disposed(by: disposeBag)

        // 引擎的进度读数 ＋ 这一刻的样子 → 进度条该画什么。
        //
        // 🔴 **拖动中不采纳引擎读数**（`ScrubDisplay`）—— 不拦的话 10 Hz 的读数会把滑块
        // 从手指底下拽回去。
        // ⚠️ 两条一起合、不是只订 `position`：**总长在 `Content` 里**，
        // 只订 position 的话，换歌（总长变了）要等到下一次 tick 才更新 ——
        // 而暂停时压根没有 tick，那一份总长会一直停在上一首。
        Observable<Timeline>.combineLatest(content, playManager.position) { [weak self] snapshot, engine in
            Timeline(
                elapsed: ScrubDisplay.position(
                    engine: engine, drag: self?.drag, trackID: snapshot.trackID
                ),
                duration: snapshot.duration
            )
        }
        .subscribe(onNext: { [weak self] progress in
            self?.progressRelay.accept(progress)
        })
        .disposed(by: disposeBag)

        // 「刚才那一首为什么没放成」→ 一句人话，走 `notice` → HUD。
        //
        // 🔴 标题得从 `content` 里读（`failureReason` 只带**值**）。用 `withLatestFrom`
        // 取**失败那一瞬间**的内容 —— 失败原因和"哪一首"本来就该是同一刻的，两条流各订各的
        // 会读到半新半旧。
        playManager.failureReason
            .withLatestFrom(content) { reason, snapshot in
                Self.failureNotice(reason: reason, title: snapshot.title)
            }
            .subscribe(onNext: { [weak self] notice in self?.noticeRelay.accept(notice) })
            .disposed(by: disposeBag)

        // 🔴 **"换歌 ⇒ 这次拖动作废"不在这儿** —— 它是 `ScrubDisplay` 比对曲目 id **算出来**的
        // （迟到 / 作废的事件必须能被丢掉，铁律第 20 条）。曾经这里挂着一条"换歌就把
        // `dragPosition` 清掉"的订阅 —— 那没用：它**排在进度那条流后面**，换歌那一瞬
        // 已经先按旧手指位置推了一帧出去；而且它一清，也没人再补推一次。
    }

    // MARK: - 动作（页面把用户动作转到这儿）

    /// 播放 / 暂停 —— 走播放器那一个口子（页面不自己判"现在该播还是该停"）。
    func togglePlayPause() {
        playManager.togglePlayPause()
    }

    func playNext() {
        playManager.playNext()
    }

    func playPrevious() {
        playManager.playPrevious()
    }

    /// 播放模式键转一格。下一档见 `nextPlaybackMode`；HUD 读切完后的 `contentNow`。
    func cyclePlaybackMode() {
        playManager.setPlaybackMode(nextPlaybackMode(contentRelay.value.playbackMode))
    }

    /// 收藏 / 取消收藏**当前这一首**。
    func toggleFavorite() {
        guard let trackID = contentRelay.value.trackID else { return }
        do {
            try library.setFavorite(!contentRelay.value.isFavorite, trackID: trackID)
        } catch {
            // 铁律第 9 条：失败路径要给用户一句人话 —— 收藏没写进去不能静默。
            noticeRelay.accept(Notice(text: "收藏没存上，稍后再试", style: .error))
        }
    }

    /// 从曲库删掉**当前这一首**。
    ///
    /// ⚠️ 只调 `TrackRemover`；接下一首 / 关页由库变 → `PlayManager.removeTracks` 那条链做，
    /// 成功后**不要**在页面里手写 dismiss。
    ///
    /// - Throws: 写库失败 —— 页面弹「删除失败」。
    func deleteCurrent(deleteFiles: Bool) throws {
        guard let trackID = contentRelay.value.trackID else { return }
        try trackRemover.remove(trackIDs: [trackID], deleteFiles: deleteFiles)
    }

    // MARK: - 音质显示开关

    /// 开关现在开着没有 —— 页面拿它画「更多」菜单里那个勾。
    ///
    /// ⚠️ 页面**同步读**它（建菜单那一刻要值），所以是个属性、不是流。
    /// 菜单用 `UIDeferredMenuElement.uncached` 展开时现读，不必再订变更流重建菜单。
    var showAudioQuality: Bool { settings.showAudioQuality }

    /// 音质显示开关翻一格。
    ///
    /// ⚠️ 只写设置，**不自己去改界面**：两边（这一页的音质条、列表行那一小枚）
    /// 都是**订着这条设置**自己重画的 —— 在这儿顺手改一处，就变成"一处设置、两处实现"。
    func toggleAudioQualityDisplay() {
        settings.showAudioQuality.toggle()
    }

    // MARK: - 歌词开关 / 点行跳转

    /// 播放页现在要不要显示歌词（竖屏是**封面与歌词二选一**）。
    ///
    /// ⚠️ 真相在 `AppSettings.lyricsVisible`（跨次启动要记住），这一页**不自己存一份** ——
    /// 页面拿它摆初始状态、点引用键时取反，跟音质那个开关同一个套路。
    var lyricsVisible: Bool { settings.lyricsVisible }

    /// 记下歌词开关的新状态。
    ///
    /// ⚠️ 只写设置，**不自己去改界面**：封面 ↔ 歌词的显隐是纯界面的事，这一页自己做；
    /// 设置只负责"下次进来还是这样"。
    func setLyricsVisible(_ visible: Bool) {
        settings.lyricsVisible = visible
    }

    /// 歌词现在长什么样（字号 ＋ 对齐）—— 页面拿它摆初始状态、设置面板拿它当起点。
    ///
    /// ⚠️ 真相在 `AppSettings.lyricsAppearance`，这一页**不自己存一份**（同 `lyricsVisible`）。
    var lyricsAppearance: LyricsAppearance { settings.lyricsAppearance }

    /// 记下歌词外观的新一份 —— 设置面板拖了滑杆 / 换了对齐时调。
    ///
    /// ⚠️ 只写设置，**不自己去改界面**：把新值摆到歌词列表上是页面的事（面板回调里页面顺手做）。
    /// 在这儿顺手改一处，就变成"一处设置、两处实现"—— 跟音质开关那条同一个理由。
    func setLyricsAppearance(_ appearance: LyricsAppearance) {
        settings.lyricsAppearance = appearance
    }

    /// 这首歌有没有歌词 —— 「更多 → 分享歌词」那一项据此置灰（没词就没有海报可做）。
    ///
    /// ⚠️ **每次问都现读一次库**（展开菜单那一刻一次），**不留缓存**：它是"这一首歌"的一个事实，
    /// 缓存下来就要跟着"编辑歌词存盘 / 换歌 / 删歌"一串事更新，而这些东西本来就有自己的流。
    /// 留一份记着 = 多一处会走散的地方。
    ///
    /// 🔴 取哪一份歌词仍然只有 `LyricsSourcePolicy` 一处判断（`customLyrics` 非空优先）。
    var hasLyrics: Bool {
        guard let trackID = contentRelay.value.trackID,
              // 敢吞 `try?` 这一下：歌刚被删掉就读不出来，那时该当"没有歌词"——
              // 菜单项置灰即可，不必为一次下拉菜单弹个错。
              let track = try? library.track(id: trackID) else { return false }
        // 内嵌歌词住在侧表 —— 跟 `track` 分开取。
        return LyricsSourcePolicy.text(for: track, lyrics: try? library.lyrics(for: trackID)) != nil
    }

    /// 跳到某一秒 —— 点歌词里某一行时用。
    ///
    /// ⚠️ 跟 `endScrub(at:)` 分开写：那一条还要丢掉"手指在拖"这个标记，这是**没有拖动**的跳转。
    func seek(to position: TimeInterval) {
        playManager.seek(to: position)
    }

    // MARK: - 拖动进度条

    /// 手指按下：**从这一刻起引擎读数不算数**。
    ///
    /// ⚠️ 要带上按下那一刻的位置：拖动是相对的，起点就是按下时滑杆的值；
    /// 记下它，按住不动时页面显示的也是这个值，而不是继续往前走的引擎读数。
    func beginScrub(at position: TimeInterval) {
        drag = (contentRelay.value.trackID, position)
        progressRelay.accept(scrubProgress(at: position))
    }

    /// 手指还在拖：只动界面（滑块 + 左边那个时间）。
    ///
    /// ⚠️ 这里**每次都重记一遍曲目 id**：拖动途中歌换了，手指再一动，这次拖动就算**新歌**的了
    /// （滑块这会儿画的本来就是新歌的进度）。
    func updateScrub(to position: TimeInterval) {
        drag = (contentRelay.value.trackID, position)
        progressRelay.accept(scrubProgress(at: position))
    }

    /// 手指抬起：**这时候才真的跳**。
    ///
    /// 🔴 拖动过程中每帧都跳要不停让解码器定位，会卡；松手跳一次是通用做法。
    /// ⚠️ 先丢掉"在拖"这个标记、再让 `PlayManager` 改进度 —— 顺序反了的话，
    /// 那次乐观更新会被下一次引擎读数（它按老位置算）判定成"拖动中"。
    func endScrub(at position: TimeInterval) {
        drag = nil
        playManager.seek(to: position)
    }

    // MARK: - 翻译（纯逻辑，不碰界面、不带引擎也能跑）

    /// 拖动中要推的那一份 —— 位置是手指的，**总长照旧从当前内容里取**
    ///（"总长从哪来"只该有一个出处）。
    private func scrubProgress(at position: TimeInterval) -> Timeline {
        Timeline(elapsed: position, duration: contentRelay.value.duration)
    }

    /// `PlayerState` ＋ 收藏集合 ＋ 音质开关 ＋ 两侧 peek → 这一页要画的东西。
    ///
    /// - Parameter showQuality: 音质显示开关开着没有。**关着就当成"这首歌没有音质信息"**
    ///   给出去（`quality = nil`）—— 那一块于是只留空行（高度照旧，见 `NowPlayingQualityView`）。
    ///   判断只在这一处做，页面不认识那个开关。
    /// - Parameters previous / next: 跟 `playPrevious` / `playNext` **同一份 peek**，
    ///   翻成封面预览。另写一份 `adjacentTrack` 看不到插队。
    private static func content(
        from state: PlayerState,
        favorites: Set<Track.ID>,
        showQuality: Bool,
        previous: Track?,
        next: Track?
    ) -> Content {
        guard let track = state.track else {
            // 没歌 ≠ 模式重置：仍带上 `state.playbackMode`，与 `idle` 同一构造口。
            return .idle(playbackMode: state.playbackMode)
        }
        return Content(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            artworkPath: track.artworkPath,
            quality: showQuality ? track.audioQualityLine : nil,
            duration: resolvedPlaybackDuration(engine: state.duration, library: track.durationMs),
            isPlaybackActive: state.isPlaybackActive,
            playbackMode: state.playbackMode,
            isFavorite: favorites.contains(track.id),
            previousCover: coverNeighbor(peeked: previous),
            nextCover: coverNeighbor(peeked: next)
        )
    }

    /// 一次播放失败 → 播放页要说的那一句话。
    ///
    /// 🔴 **句子的尾巴留在这儿、不放进 `PlaybackError+Display`**：跳过还是停机取决于
    /// **执行结果**（跳没跳成），短词那一层不知道。
    ///
    /// ⚠️ `engineFailed` 是停机不跳 ⇒ 尾巴是「已停止」、且**不挂歌名**（它说的不是"哪一首"，
    /// 是"播放器坏了"）。
    private static func failureNotice(reason: PlaybackError, title: String) -> Notice {
        switch reason {
        case .fileMissing, .unsupportedFormat:
            return Notice(text: "\(title)：\(reason.displayText)，已跳过", style: .error)
        case .engineFailed:
            return Notice(text: "\(reason.displayText)，已停止", style: .error)
        }
    }

    /// peek → 封面这一侧有没有预览。跟迷你条同一条 `queueNeighbor`，不许封面自己再判一遍。
    private static func coverNeighbor(peeked: Track?) -> Content.CoverNeighbor? {
        switch queueNeighbor(peeked: peeked) {
        case .available(let track):
            return Content.CoverNeighbor(artworkPath: track.artworkPath)
        case .unavailable:
            return nil
        }
    }

    /// 封面文件一路变 → 背景一路变。三条规矩，全在这条流的形状里：
    ///
    /// 1. **同一个封面文件不重算** —— `distinctUntilChanged`。比的是文件名，不是图片对象：
    ///    比 `UIImage` 是不是同一个（`!==`）的话，缓存一淘汰同一张封面就换了个对象、白算一遍；
    ///    收藏、播停、换模式也会让 `Content` 再推一次，文件名没变就到不了取色。
    /// 2. **只认最新那一次** —— `flatMapLatest`：新文件名一来，上一次还没算完的那份**连同它回主线程的那一跳**
    ///    一起作废（`observe(on:)` 写在里面）。扔到并发队列上算、回来不对号，
    ///    连切几首时先发的可能后到，把背景刷回上上首。
    /// 3. **取不出色就用兜底那一份** —— 没封面、读不出像素都走 `BackdropGradient.fallback`，跟视图初始画的是同一份。
    private static func backdrop(
        forArtworkPaths artworkPaths: Observable<String?>,
        palette: @escaping (String?) -> ArtworkPalette?,
        on scheduler: SchedulerType
    ) -> Observable<BackdropGradient> {
        artworkPaths
            .distinctUntilChanged()
            .flatMapLatest { artworkPath in
                Observable<ArtworkPalette?>.deferred { .just(palette(artworkPath)) }
                    .subscribe(on: scheduler)
                    .map { $0.map(BackdropGradient.init(palette:)) ?? .fallback }
                    .observe(on: MainScheduler.instance)
            }
    }
}

/// 「进度条这一刻该画在哪儿」—— **纯函数**：吃三个值、吐一个值，不带引擎也能跑。
///
/// 🔴 规则两句话：
/// 1. **手指在拖的时候，引擎读数一律不算数** —— 不拦的话，10 Hz 的引擎读数会在用户拖动时
///    不停把滑块拽回去，表现就是"拖不动"；
/// 2. **那次拖动只对它开始那一首算数** —— 歌一换，引擎读数立刻接管（见下）。
///
/// ⚠️ **它留在页面侧、不进 `Playback/Decisions/`**：「手指在拖」是**界面**的事，
/// 播放层不该认识它 —— 放过去就是让播放层依赖界面概念。
private enum ScrubDisplay {

    /// - Parameters:
    ///   - engine: 引擎刚报的读数。
    ///   - drag: 手指拖到哪儿 ＋ **那次拖动属于哪一首**；`nil` ＝ 没在拖。
    ///   - trackID: **现在**装的是哪一首。
    static func position(
        engine: TimeInterval,
        drag: (trackID: Track.ID?, position: TimeInterval)?,
        trackID: Track.ID?
    ) -> TimeInterval {
        // 🔴 **曲目对不上 ⇒ 这次拖动不算数**（手还按在屏幕上、歌已经换了一首）。
        // 这一条替代了原来"换歌时去清 `dragPosition`"那条订阅 —— 那是靠**订阅顺序**兜的：
        // 清晚一步就先按旧手指位置推了一帧出去，而且清完也没人补推。
        guard let drag, drag.trackID == trackID else { return engine }
        return drag.position
    }
}

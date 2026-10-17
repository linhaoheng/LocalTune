import CoreGraphics
import Foundation
import RxRelay
import RxSwift

/// 曲库页的**状态**。
///
/// 输入 = 用户动作（换排序、删一首歌）；输出 = 一份**可以直接渲染的快照**。
/// 页面拿到快照就画，自己不再做任何判断。
///
/// 🔴 它不持有 ViewController，也不知道界面长什么样 —— 所以这个文件里不出现任何界面类型。
///
/// ## 线程
///
/// **全在主线程**：库推来的那一份走 `LibraryStore` 的观察回调（那些流用 `.async(onQueue: .main)`
/// 启动），播放器那两条流也在主线程（见 `PlayManager` 顶上那段），页面动作本来就是主线程来的。
/// ⇒ 下面那几个 `BehaviorRelay` 和 `latestTracks` **都不需要锁** —— 没有第二个线程碰它们。
@MainActor
final class SongsViewModel {

    /// 界面需要的内容都在这里。
    struct Snapshot: Equatable {
        var rows: [SongRow]

        /// 这一列的歌本身 —— **顺序和 `rows` 一模一样**。
        ///
        /// ⚠️ 为什么要带上它：点一行时要把**用户当时看到的那一列**交给播放器当队列
        /// （播完接着放下面的），而 `SongRow` 只是展示投影、没有路径。
        /// 让页面拿 id 回来再查一遍的话，"当时看到的那一列"就散了 ——
        /// 排序和搜索是怎么算的，页面根本不知道。
        var tracks: [Track]

        /// 要不要按歌名首字母分段 —— 只有「按标题排序、且没在搜索」才开。
        ///
        /// ⚠️ 这里只回答**该不该分组**，「怎么分」是页面的事：
        /// 分段要用的系统工具只能在界面线程上用（见 `SongSections` 顶上那段）。
        var shouldGroup: Bool

        /// 正在搜、但一条都没搜到 —— 页面据此弹一次「未找到相关歌曲」。
        ///
        /// ⚠️ 它是**状态**，不是事件：页面自己去认「从 false 翻成 true 的那一刻」。
        /// ViewModel 不该替界面决定"什么时候弹"。
        var foundNothing: Bool

        /// 当前列表加起来一共多长时间（毫秒）—— 底部那行统计用。
        ///
        /// ⚠️ **先把毫秒全加起来、最后才转成秒**。逐首"先转秒再累加"每首都会截掉一点，
        /// 几百首累起来就看得出来了；毫秒本来就是整数，加完只转一次。
        /// 读不出时长的那些按 0 算 —— 总时长会偏小，这一点都一样。
        var totalDurationMs: Int

        /// 现在是不是在搜。
        ///
        /// ⚠️ 为什么要单独给页面这个信息：**搜索结果为空 ≠ 曲库是空的**。
        /// 搜没搜到，弹一句「未找到相关歌曲」就够了；这时候要是摆出
        /// 「您的音乐库中没有歌曲」，那是**假话** —— 库里明明有歌，只是没搜着。
        var isSearching: Bool

        /// 曲库里有多少首歌的**文件不在本机** —— 顶部那条横幅用。
        ///
        /// ⚠️ 数的是**整个曲库**，不是当前这一列：横幅说的是"库里有 N 首找不到文件"，
        /// 不该被搜索框改变（搜了「周杰伦」，横幅不能变成"1 首找不到"）。
        var missingCount: Int

        /// 要不要在表格顶上出那条横幅。
        ///
        /// 🔴 **判据只此一处**（`LibraryReconcile.looksLikeWholeLibraryMissing`）——
        /// 页面拿到的是一个结论，不再自己比阈值。
        var showsMissingBanner: Bool
    }

    /// 列表内容：库一变、排序一变、搜索词一变，就推一份新的。
    let snapshot: Observable<Snapshot>

    /// 排序状态（字段 + 升 / 降）—— 页面订阅它来**重建排序菜单**。
    ///
    /// ⚠️ 为什么要有这个出口：`UIBarButtonItem` 的菜单**建好之后不会自己刷新**，
    /// 打勾是"建的那一刻"定死的。所以页面得知道排序变了，然后重建菜单。
    let sortState: Observable<(SongSortMode, SortDirection)>

    /// 曲库出错（读不出来）—— 页面订阅它、**弹一次提示**。
    ///
    /// ⚠️ 为什么从这儿转一手、不让页面直接订阅 `LibraryStore`：数据流是
    /// `Store → ViewModel → ViewController`，**页面不认识 Store**。
    ///
    /// ⚠️ 错误**不会自己恢复**：观察断了就是断了（`LibraryStore` 顶上写了这件事）——
    /// 收到就该提示用户，别等下一次更新（不会有下一次）。
    let errors: Observable<Error>

    /// 「谁在播、出没出声」—— 列表行蓝字 / 竖杠用。
    ///
    /// 🔴 **唯一出处仍是 `PlayerState`**：这里只做投影，不另存一份「当前曲」。
    /// 页面订这条去刷可见行；点行要不要开播放页也问瞬时镜像（见 `handleRowTap`）。
    let playbackChrome: Observable<SongPlaybackChrome>

    /// 当前按什么排 —— 排序菜单读它来打勾。
    private let sortModeRelay: BehaviorRelay<SongSortMode>
    private let sortDirectionRelay: BehaviorRelay<SortDirection>

    /// 搜索 —— 搜索框里敲的字进去，**命中的那些歌**出来（防抖 ＋ 算在别的线程上）。
    ///
    /// 🔴 **"哪几首"和"在不在搜"同源**（都从这份 `Result` 上读）—— 两者要是分开走，
    /// 就会出现"框里写着 A、列表按 B 筛"那一拍（见 `LibrarySearch` 顶上那段）。
    private let search: LibrarySearch

    /// 曲库 —— 点一行播放时要按 id 取完整的一首（`SongRow` 只是展示投影，没有路径）。
    private let library: LibraryStore

    /// 播放器 —— 点一行"播这一首"由这里落地。
    ///
    /// 🔴 **在 VM 手里、不在页面手里**：点歌这个动作要"往上走"到 VM
    /// 等队列来了，"播这首 + 把它后面的排进队列"
    /// 这个判断也落在这里；页面只负责说"用户点了哪一行"，不认识播放器、不直接调它。
    private let playManager: PlayManager

    /// 排序偏好存哪儿 —— 只在这里用。
    private let settings: AppSettings

    /// 删歌 —— 页面只管说"用户要删这些"，怎么删在这里定。
    private let trackRemover: TrackRemover

    /// 最近一次算出来的那一列 —— 「点一行」把它交给播放器当队列。
    ///
    /// ⚠️ 它不是"第二份真相"：这一列本来就是 `library.allTracks` 算出来的，
    /// 存一份只是为了让「用户点的那一刻看到的」和「排进队列的」是**同一份** ——
    /// 点完再重算一遍的话，中间库要是变了，队列就和他刚才看到的不一样了。
    private var latestTracks: [Track] = []

    /// 最近一次播放呈现 —— 「点正在播的行」要立刻判断，不能干等下一次推送。
    ///
    /// ⚠️ 它是 `playbackChrome` 流的瞬时镜像，不是第二份 `PlayerState`。
    private var latestPlaybackChrome = SongPlaybackChrome.idle

    /// 订阅的生命 —— 跟这个 ViewModel 同寿。
    private let disposeBag = DisposeBag()

    /// 取图的动作 —— 装配层给，预取时用它（这一层不认识封面文件存在哪）。
    private let artworkProvider: ArtworkProvider

    init(
        library: LibraryStore,
        settings: AppSettings,
        trackRemover: TrackRemover,
        playManager: PlayManager,
        artworkProvider: @escaping ArtworkProvider
    ) {
        self.library = library
        self.settings = settings
        self.trackRemover = trackRemover
        self.playManager = playManager
        self.artworkProvider = artworkProvider
        search = LibrarySearch(library: library)
        sortModeRelay = BehaviorRelay(value: settings.songSortMode)
        sortDirectionRelay = BehaviorRelay(value: settings.songSortDirection)
        sortState = Observable.combineLatest(sortModeRelay, sortDirectionRelay)
        errors = library.errors
        isSelecting = isSelectingRelay.asObservable()
        selectedIDs = selectedIDsRelay.asObservable()
        playbackChrome = playManager.state
            .map(SongPlaybackChrome.from)
            .distinctUntilChanged()
            .share(replay: 1)

        // 六个来源合成一份列表：库里有什么 + 按什么排 + 升还是降 + 搜出来的是哪几首
        // + 音质开不开 + 播放次数显不显示。
        //
        // ⚠️ 用带 `resultSelector` 的那个重载，不要 `.map` 之后再拆元组 ——
        // 这里拿到的是几个独立参数，不用跟元组打交道。
        //
        // 🔴 **音质 / 播放次数显示开关也是这个 combineLatest 的来源**：翻一下，
        // 整份列表重算、每一行的 `quality` / `playCount` 跟着有 / 没有 ——
        // 页面那边靠差量刷新的 `reconfigureItems` 把在屏的那几行重画。
        //
        // ⚠️ **先筛后排**：搜索是"把不相关的拿掉"，排序是"把剩下的排好"。
        // 反过来的话，排序要去排那些马上就被丢掉的歌 —— 白干。
        let snapshots = Observable.combineLatest(
            library.allTracks,
            sortModeRelay,
            sortDirectionRelay,
            search.result,
            settings.showAudioQualityChanges,
            settings.showPlayCountChanges,
            library.favoriteTrackIDs
        ) { tracks, mode, direction, searchResult, showQuality, showPlayCount, favoriteIDs in
            // 没在搜就不动它；在搜才按命中的那些 id 筛（命中怎么算**只有库知道**，见 `LibraryStore`）。
            let searching = searchResult.isSearching
            let found = searching ? searchResult.matching(tracks) : tracks
            // 排一次、两处用：`rows` 和 `tracks` 必须是**同一个顺序**（点一行靠它对上）。
            let sorted = SongSort.sorted(found, mode: mode, direction: direction)
            // 🔴 数的是**整个曲库**（`tracks`），不是 `found` —— 横幅说的是库里有多少首找不到。
            let missingCount = tracks.reduce(0) { $0 + ($1.missingSince != nil ? 1 : 0) }
            return Snapshot(
                rows: sorted.map {
                    SongRow.make(
                        $0,
                        showQuality: showQuality,
                        showPlayCount: showPlayCount,
                        isFavorite: favoriteIDs.contains($0.id)
                    )
                },
                tracks: sorted,
                // 只有「按标题排序」才有字母可言；搜索时结果东一首西一首，分段也没意义。
                shouldGroup: mode == .title && !searching,
                foundNothing: searching && found.isEmpty,
                totalDurationMs: found.reduce(0) { $0 + ($1.durationMs ?? 0) },
                isSearching: searching,
                missingCount: missingCount,
                showsMissingBanner: LibraryReconcile.looksLikeWholeLibraryMissing(
                    missing: missingCount,
                    total: tracks.count
                )
            )
        }

        // 🔴 `share(replay:)` 不是为了提速，是**必需**：下面还要再订一次（记住最新那一列）。
        // 不共享的话两个订阅者各跑一遍「过滤 + 排序 + 建行」——
        // 几千首的曲库上，那是白白多算一遍。
        let shared = snapshots.share(replay: 1)
        snapshot = shared

        // 记住最新那一列 —— 点一行时要把"他当时看到的那一列"交给播放器（见 `playTrack`）。
        shared
            .subscribe(onNext: { [weak self] in self?.latestTracks = $0.tracks })
            .disposed(by: disposeBag)

        // ⚠️ 必须在 `snapshot` 赋完之后再订：早一步抓 `self` 会让编译器以为
        // 还没初始化完就被用了（`snapshot` 赋值前就被引用）。
        playbackChrome
            .subscribe(onNext: { [weak self] in self?.latestPlaybackChrome = $0 })
            .disposed(by: disposeBag)
    }

    // MARK: - 排序

    /// 当前排序字段。
    var sortMode: SongSortMode { sortModeRelay.value }

    /// 当前升降方向。
    var sortDirection: SortDirection { sortDirectionRelay.value }

    /// 换排序字段 —— **改完立刻存盘**，下次打开还是它。
    func setSortMode(_ mode: SongSortMode) {
        sortModeRelay.accept(mode)
        settings.songSortMode = mode
    }

    /// 换升降方向 —— 同上。
    func setSortDirection(_ direction: SortDirection) {
        sortDirectionRelay.accept(direction)
        settings.songSortDirection = direction
    }

    // MARK: - 播放次数显示

    /// 列表要不要画「耳机 + 次数」—— **只管显示，不管统计**。
    var showPlayCount: Bool { settings.showPlayCount }

    /// 显示开关变了 —— 页面订它来重建「更多」菜单里的勾。
    var showPlayCountChanges: Observable<Bool> { settings.showPlayCountChanges }

    /// 翻一格播放次数显示开关。
    func toggleShowPlayCount() {
        settings.showPlayCount.toggle()
    }

    // MARK: - 搜索

    /// 搜索框里的字变了。
    ///
    /// ⚠️ **不存盘**：搜索是一次性的，退出页面就该清空 ——
    /// 下次进来还停在上次的搜索结果，用户会以为歌丢了。
    ///
    /// ⚠️ 这里只把字交给搜索那一条管道（防抖 ＋ 算在别的线程上，见 `LibrarySearch`）；
    /// 结果从 `Snapshot` 那条路上回来，页面不认识管道。
    func setSearchText(_ text: String) {
        search.accept(text)
    }

    // MARK: - 选择模式

    /// 选择模式开着没有 —— 页面订阅它来换导航栏 / 底部工具条。
    let isSelecting: Observable<Bool>

    /// 选中的是哪些 —— 页面订阅它来更新工具条上「删除」能不能点。
    let selectedIDs: Observable<Set<Track.ID>>

    private let isSelectingRelay = BehaviorRelay(value: false)
    private let selectedIDsRelay = BehaviorRelay<Set<Track.ID>>(value: [])

    /// 现在是不是选择模式（**同步读**）。
    ///
    /// ⚠️ 给「列表内容变了」那条路用（页面里的 `pruneSelection(to:)`）——
    /// 那会儿要决定**要不要把表格那边的勾跟着同步一遍**；不在选择模式就什么都不用做。
    /// 走订阅也能拿到，但订阅给的是**事件**（要等一轮），这里要的是**当下**。
    var isSelectingNow: Bool { isSelectingRelay.value }

    /// 现在选中的是哪些（**同步读**）。
    ///
    /// ⚠️ 删除确认要用它：弹窗那一刻把 id **取一份**出来，之后提示语里数的和真删的
    /// 都是这一份 —— 不回头读第二次（读第二次就留下了两处对不上的余地）。
    var selectedIDsNow: Set<Track.ID> { selectedIDsRelay.value }

    /// 进 / 出选择模式 —— **反转**。只给「更多 → 选择」那个入口用。
    /// **退出时把选中清空** —— 下次进来是干净的。
    func toggleSelect() {
        let next = !isSelectingRelay.value
        isSelectingRelay.accept(next)
        if !next { selectedIDsRelay.accept([]) }
    }

    /// 退出选择模式 —— **幂等**：已经不在选择模式时也安全。
    ///
    /// 🔴 「一个任务做完就退出」用它，**不要**用 `toggleSelect()` ——
    /// 后者是"反转"，那会把「退出」这个结果的正确性押在
    /// 「调用那一刻必然还在选择模式」这个隐含前提上。
    func endSelect() {
        isSelectingRelay.accept(false)
        selectedIDsRelay.accept([])
    }

    /// 选中 / 取消选中一首。
    func setSelected(_ id: Track.ID, _ selected: Bool) {
        var ids = selectedIDsRelay.value
        if selected {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        selectedIDsRelay.accept(ids)
    }

    /// 全选 —— 传进来的就是**当前列表**（搜索过滤之后的那些）。
    func selectAll(_ ids: [Track.ID]) {
        selectedIDsRelay.accept(Set(ids))
    }

    /// 取消全选。
    func deselectAll() {
        selectedIDsRelay.accept([])
    }

    /// 丢掉**已经不在列表里**的选中项。
    ///
    /// ⚠️ 必须做：搜索条件一变，先前选中的歌可能已经看不见了 ——
    /// 不清理的话「删除」会作用到用户根本没在看着的歌上。
    /// 出处：primuse `SongSelectionModel.prune(to:)`。数学在 `SelectionMath`（全工程一份）；
    /// 🔴 **「值没变就不写」的纪律留在这儿** —— 那是写侧的事，数学不管。
    func pruneSelection(to available: [Track.ID]) {
        let ids = selectedIDsRelay.value
        guard !ids.isEmpty else { return }
        let kept = SelectionMath.prune(ids, to: available)
        guard kept.count != ids.count else { return }
        selectedIDsRelay.accept(kept)
    }

    // MARK: - 删除

    /// 删掉这些歌。
    ///
    /// - Parameter deleteFiles: `true` 连磁盘上的文件一起删。
    /// - Throws: 数据库写失败时抛出 —— 页面负责把它变成一句给用户看的话。
    func delete(trackIDs: [Track.ID], deleteFiles: Bool) throws {
        try trackRemover.remove(trackIDs: trackIDs, deleteFiles: deleteFiles)
    }

    /// 库里**所有**「文件不在本机」的歌 —— 「移除找不到的歌」要用。
    ///
    /// 🔴 **从库里读，不从 `latestTracks` 读**：后者是当前这一列（搜索过滤之后），
    /// 拿它去删会把"找不到的歌"漏掉一大半。
    ///
    /// ⚠️ 复用对账那一个投影（`reconcileEntries`）：它读的就是 `id` ＋ 有没有标记，
    /// 正是这里要的那一份；另开一个口等于为同一个事实写第二条 SQL。
    func missingTrackIDs() throws -> [Track.ID] {
        try library.reconcileEntries().filter(\.isMissing).map(\.id)
    }

    // MARK: - 取一首

    /// 按 id 取完整的一首 —— 点一行播放要用（`SongRow` 只是展示投影，没有路径）。
    ///
    /// ⚠️ 用 `try?`：库里读不出来那一下（跟 `errors` 那条流是同一类问题），点行就不播了 ——
    /// 不在这儿再弹一次错，那是 `errors` 已经管的事。
    func track(id: Track.ID) -> Track? {
        try? library.track(id: id)
    }

    /// 点一行 —— 播这一首，**并把它所在的这一列排进队列**。
    ///
    /// 页面只传 id 过来，按 id 取完整的一首、调播放器都在这儿做 —— 页面不认识播放器。
    ///
    /// ⚠️ 队列用的是**用户当时看到的那一列**（`latestTracks`）：搜了「周杰伦」点一首，
    /// 播完接着放周杰伦，而不是跳回整个曲库。那一列还没有（理论上不该发生，页面还没画）
    /// 或者点的那首不在里面时，播放器那边只会播这一首 —— 不会塞一首他没点过的歌。
    ///
    /// ⚠️ **不动洗牌**：点行只是挑起播点。洗牌开着时 `replace` 会把点中的歌放队首、其余打乱；
    /// 关洗牌是表头「播放」/ 模式键的事，不该被点行偷偷改掉（会关，我们否掉）。
    func playTrack(id: Track.ID) {
        guard let track = track(id: id) else { return }
        playManager.play(track, in: latestTracks)
    }

    /// 标题分段后画面顺序可能和 `SongSort` 不一致（`SongSections` 用系统 collation 重排）——
    /// 页面算完段之后把**看得见的顺序**灌回来，点行进队才跟列表一致。
    func syncPlayOrder(toVisibleIDs ids: [Track.ID]) {
        let byID = Dictionary(uniqueKeysWithValues: latestTracks.map { ($0.id, $0) })
        latestTracks = ids.compactMap { byID[$0] }
    }

    /// 点一行该干什么 —— 判据在 `SongPlaybackChrome.rowTapOutcome`；这里只执行「开播」副作用。
    ///
    /// 🔴 **先问一句"文件还在不在"**，它压过下面那条"是不是正在播"：
    /// 一首找不到文件的歌，点它既不该开播、也不该跳播放页（播放页那边一样放不出声）。
    ///
    /// ⚠️ 判据读 `latestTracks`（＝**列表当时画出来的那一份**），不另读库：
    /// 用户是看着那一行点的 —— 那行没变灰，点下去就不该冒出"不在本机"。
    @discardableResult
    func handleRowTap(id: Track.ID) -> SongRowTapOutcome {
        if latestTracks.first(where: { $0.id == id })?.missingSince != nil {
            return .missingFile
        }
        let outcome = latestPlaybackChrome.rowTapOutcome(for: id)
        if case .startPlayback = outcome {
            playTrack(id: id)
        }
        return outcome
    }

    /// 此刻的播放呈现 —— 配行 / 刷新可见行时读，避免再订一次流。
    var playbackChromeNow: SongPlaybackChrome { latestPlaybackChrome }

    /// 把这首排到「下一首」播放。
    ///
    /// ⚠️ 取不出来那首（库里刚被删掉）就什么都不做 —— 跟 `playTrack` 同一条。
    func playNext(id: Track.ID) {
        guard let track = track(id: id) else { return }
        playManager.playNext(track)
    }

    /// 收 / 取消收藏这首歌。
    ///
    /// - Parameter isFavorite: 这一行**当前**显示的收藏状态（来自 `favoriteTrackIDs` 流，实时的）。
    ///   直接用它翻，不再查库 —— 单一数据源，不用二次确认。
    ///
    /// ⚠️ 用 `try?`：写不进去不弹错（`LibraryStore.errors` 那条流会管库级别的故障），
    /// 收藏状态会随 `favoriteTrackIDs` 流自动回来 —— 没写成的话，行菜单的文案不会变，
    /// 用户一看就知道没成功。
    func toggleFavorite(id: Track.ID, isFavorite: Bool) {
        try? library.setFavorite(!isFavorite, trackID: id)
    }

    /// 这首歌在磁盘上的位置 —— 共享菜单要用。
    func fileURL(for id: Track.ID) -> URL? {
        guard let track = track(id: id) else { return nil }
        return MusicFileStore.resolve(relativePath: track.path)
    }

    // MARK: - 封面预取

    /// 提前把封面读进内存缓存 —— 滚到那一行时，行里只是查一下缓存，不读盘。
    ///
    /// 🔴 **读盘这一步归这里、不归页面**：页面只做三件事（订阅 / 渲染 / 转发动作），
    /// 碰数据层是这一层的事（见 `SongsViewController` 顶上那段）。
    /// 页面负责把"要预取哪几张"和两个界面量交过来，剩下的在这儿。
    ///
    /// ⚠️ 取图走**注入的那个动作**："封面文件在哪"是 `Data` 的事，这一层也不认识
    /// （跟行里那条缝同一个，见 `Core/UI/ArtworkProvider.swift`）。
    ///
    /// ⚠️ **尺寸和屏幕倍数必须由页面给**，两条原因：
    /// ① 尺寸得和行里画的那一格一致（`SongTableCell.artworkSide`）——
    ///    给的尺寸不一样，取出来就是另一张图，行里照样要重读一遍；
    /// ② 倍数只有界面上下文里才有 —— 后台线程取到的是默认值，@3x 的机器上会出一张偏小的图。
    ///
    /// ⚠️ 读盘 + 解码发到**后台队列**：`ArtworkStore` 的缓存是 `NSCache`（线程安全），
    /// 它存在的意义正是"别让读盘发生在滚动的每一帧里"。
    /// 这一步**不碰本类的任何状态**，所以跟顶上那条"全在主线程"不冲突（只借了队列去读盘）。
    func prefetchArtwork(_ artworkPaths: [String], pointSize: CGSize, displayScale: CGFloat) {
        guard !artworkPaths.isEmpty else { return }
        let artworkProvider = self.artworkProvider
        DispatchQueue.global(qos: .userInitiated).async {
            for artworkPath in artworkPaths {
                _ = artworkProvider(artworkPath, pointSize, displayScale)
            }
        }
    }
}

// MARK: - 搜索词的接收方

/// 搜索词的接收方 —— 转发那条线在 `SearchTextForwarding` 的默认实现里（全工程一份）。
extension SongsViewModel: SearchTextSetting {}

// MARK: - 多选状态的读口

/// 选中集的收拾（`TableSelectionSync.prune`）经由这三个读口进来；真相仍只在这里。
extension SongsViewModel: SelectionState {}

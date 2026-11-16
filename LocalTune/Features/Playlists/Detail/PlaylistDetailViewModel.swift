import Foundation
import RxRelay
import RxSwift
import UIKit

/// 歌单详情页的页面状态 —— **这一页该显示什么、用户动作落到哪儿**。
///
/// 🔴 它不认识界面：不持有页面、不碰表格、不拼导航栏。页面只做三件事：
/// 订阅快照 → 渲染 → 把用户动作转回来（跟曲库页、歌单列表页同一条架构）。
@MainActor
final class PlaylistDetailViewModel {

    // MARK: - 快照

    struct Info: Equatable {
        var name: String
        var cover: PlaylistCover
        var isFavorites: Bool
    }

    struct Snapshot: Equatable {
        var info: Info?
        var songs: [SongRow]
        var tracks: [Track]
        var totalDurationMs: Int
        /// 「按标题排 + 没在搜」才分段（跟曲库页同一条）。
        var shouldGroup: Bool
    }

    let snapshot: Observable<Snapshot>
    let errors: Observable<Error>
    let playbackChrome: Observable<SongPlaybackChrome>

    /// 排序状态变了 —— 页面重建「更多」菜单里的勾。
    let sortState: Observable<(PlaylistDetailSortMode, SortDirection)>

    /// 手动排序开着没有。
    let isReordering: Observable<Bool>

    /// 选择模式开着没有。
    let isSelecting: Observable<Bool>

    /// 选中的是哪些 —— 工具条「移除」能不能点。
    let selectedIDs: Observable<Set<Track.ID>>

    // MARK: - 依赖

    let playlistID: Playlist.ID

    private let library: LibraryStore
    private let settings: AppSettings
    private let trackRemover: TrackRemover
    private let playManager: PlayManager

    private var latestTracks: [Track] = []
    private var latestPlaybackChrome = SongPlaybackChrome.idle

    /// 搜索 —— 搜索框里敲的字进去，**命中的那些歌**出来（防抖 ＋ 算在别的线程上）。
    ///
    /// 🔴 **"哪几首"和"在不在搜"同源**（都从这份 `Result` 上读）—— 两者要是分开走，
    /// 就会出现"框里写着 A、列表按 B 筛"那一拍（见 `LibrarySearch` 顶上那段）。
    private let search: LibrarySearch
    private let sortModeRelay: BehaviorRelay<PlaylistDetailSortMode>
    private let sortDirectionRelay: BehaviorRelay<SortDirection>
    private let isReorderingRelay = BehaviorRelay(value: false)
    private let isSelectingRelay = BehaviorRelay(value: false)
    private let selectedIDsRelay = BehaviorRelay<Set<Track.ID>>(value: [])
    /// 取消手动排序时排序字段可能没变，靠它显式重推快照。
    private let snapshotRepublishRelay = BehaviorRelay(value: 0)
    /// 进手动排序前的字段 —— 取消时还原。
    private var modeBeforeReordering: PlaylistDetailSortMode?
    /// 进手动排序前的方向 —— 取消时还原（🔴 只记 mode 会把用户的降序静默改成升序）。
    private var directionBeforeReordering: SortDirection?

    private let disposeBag = DisposeBag()

    // MARK: - 建立

    /// 歌单封面的编排者 —— 换封面 / 生成拼图走它，不直接碰 `ArtworkStore`。
    private let covers: PlaylistCoverService

    init(
        playlistID: Playlist.ID,
        library: LibraryStore,
        covers: PlaylistCoverService,
        settings: AppSettings,
        trackRemover: TrackRemover,
        playManager: PlayManager
    ) {
        self.playlistID = playlistID
        self.library = library
        self.covers = covers
        self.settings = settings
        self.trackRemover = trackRemover
        self.playManager = playManager
        errors = library.errors
        playbackChrome = playManager.state
            .map(SongPlaybackChrome.from)
            .distinctUntilChanged()
            .share(replay: 1)

        search = LibrarySearch(library: library)
        sortModeRelay = BehaviorRelay(value: settings.playlistDetailSortMode)
        sortDirectionRelay = BehaviorRelay(value: settings.playlistDetailSortDirection)
        sortState = Observable.combineLatest(sortModeRelay, sortDirectionRelay)
        isReordering = isReorderingRelay.asObservable()
        isSelecting = isSelectingRelay.asObservable()
        selectedIDs = selectedIDsRelay.asObservable()

        // 八个来源合成一份列表（Rx `combineLatest` 带 resultSelector 最多 8 路）。
        // 排序字段 + 升降已合成 `sortState`，腾出一格给显式重推令牌。
        let shared = Observable.combineLatest(
            library.allPlaylists,
            library.playlistTracks(playlistID),
            settings.showAudioQualityChanges,
            settings.showPlayCountChanges,
            search.result,
            library.favoriteTrackIDs,
            sortState,
            snapshotRepublishRelay
        ) { playlists, tracks, showQuality, showPlayCount, searchResult, favoriteIDs, sort, _ in
            let searching = searchResult.isSearching
            // 🔴 **这一页不许自己比 title / artist / album** —— 那会跟曲库页两套规则；
            // 只按库给的那组命中 id 过一遍。
            let matched = searching ? searchResult.matching(tracks) : tracks
            let sorted = PlaylistDetailSort.sorted(matched, mode: sort.0, direction: sort.1)
            return Self.makeSnapshot(
                playlist: playlists.first { $0.id == playlistID },
                tracks: sorted,
                showQuality: showQuality,
                showPlayCount: showPlayCount,
                favoriteIDs: favoriteIDs,
                shouldGroup: sort.0 == .title && !searching
            )
        }
        .share(replay: 1)

        snapshot = shared
        shared
            .subscribe(onNext: { [weak self] in self?.latestTracks = $0.tracks })
            .disposed(by: disposeBag)

        playbackChrome
            .subscribe(onNext: { [weak self] in self?.latestPlaybackChrome = $0 })
            .disposed(by: disposeBag)
    }

    // MARK: - 读当下

    var sortMode: PlaylistDetailSortMode { sortModeRelay.value }
    var sortDirection: SortDirection { sortDirectionRelay.value }
    var isReorderingNow: Bool { isReorderingRelay.value }
    var isSelectingNow: Bool { isSelectingRelay.value }
    var selectedIDsNow: Set<Track.ID> { selectedIDsRelay.value }
    var playbackChromeNow: SongPlaybackChrome { latestPlaybackChrome }

    // MARK: - 播放

    @discardableResult
    func playAll() -> Bool {
        guard let first = latestTracks.first else { return false }
        playManager.setPlaybackMode(.all)
        playManager.play(first, in: latestTracks)
        return true
    }

    @discardableResult
    func shuffleAll() -> Bool {
        guard let random = latestTracks.randomElement() else { return false }
        playManager.setPlaybackMode(.shuffle)
        playManager.play(random, in: latestTracks)
        return true
    }

    /// 点行开播 —— 不改播放模式。
    func playTrack(id: Track.ID) {
        guard let track = latestTracks.first(where: { $0.id == id }) else { return }
        playManager.play(track, in: latestTracks)
    }

    /// 封面流播放键：只 toggle，不切歌。
    func togglePlayPause() {
        playManager.togglePlayPause()
    }

    /// 点封面流中央：当前曲 toggle，否则开播（不改模式）。
    func handleCoverFlowCenterTap(id: Track.ID) {
        if latestPlaybackChrome.isCurrent(id) {
            playManager.togglePlayPause()
        } else {
            playTrack(id: id)
        }
    }

    /// 一批 id 的艺人名 —— **一次建表**（O(n + m)）。
    ///
    /// 🔴 别改成「每个 id 一次 `first(where:)`」：封面流给整列歌配艺人时那就是 O(n²)。
    func artistNames(for ids: [Track.ID]) -> [Track.ID: String] {
        let wanted = Set(ids)
        var table: [Track.ID: String] = [:]
        table.reserveCapacity(wanted.count)
        for track in latestTracks where wanted.contains(track.id) {
            table[track.id] = track.artist
        }
        return table
    }

    var iPadAutoCoverFlow: Bool {
        get { settings.iPadAutoCoverFlow }
        set { settings.iPadAutoCoverFlow = newValue }
    }

    /// 把这首排到「下一首」播放。
    func playNext(id: Track.ID) {
        guard let track = latestTracks.first(where: { $0.id == id }) else { return }
        playManager.playNext(track)
    }

    /// 这首歌在磁盘上的位置 —— 共享菜单要用。
    func fileURL(for id: Track.ID) -> URL? {
        guard let track = latestTracks.first(where: { $0.id == id }) else { return nil }
        return MusicFileStore.resolve(relativePath: track.path)
    }

    /// 点行 —— 播这一首（**不改播放模式**）。
    ///
    /// 🔴 **先问一句"文件还在不在"**，它压过"是不是正在播"：找不到文件的歌点它
    /// 既不该开播、也不该跳播放页。判据跟曲库页是**同一条**，只是各在自己的 VM 里问。
    ///
    /// ⚠️ 读 `latestTracks`（＝列表画出来的那一份）—— 跟那一行显示的状态同源：
    /// 那行没变灰，点下去就不该冒出"不在本机"。
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

    // MARK: - 排序

    func setSortMode(_ mode: PlaylistDetailSortMode) {
        sortModeRelay.accept(mode)
        settings.playlistDetailSortMode = mode
    }

    func setSortDirection(_ direction: SortDirection) {
        sortDirectionRelay.accept(direction)
        settings.playlistDetailSortDirection = direction
    }

    // MARK: - 手动排序

    func beginReordering() {
        guard !isSelectingNow, !isReorderingNow else { return }
        modeBeforeReordering = sortModeRelay.value
        directionBeforeReordering = sortDirectionRelay.value
        if sortModeRelay.value != .playlistOrder {
            setSortMode(.playlistOrder)
        }
        // 编辑态看升序更直观 —— **只推 relay，不写 settings**；取消时按记下的方向还原。
        if sortDirectionRelay.value != .ascending {
            sortDirectionRelay.accept(.ascending)
        }
        isReorderingRelay.accept(true)
    }

    func finishReordering(_ orderedIDs: [Track.ID]) throws {
        // 🔴 **先写库、再退编辑态**：写失败仍停在编辑态，用户还能再拖（列表页同口径）。
        try library.reorder(playlistID: playlistID, orderedTrackIDs: orderedIDs)
        modeBeforeReordering = nil
        directionBeforeReordering = nil
        // 完成 = 接受「歌单顺序」；方向也落成升序（跟编辑态看到的一致）。
        settings.playlistDetailSortDirection = .ascending
        isReorderingRelay.accept(false)
    }

    func cancelReordering() {
        let previousMode = modeBeforeReordering ?? .playlistOrder
        let previousDirection = directionBeforeReordering ?? .ascending
        modeBeforeReordering = nil
        directionBeforeReordering = nil
        if sortModeRelay.value != previousMode {
            sortModeRelay.accept(previousMode)
            settings.playlistDetailSortMode = previousMode
        }
        if sortDirectionRelay.value != previousDirection {
            sortDirectionRelay.accept(previousDirection)
            // settings 进编辑时没被改写；这里仍对齐，防止别处读到不一致。
            settings.playlistDetailSortDirection = previousDirection
        }
        isReorderingRelay.accept(false)
        snapshotRepublishRelay.accept(snapshotRepublishRelay.value &+ 1)
    }

    // MARK: - 选择

    /// 进 / 出选择模式 —— **反转**。只给「更多 → 选择」那个入口用。
    func toggleSelect() {
        guard !isReorderingNow else { return }
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

    func setSelected(_ id: Track.ID, _ selected: Bool) {
        var ids = selectedIDsRelay.value
        if selected { ids.insert(id) } else { ids.remove(id) }
        selectedIDsRelay.accept(ids)
    }

    func selectAll(_ ids: [Track.ID]) {
        selectedIDsRelay.accept(Set(ids))
    }

    func deselectAll() {
        selectedIDsRelay.accept([])
    }

    func pruneSelection(to available: [Track.ID]) {
        let ids = selectedIDsRelay.value
        guard !ids.isEmpty else { return }
        let kept = SelectionMath.prune(ids, to: available)
        guard kept.count != ids.count else { return }
        selectedIDsRelay.accept(kept)
    }

    // MARK: - 编辑歌单 / 曲目

    func remove(trackIDs: [Track.ID]) throws {
        try library.remove(trackIDs: trackIDs, from: playlistID)
        pruneSelection(to: latestTracks.map(\.id).filter { !Set(trackIDs).contains($0) })
    }

    /// 从曲库删除 —— 跟曲库页同一条 `TrackRemover`（可只删库 / 连文件）。
    func deleteFromLibrary(trackIDs: [Track.ID], deleteFiles: Bool) throws {
        try trackRemover.remove(trackIDs: trackIDs, deleteFiles: deleteFiles)
        pruneSelection(to: latestTracks.map(\.id).filter { !Set(trackIDs).contains($0) })
    }

    func canRename(to name: String) -> Bool {
        PlaylistNaming.canSave(name)
    }

    func rename(to name: String) throws {
        guard PlaylistNaming.canSave(name) else { return }
        try library.rename(playlistID: playlistID, to: PlaylistNaming.trimmed(name))
    }

    func deletePlaylist() throws {
        try library.delete(playlistIDs: [playlistID])
    }

    /// 用户手挑一张歌单封面。
    ///
    /// ⚠️ **压 JPEG 这一步在本层做**（`CoverImageWriter`，`Core/UI`）：像素是画布的活儿，
    /// `Data` 层只收字节。压不出来 → 变成人话。
    func setPlaylistCover(_ image: UIImage) throws {
        guard let data = CoverImageWriter.jpegDataForCustomCover(image) else {
            throw PlaylistCoverError.cannotEncode
        }
        try covers.applyPicked(data, playlistID: playlistID)
    }

    func generatePlaylistCover(completion: @escaping (Result<Bool, Error>) -> Void) {
        covers.generate(playlistID: playlistID, completion: completion)
    }

    // MARK: - 搜索

    func setSearchText(_ text: String) {
        search.accept(text)
    }

    /// 标题分段后画面顺序可能和 `PlaylistDetailSort` 不一致 —— 页面算完段后灌回可见顺序。
    func syncPlayOrder(toVisibleIDs ids: [Track.ID]) {
        let byID = Dictionary(uniqueKeysWithValues: latestTracks.map { ($0.id, $0) })
        latestTracks = ids.compactMap { byID[$0] }
    }

    // MARK: - 私有

    private static func makeSnapshot(
        playlist: Playlist?,
        tracks: [Track],
        showQuality: Bool,
        showPlayCount: Bool,
        favoriteIDs: Set<Track.ID>,
        shouldGroup: Bool
    ) -> Snapshot {
        Snapshot(
            info: playlist.map {
                Info(
                    name: $0.name,
                    cover: PlaylistCover($0),
                    isFavorites: $0.isFavorites
                )
            },
            songs: tracks.map {
                SongRow.make(
                    $0,
                    showQuality: showQuality,
                    showPlayCount: showPlayCount,
                    isFavorite: favoriteIDs.contains($0.id)
                )
            },
            tracks: tracks,
            totalDurationMs: tracks.reduce(0) { $0 + ($1.durationMs ?? 0) },
            shouldGroup: shouldGroup
        )
    }
}

// MARK: - 搜索词的接收方

/// 搜索词的接收方 —— 转发那条线在 `SearchTextForwarding` 的默认实现里（全工程一份）。
extension PlaylistDetailViewModel: SearchTextSetting {}

// MARK: - 多选状态的读口

/// 选中集的收拾（`TableSelectionSync.prune`）经由这三个读口进来；真相仍只在这里。
extension PlaylistDetailViewModel: SelectionState {}

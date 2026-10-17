import Foundation
import RxRelay
import RxSwift
import UIKit

/// 歌单页的页面状态 —— **列表该显示什么、用户动作落到哪儿**。
///
/// 🔴 它不认识界面：不持有页面、不碰表格、不拼导航栏。页面只做三件事：
/// 订阅快照 → 渲染 → 把用户动作转回来（跟曲库页同一条架构，见 `SongsViewModel`）。
///
/// ## 数据从哪来
///
/// 两条库里的流 + 两个自己的开关：
/// - `LibraryStore.allPlaylists` —— 歌单本身，**已按手动顺序排好**；
/// - `LibraryStore.playlistTrackCounts` —— 每个歌单几首歌（一条 `GROUP BY` 算完，
///   **不让每一行自己去查**）；
/// - 搜索词、排序偏好 —— 这两个是页面自己的，不来自库。
///
/// ## 线程
///
/// **全在主线程**：库那两条流走 `LibraryStore` 的观察回调（用 `.async(onQueue: .main)` 启动），
/// 页面动作本来就是主线程来的。
/// ⇒ 下面那几个 `BehaviorRelay` 和 `modeBeforeReordering` **都不需要锁** ——
/// 那个 `var` 是在 `beginReordering()` 里写、`cancelReordering()` 里读，两处都在主线程。
final class PlaylistsViewModel {

    // MARK: - 快照

    /// 列表内容：库一变、排序一变、搜索词一变，就推一份新的。
    struct Snapshot: Equatable {

        /// 「最爱的歌曲」那一行 —— **0 或 1 行**（被搜索滤掉时是 `nil`）。
        var favorites: PlaylistRow?

        /// 用户歌单那一段（已按当前排序排好）。
        var users: [PlaylistRow]

        /// 搜索有词、但一个歌单都没命中（「最爱的歌曲」也算一个）——
        /// 页面据此弹一句「未找到相关歌单」。
        ///
        /// ⚠️ 「在不在搜」这个信息**只并进这一项**，不再单摆一个字段：
        /// 它原来的唯一读者是空状态，而这一页**没有空状态**（「最爱的歌曲」恒占一行，
        /// 列表永远不会是空的 —— 见 `PlaylistsViewController` 顶上那段）。
        var foundNothing: Bool
    }

    /// 列表内容。
    let snapshot: Observable<Snapshot>

    /// 排序状态（字段 + 升 / 降）—— 页面订阅它来**重建排序菜单**。
    ///
    /// ⚠️ 为什么要有这个出口：`UIBarButtonItem` 的菜单**建好之后不会自己刷新**，
    /// 打勾是"建的那一刻"定死的。所以页面得知道排序变了，然后重建菜单。
    let sortState: Observable<(PlaylistSortMode, SortDirection)>

    /// 库读不出来（观察断了、文件坏了…）—— 页面订阅它、**弹一次提示**。
    ///
    /// ⚠️ 错误**不会自己恢复**：观察断了就是断了（见 `LibraryStore` 顶上那段）——
    /// 收到就该提示用户，别等下一次更新（不会有下一次）。
    let errors: Observable<Error>

    /// 手动排序开着没有 —— 页面订阅它来进出编辑态、换导航栏那两颗按钮。
    let isReordering: Observable<Bool>

    // MARK: - 私有状态

    /// 当前按什么排 —— 排序菜单读它来打勾。
    private let sortModeRelay: BehaviorRelay<PlaylistSortMode>
    private let sortDirectionRelay: BehaviorRelay<SortDirection>

    /// 搜索框里现在是什么 —— 空串 = 没在搜。
    private let searchTextRelay = BehaviorRelay(value: "")

    private let isReorderingRelay = BehaviorRelay(value: false)

    /// 显式重推快照的令牌 —— **只**给「取消手动排序」用。
    ///
    /// 取消时排序字段可能没变（进编辑前已经是「手动」），`sortModeRelay` 不会再发；
    /// 而编辑态里表格停在拖到一半的样子，必须再推一份快照才能画回去。
    /// 用令牌进 `combineLatest`，不靠「再设一次同一排序值」的副作用。
    private let snapshotRepublishRelay = BehaviorRelay(value: 0)

    /// 进编辑态**之前**是哪个排序字段 —— 「取消」要退回它。
    ///
    /// ⚠️ 进编辑态时会把它切成「手动」（理由见 `beginReordering`），所以得先记一笔。
    private var modeBeforeReordering: PlaylistSortMode?

    /// 默认歌单名 —— 新建时名字留空就用它。
    ///
    /// ⚠️ 一个歌单总得有个名字，而"点了保存什么都没发生"比一个凑合的名字更让人摸不着头脑。
    private static let defaultPlaylistName = "新歌单"

    // MARK: - 依赖

    private let library: LibraryStore
    private let settings: AppSettings

    private let disposeBag = DisposeBag()

    // MARK: - 建立

    /// 歌单封面的编排者 —— 换封面 / 生成拼图走它，不直接碰 `ArtworkStore`。
    private let covers: PlaylistCoverService

    init(library: LibraryStore, settings: AppSettings, covers: PlaylistCoverService) {
        self.library = library
        self.settings = settings
        self.covers = covers

        sortModeRelay = BehaviorRelay(value: settings.playlistSortMode)
        sortDirectionRelay = BehaviorRelay(value: settings.playlistSortDirection)
        sortState = Observable.combineLatest(sortModeRelay, sortDirectionRelay)
        errors = library.errors
        isReordering = isReorderingRelay.asObservable()

        // 六个来源合成一份列表：库里的歌单 + 各有几首歌 + 按什么排 + 升还是降 + 在搜什么
        // + 显式重推令牌（取消手动排序时用，见 `snapshotRepublishRelay`）。
        //
        // ⚠️ 用带 `resultSelector` 的那个重载，不要 `.map` 之后再拆元组 ——
        // 这里拿到的是几个独立参数，不用跟元组打交道。
        //
        // 🔴 `share(replay:)` 不是为了提速，是**必需**：页面要从这条流上订两次
        //（一次画列表、一次听「一个都没搜着」）。不共享的话两个订阅者各跑一遍
        //「过滤 + 排序 + 建行」—— 白算一遍。
        snapshot = Observable.combineLatest(
            library.allPlaylists,
            library.playlistTrackCounts,
            sortModeRelay,
            sortDirectionRelay,
            searchTextRelay,
            snapshotRepublishRelay
        ) { playlists, counts, mode, direction, query, _ in
            Self.makeSnapshot(playlists, counts: counts, mode: mode, direction: direction, query: query)
        }
        .share(replay: 1)
    }

    // MARK: - 排序

    /// 当前排序字段。
    var sortMode: PlaylistSortMode { sortModeRelay.value }

    /// 当前升降方向。
    var sortDirection: SortDirection { sortDirectionRelay.value }

    /// 换排序字段 —— **改完立刻存盘**，下次打开还是它。
    func setSortMode(_ mode: PlaylistSortMode) {
        sortModeRelay.accept(mode)
        settings.playlistSortMode = mode
    }

    /// 换升降方向 —— 同上。
    func setSortDirection(_ direction: SortDirection) {
        sortDirectionRelay.accept(direction)
        settings.playlistSortDirection = direction
    }

    // MARK: - 搜索

    /// 搜索框里的字变了。
    ///
    /// ⚠️ **不存盘**：搜索是一次性的，退出页面就该清空 ——
    /// 下次进来还停在上次的搜索结果，用户会以为歌单丢了。
    func setSearchText(_ text: String) {
        searchTextRelay.accept(text)
    }

    // MARK: - 手动排序

    /// 现在在不在手动排序里（**同步读**）。
    ///
    /// ⚠️ 给「列表内容换了」那条路用：编辑态里表格的顺序是**用户拖出来的**，
    /// 快照推来的旧顺序不能往上盖（见 `PlaylistsViewController.apply`）。
    /// 走订阅也能拿到，但订阅给的是**事件**（要等一轮），这里要的是**当下**。
    var isReorderingNow: Bool { isReorderingRelay.value }

    /// 进手动排序 —— **同时把排序字段切成「手动」**。
    ///
    /// 🔴 为什么切在**这一刻**、而不是拖完那一刻：切排序字段会**同步**推一份新快照出来
    /// （`sortModeRelay` → `combineLatest`），而那一份里的顺序还是库里**旧的** `sortIndex`。
    /// 要是等拖完再切，用户刚拖出来的顺序会先被那一份打回去、过一会儿再跳回来 ——
    /// 屏幕上就是"松手之后列表闪一下"。
    /// 进编辑态时就切，那一次推送正好被「编辑态里不重画」那条规矩挡掉。
    func beginReordering() {
        guard !isReorderingNow else { return }
        modeBeforeReordering = sortModeRelay.value
        isReorderingRelay.accept(true)
        setSortMode(.manual)
    }

    /// 拖完了 —— 把新顺序写回去。
    ///
    /// ⚠️ 传的是**完整的那个新顺序**（见 `LibraryStore.applyPlaylistManualOrder`）。
    ///
    /// ⚠️ 这里**不重画列表**：写库之后库会把新顺序推回来，页面照着它重画一次就够了。
    /// 当场重画反而会用"库里还没更新的顺序"盖掉用户刚拖出来的样子。
    ///
    /// 🔴 **先写库、再退编辑态**：写失败仍停在编辑态，用户还能再拖
    /// （跟歌单详情页同一条；早先先退编辑再写，失败时顺序已丢、界面也退了）。
    func finishReordering(_ orderedIDs: [Playlist.ID]) throws {
        try library.applyPlaylistManualOrder(orderedIDs)
        modeBeforeReordering = nil
        isReorderingRelay.accept(false)
    }

    /// 取消 —— **什么都不写库**，退回进编辑态之前那个排序字段，再显式推一份快照。
    ///
    /// 顺序：先恢复排序真相 → 退出编辑态 → 重推快照。
    /// 重推必须在 `isReordering == false` 之后，否则页面 `apply` 会因编辑态挡掉（见那边）。
    /// 🔴 **不**靠「再设一次同一排序值」去蹭 `BehaviorRelay` 的副作用。
    func cancelReordering() {
        let previous = modeBeforeReordering ?? .createdAt
        modeBeforeReordering = nil
        if sortModeRelay.value != previous {
            sortModeRelay.accept(previous)
            settings.playlistSortMode = previous
        }
        isReorderingRelay.accept(false)
        snapshotRepublishRelay.accept(snapshotRepublishRelay.value &+ 1)
    }

    // MARK: - 动作

    /// 建一个空歌单。
    ///
    /// ⚠️ 名字去空白之后是空的 ⇒ 用默认名兜底（理由见 `defaultPlaylistName`）。
    func createPlaylist(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try library.createPlaylist(name: trimmed.isEmpty ? Self.defaultPlaylistName : trimmed)
    }

    /// 这个名字能不能用 —— 去空白之后不是空的就行。
    ///
    /// 🔴 **判据只有这一处**：页面上那个「保存」键亮不亮靠它（见 `PlaylistsViewController+Actions`），
    /// 真写库之前它再挡一道。页面里**不许再写一遍** `trimmingCharacters`。
    ///
    /// ⚠️ 改名跟建单不一样：建单留空有「新歌单」兜底，改名**没有**兜底名字可用 ——
    /// 把名字改成「新歌单」是比不写更坏的结果，所以空名字就是不让改。
    func canRename(to name: String) -> Bool {
        PlaylistNaming.canSave(name)
    }

    /// 改歌单名。
    ///
    /// ⚠️ 名字去空白之后是空的就**不写**。正常走不到这一支（界面那头已经把「保存」置灰了），
    /// 留着是**双保险** —— 跟 `deletePlaylists` 那边数据层再挡一道是同一个道理。
    ///
    /// - Throws: 写库失败时抛出，页面负责把它变成一句给用户看的话。
    func renamePlaylist(id: Playlist.ID, to name: String) throws {
        guard PlaylistNaming.canSave(name) else { return }
        try library.rename(playlistID: id, to: PlaylistNaming.trimmed(name))
    }

    /// 删歌单 —— 里面的歌**不受影响**，只是这层关联没了。
    ///
    /// ⚠️ 「最爱的歌曲」数据层挡着删不掉（见 `LibraryStore.delete`）；
    /// 界面上那一行的「删除」也是置灰的，两处各管一头。
    func deletePlaylists(_ ids: [Playlist.ID]) throws {
        try library.delete(playlistIDs: ids)
    }

    /// 把歌曲页当前选中的歌加入指定歌单。
    ///
    /// 数据层会跳过歌单里已经存在的歌，并按传入顺序把新歌接到末尾。
    func addTracks(_ trackIDs: [Track.ID], to playlistID: Playlist.ID) throws {
        try library.add(trackIDs: trackIDs, to: playlistID)
    }

    /// 这个歌单里现在有哪些歌（按歌单顺序）—— 「添加到播放列表」要把它们批量加进别的歌单。
    func trackIDs(in playlistID: Playlist.ID) throws -> [Track.ID] {
        try library.tracks(in: playlistID).map(\.id)
    }

    /// 用户手挑一张歌单封面。
    ///
    /// ⚠️ **压 JPEG 这一步在本层做**（`CoverImageWriter`，`Core/UI`）：像素是画布的活儿，
    /// `Data` 层只收字节。压不出来 → 变成人话。
    func setPlaylistCover(_ image: UIImage, playlistID: Playlist.ID) throws {
        guard let data = CoverImageWriter.jpegDataForCustomCover(image) else {
            throw PlaylistCoverError.cannotEncode
        }
        try covers.applyPicked(data, playlistID: playlistID)
    }

    /// 生成拼图封面（后台；回调主线程）。
    ///
    /// - success(`false`) = 歌单里没有带封面的歌。
    func generatePlaylistCover(
        playlistID: Playlist.ID,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        covers.generate(playlistID: playlistID, completion: completion)
    }

    /// 找出已经包含这批歌曲的歌单，用来给添加模式的行尾显示勾。
    func playlistsContainingAll(_ trackIDs: [Track.ID]) throws -> Set<Playlist.ID> {
        let required = Set(trackIDs)
        guard !required.isEmpty else { return [] }
        let memberships = try library.playlistMemberships(for: trackIDs)
        return memberships.reduce(into: Set<Playlist.ID>()) { result, entry in
            if entry.value.isSuperset(of: required) {
                result.insert(entry.key)
            }
        }
    }

    // MARK: - 私有 · 合成

    /// 库里的歌单 + 偏好 + 搜索词 → 一份列表内容。
    ///
    /// ⚠️ **先筛后排**：搜索是"把不相关的拿掉"，排序是"把剩下的排好"。
    /// 反过来的话，排序要去排那些马上就被丢掉的歌单 —— 白干。
    private static func makeSnapshot(
        _ playlists: [Playlist],
        counts: [Playlist.ID: Int],
        mode: PlaylistSortMode,
        direction: SortDirection,
        query: String
    ) -> Snapshot {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !trimmed.isEmpty

        // ① 筛：没在搜就一个不滤。两段走的是**同一遍** —— 理由见下。
        let visible = playlists.filter { !searching || matches($0, trimmed) }

        // 🔴 「最爱的歌曲」**不参与排序**（列表把它单摆一段、永远在最上面），
        // 但**参与搜索** —— 它也在上面那份 `visible` 里，搜不着一样被滤掉；
        // 不这么写的话，搜「周杰伦」还会看见一行「最爱的歌曲」。
        let favorites = visible.first { $0.isFavorites }

        // ② 排：只有用户歌单要排。
        let users = PlaylistSort.sorted(
            visible.filter { !$0.isFavorites },
            mode: mode,
            direction: direction
        )

        return Snapshot(
            favorites: favorites.map { makeRow($0, counts: counts) },
            users: users.map { makeRow($0, counts: counts) },
            foundNothing: searching && favorites == nil && users.isEmpty
        )
    }

    /// 这个歌单名里有没有这段字。
    ///
    /// ⚠️ 歌单**没有全文索引**（曲库那套拼音 / 首字母是给歌用的），所以这儿就是最朴素的
    /// 子串比较、忽略大小写 —— 只有这一处，别在页面里再写一遍。
    private static func matches(_ playlist: Playlist, _ query: String) -> Bool {
        playlist.name.localizedCaseInsensitiveContains(query)
    }

    /// 数据 → 一行展示内容。
    private static func makeRow(_ playlist: Playlist, counts: [Playlist.ID: Int]) -> PlaylistRow {
        PlaylistRow(
            id: playlist.id,
            title: playlist.name,
            // ⚠️ 查不到就是 0 首：空歌单、以及「最爱的歌曲」在关联表里本来就没有行
            //（它那一份由数据层补好，见 `LibraryStore.playlistTrackCounts`）。
            subtitle: "\(counts[playlist.id] ?? 0) 首歌",
            cover: PlaylistCover(playlist),
            isFavorites: playlist.isFavorites
        )
    }
}

// MARK: - 搜索词的接收方

/// 搜索词的接收方 —— 转发那条线在 `SearchTextForwarding` 的默认实现里（全工程一份）。
extension PlaylistsViewModel: SearchTextSetting {}

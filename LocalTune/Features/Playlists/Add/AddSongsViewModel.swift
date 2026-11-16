import Foundation
import RxRelay
import RxSwift

/// 「添加歌曲到歌单」页的页面状态 —— **未加入当前歌单的歌曲列表 + 勾选**。
///
/// 🔴 它不认识界面：不持有页面、不碰表格、不拼导航栏。页面只做三件事：
/// 订阅快照 → 渲染 → 把用户动作转回来（跟曲库页、歌单页、详情页同一条架构）。
///
/// ## 这一页跟别的页**最不一样**的一点：点行不写库
///
/// 用户点一行只是**勾上 / 取消勾**，写库只在「完成」那一下发生一次。
/// 所以勾选是**这一页自己的状态**（下面那个 `selectionRelay`），不是库推来的 ——
/// 库里推来的只有"这个歌单**本来**有哪些歌"（用来算差集）。
///
/// ⚠️ 参考实现（`AddSongsToPlaylistViewController`）是**点一下就写库**的 ——
/// 那是个真毛病：用户点「取消」的本意是"算了别加"，可歌早就进去了（取消也退不回来）。
/// **它不跟**。攒着、「完成」才写，取消才是真的取消。
///
/// ## 数据从哪来
///
/// 三条库里的流 + 两个自己的开关：
/// - `LibraryStore.allTracks` —— **整个曲库**，之后排除已经在这个歌单里的那些；
/// - `LibraryStore.playlistTracks(_:)` —— 这个歌单**本来**有哪些歌，用来做排除条件；
/// - `AppSettings.showAudioQualityChanges` —— 音质开关；
/// - 搜索词、以及用户勾出来的那一份。
///
/// ## 列表顺序
///
/// **照库推来的顺序**（入库先后），不排
/// （`PlaylistAddSongController` 里 `results` 就是 `Realm.objects(Song.self)` 原样倒出来）。
/// 这一页是"从一堆歌里挑几首"，按标题重排一遍反而让用户每次进来看到的位置都不一样。
///
/// ## 线程
///
/// **全在主线程**：库那几条流用 `.async(onQueue: .main)` 启动（见 `LibraryStore`），
/// 开关流也是，页面动作本来就是主线程来的。⇒ 下面几个 `var` **不需要锁**。
final class AddSongsViewModel {

    // MARK: - 快照

    /// 界面需要的内容都在这里。
    struct Snapshot: Equatable {

        /// 列表里要画的行 —— 当前歌单尚未加入的歌曲（再按搜索筛过），顺序照库推来的。
        var songs: [SongRow]

        /// 这一列的歌本身 —— **顺序和 `songs` 一模一样**。
        ///
        /// ⚠️ 页面点一行时要拿 id 回来翻勾；`SongRow` 是展示投影、认不出勾选态。
        var tracks: [Track]

        /// 现在勾着哪些 —— **点了「完成」之后这个歌单里会有的那些**。
        ///
        /// ⚠️ 它**不是**"这个歌单现在有哪些歌"：用户还没动过手时两者相同，
        /// 动过之后以他勾的为准（见 `selectionRelay`）。
        var selectedIDs: Set<Track.ID>

        /// 正在搜、但一条都没搜到 —— 页面据此弹一次「未找到相关歌曲」。
        ///
        /// ⚠️ 它是**状态**、不是事件：页面自己去认"从 false 翻成 true 的那一刻"。
        var foundNothing: Bool
    }

    /// 列表内容：库一变、音质开关一变、搜索词一变、勾选一变，就推一份新的。
    let snapshot: Observable<Snapshot>

    /// 库读不出来（观察断了、文件坏了…）—— 页面订阅它、**弹一次提示**。
    ///
    /// ⚠️ 错误**不会自己恢复**：观察断了就是断了（见 `LibraryStore` 顶上那段）。
    let errors: Observable<Error>

    /// 用户是否改过这一页的暂存选择。
    ///
    /// 没有改动时允许系统下拉关闭；有改动时由页面拦住并询问是否保存添加。
    var hasUnsavedChanges: Bool {
        latestSelectedIDs != memberIDs
    }

    /// 这一页在往**哪个**歌单里挑歌。
    ///
    /// ⚠️ 是 `internal` 而不是 `private`：歌单详情页那个「加号」要用它请路由弹页 ——
    /// 页面自己不存第二份（id 只有一个出处）。
    let playlistID: Playlist.ID

    // MARK: - 依赖

    private let library: LibraryStore
    private let settings: AppSettings

    // MARK: - 我们自己的状态

    /// 用户勾出来的那一份；`nil` ＝ **还没动过手**。
    ///
    /// 🔴 为什么是可选的、而不是一上来就把歌单成员灌进来：成员是**异步**拿到的，
    /// "灌的那一下"会多推一份快照 —— 界面先画一遍"一首都没勾"，再翻成"已加入的都勾上"，
    /// 看着就是闪一下（而且是往错的方向闪）。用 `nil` 把"还没动过"显式拿出来，
    /// 第一次算快照时直接就是对的（见 `snapshot` 的合成）。
    private let selectionRelay = BehaviorRelay<Set<Track.ID>?>(value: nil)

    /// 搜索 —— 搜索框里敲的字进去，**命中的那些歌**出来（防抖 ＋ 算在别的线程上）。
    ///
    /// ⚠️ **不存盘**：搜索是一次性的，这一页关掉就该清空。
    ///
    /// 🔴 **"哪几首"和"在不在搜"同源**（都从这份 `Result` 上读）—— 两者要是分开走，
    /// 就会出现"框里写着 A、列表按 B 筛"那一拍（见 `LibrarySearch` 顶上那段）。
    private let search: LibrarySearch

    /// 这个歌单**本来**有哪些歌 —— 「完成」时算差集要用（要加哪些、要去掉哪些）。
    ///
    /// ⚠️ 拿不到时它是空的：那会儿「完成」只会**加**、不会误删（见 `save()`）。
    private var memberIDs: Set<Track.ID> = []

    /// 最近一次算出来的勾选 —— 「点一行」要拿它翻（不能直接读 `selectionRelay`：
    /// 用户还没动过手时它是 `nil`，那会儿的勾选是成员集合算出来的）。
    private var latestSelectedIDs: Set<Track.ID> = []

    /// 最近一次列表的**顺序** —— 「完成」按它排新加的歌（见 `save()`）。
    private var latestTrackIDs: [Track.ID] = []

    private let disposeBag = DisposeBag()

    // MARK: - 建立

    init(playlistID: Playlist.ID, library: LibraryStore, settings: AppSettings) {
        self.playlistID = playlistID
        self.library = library
        self.settings = settings
        search = LibrarySearch(library: library)
        errors = library.errors

        // 这个歌单本来有哪些歌。
        //
        // ⚠️ `share(replay: 1)`：下面**两处**要用它（合成快照 + 记住成员）——
        // 不共享的话底层会订两遍、这个歌单的曲目被查两次、被观察两次。
        let members = library.playlistTracks(playlistID)
            .map { Set($0.map(\.id)) }
            .share(replay: 1)

        // 五个来源合成一份：全库 + 这个歌单本来的成员 + 音质开关 + 搜索词 + 用户勾的。
        //
        // ⚠️ 用带 `resultSelector` 的那个重载，不要 `.map` 之后再拆元组。
        //
        // 🔴 **搜索在这一层筛，页面不知道"在不在搜"**：筛完的那一列**就是**快照里的那一列 ——
        // 列表画什么、点一行翻的是哪一首，一处口径出两样东西（跟曲库页、详情页同一条）。
        //
        // 🔴 **音质 / 播放次数显示开关也是合成的来源**：翻一下，每一行的
        // `quality` / `playCount` 跟着有 / 没有。
        let shared = Observable.combineLatest(
            library.allTracks,
            members,
            settings.showAudioQualityChanges,
            settings.showPlayCountChanges,
            search.result,
            selectionRelay,
            library.favoriteTrackIDs
        ) { tracks, memberIDs, showQuality, showPlayCount, searchResult, selection, favoriteIDs in
            let matched = Self.matched(
                tracks,
                memberIDs: memberIDs,
                search: searchResult
            )
            let searching = searchResult.isSearching
            return Snapshot(
                songs: matched.map {
                    SongRow.make(
                        $0,
                        showQuality: showQuality,
                        showPlayCount: showPlayCount,
                        isFavorite: favoriteIDs.contains($0.id)
                    )
                },
                tracks: matched,
                // 用户动过手就听他的；没动过，勾选就是"这个歌单本来有的那些"。
                selectedIDs: selection ?? memberIDs,
                foundNothing: searching && matched.isEmpty
            )
        }
        // 🔴 `share(replay:)` 不是为了提速，是**必需**：下面还要再订一次（记住最新那份勾选）。
        .share(replay: 1)

        snapshot = shared

        // 记住最近一次算出来的勾选与顺序 —— 「点一行」和「完成」都拿它俩干活。
        // ⚠️ 顺序要一起记：`Set` 是无序的，写库时直接把它丢给 `add`，新歌在歌单里的先后就是随机的。
        shared
            .subscribe(onNext: { [weak self] in
                self?.latestSelectedIDs = $0.selectedIDs
                self?.latestTrackIDs = $0.tracks.map(\.id)
            })
            .disposed(by: disposeBag)

        // 记住这个歌单本来的成员 —— 「完成」算差集用。
        members
            .subscribe(onNext: { [weak self] in self?.memberIDs = $0 })
            .disposed(by: disposeBag)
    }

    // MARK: - 勾选

    /// 点一行 —— **勾上 / 取消勾**（翻一下）。写库不在这儿（见「完成」那颗键 → `save()`）。
    ///
    /// ⚠️ 起点是 `latestSelectedIDs`（最近一次算出来的那份），不是 `selectionRelay.value` ——
    /// 用户第一次点的时候 relay 还是 `nil`，从 `nil` 变出去会把已经在这个歌单里的那些全丢掉。
    func toggle(id: Track.ID) {
        var ids = latestSelectedIDs
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        selectionRelay.accept(ids)
    }

    // MARK: - 保存

    /// 「完成」—— **到这一刻才把勾选写进歌单**。
    ///
    /// 干两件事，**都用数据层现成的那两条写规则**（`add` / `remove`），不另起一套：
    /// - 原来在、现在没勾的 ⇒ `remove`；
    /// - 原来没有、现在勾上的 ⇒ `add`。
    ///
    /// ⚠️ **为什么不是"先清空再按顺序加一遍"**：那会连带把歌单里原有的**位置顺序**整个打乱，
    /// 而用户在这一页**没动过顺序**（他只挑歌）；而且中途任何一步失败，歌单就少了一批歌。
    /// 走差集的话，没被碰过的那些歌连位置都不动。
    ///
    /// - Throws: 写库失败时抛出 —— 页面负责把它变成一句给用户看的话（并且**不退页**，
    ///   不然用户勾了半天，一失败就什么都没了还看不见原因）。
    func save() throws {
        let selected = latestSelectedIDs
        let removals = memberIDs.subtracting(selected)
        let additions = selected.subtracting(memberIDs)

        // ⚠️ 空的那一边不落库 —— 走一趟空写会白白推一次库变更（页面那边就是一次整表刷新）。
        if !removals.isEmpty {
            try library.remove(trackIDs: Array(removals), from: playlistID)
        }
        if !additions.isEmpty {
            // 🔴 **新加的那些要按"列表里从上到下的顺序"给 `add`**：`Set` 是无序的，
            // 直接丢过去的话，用户勾的那几首新歌在歌单里的先后是随机的 ——
            // 他回到歌单页看到的顺序和刚才在这一页看到的不一样。
            //
            // ⚠️ 加的是**勾选全体**、不是"当前列表里看得见的那些"：用户在搜索状态下勾的歌，
            // 清掉搜索之前列表里还有，之后就没有了 —— 按列表算会把那些歌**悄悄丢掉**
            //（用户明明勾了，完成之后却没进去）。列表里看不见的那些接在后面（按 id 排一下，
            // 它们本来就没有"位置"可言，但总得有个确定的先后）。
            let ordered = latestTrackIDs.filter(additions.contains)
                + additions.subtracting(latestTrackIDs).sorted()
            try library.add(trackIDs: ordered, to: playlistID)
        }
    }

    // MARK: - 搜索

    /// 搜索框里的字变了 —— 页面只转发，**命中怎么算不归它管**。
    func setSearchText(_ text: String) {
        search.accept(text)
    }

    // MARK: - 私有

    /// 在全库里挑出**尚未加入当前歌单、且命中关键词**的歌（顺序照旧）。
    ///
    /// ⚠️ **排除已加入歌曲先于搜索**：搜索结果里也不能重新出现已经在歌单里的歌。
    ///
    /// ⚠️ **排除这一件事是这一页的规矩**（曲库页 / 详情页没有它）—— 所以留在这一页；
    /// 而"命中怎么算"不在这一层（见 `LibrarySearch` / `LibraryStore.matchingTrackIDs`）。
    /// 参考实现是自己比 `title` / `artist` / `album` 三段的子串 —— 那是**另一套规则**，
    /// 照它抄的话同一个词在曲库页搜得到、在这一页搜不到。**不跟。**
    private static func matched(
        _ tracks: [Track],
        memberIDs: Set<Track.ID>,
        search: LibrarySearch.Result
    ) -> [Track] {
        let unadded = tracks.filter { !memberIDs.contains($0.id) }
        guard search.isSearching else { return unadded }
        return search.matching(unadded)
    }
}

// MARK: - 搜索词的接收方

/// 搜索词的接收方 —— 转发那条线在 `SearchTextForwarding` 的默认实现里（全工程一份）。
extension AddSongsViewModel: SearchTextSetting {}

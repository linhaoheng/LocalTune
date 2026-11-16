import Foundation
import GRDB
import RxRelay
import RxSwift

/// 曲库的**唯一出口**：增删改查 + 实时观察。
///
/// 上层（ViewModel / 页面）只跟它打交道，**不许自己碰 GRDB** —— 它是那道墙：
/// 数据库一旦漏到页面，以后改表结构就得改一片页面。
///
/// ## 「实时观察」怎么做的
///
/// 做法：GRDB 的 `ValueObservation` 盯住一段查询，**库一变就重跑**，结果推给 RxSwift 的 relay。
/// 两个要点是踩出来的经验：
///
/// 1. **首次回调是异步的** —— 启动时还要**同步读一次**，否则首屏会闪一下空列表。
/// 2. 观察出错时 `ValueObservation` 就**停了**，不会自己恢复 —— 所以错误要转出去
///    （见 `errors`），让上层能提示用户，而不是悄悄永远不更新。
///
/// ## 线程
///
/// - **SQLite 读写**全在 GRDB `DatabaseWriter` 自带的串行队列上（`writer.read/write` 内部排队），
///   不需要自己加锁；多条读写不会并发。
/// - **观察回调**（`ValueObservation`）用 `.async(onQueue: .main)` 启动，
///   所以推到 relay 的那份快照**永远在主线程上** —— 页面直接订阅就能刷新界面。
/// - **同步查询方法**（`track(id:)` / `upsert` / `delete` …）谁调谁阻塞：
///   它们在 GRDB 队列上跑完才返回；在主线程调会短暂卡主线程，
///   所以**批量导入**这种重操作不在主线程调（在 `ImportService` 里走后台）。
///
/// ## 三条架构决定（这一类的通例，别再塞回来）
///
/// | 常见做法 | 我们 | 为什么 |
/// |---|---|---|
/// | 一个 store 把导入 / 封面 / 歌词 / 目录全塞身上 | 只管道**曲库数据** | 按规范分给 `Data/Import/`、`Data/Artwork/`、`Playback/Lyrics/` |
/// | 自己开库、`AppServices.shared` 单例 | **从外面拿连接** | `AppServices` 是唯一 new 服务的地方，页面里不许出现 `.shared` |
/// | 对外暴露 `BehaviorRelay`（外面能往里写） | 只暴露**只读的 `Observable`** | 外面只该订阅，不该能往里塞数据 |
/// | 模型与行记录分两层 ⇒ 手写 SQL 转换 | 用 GRDB 的 Record API | 我们模型本身就是 Record，多一层转换只是白写 |
final class LibraryStore {

    // MARK: - 依赖

    /// 谁开的库谁负责持有，这里只借用。
    private let writer: any DatabaseWriter

    /// 观察的凭据 —— 持有它，观察才活着；置空就等于停掉。
    private var observation: AnyDatabaseCancellable?

    // MARK: - 对外：只读的流

    /// 曲库里所有的歌。库一变就推新的一份。
    ///
    /// ⚠️ **这里不按显示方式排** —— "按什么排"是页面的决定（ViewModels 的事），
    /// 数据层只管把库里有什么推出去。歌单那边不同（见 `allPlaylists`）。
    ///
    /// 但推出去的顺序是**确定的「入库先后」**（按 `rowid`）：它不是一种排序方式，
    /// 而是给页面的一个确定原始顺序 —— 页面按导入时间 / 标题排到**并列**时靠它兜底。
    /// 详见 `fetchSnapshot`。
    let allTracks: Observable<[Track]>

    /// 所有歌单。**按手动顺序**（`sortIndex`）排好 ——
    /// 这个顺序是数据本身的一部分（用户拖出来的），不是"显示时怎么排"，所以在这里排。
    let allPlaylists: Observable<[Playlist]>

    /// 每个歌单**有几首歌** —— 列表每一行都要显示它。
    ///
    /// 🔴 为什么要单开一条流、而不是让每一行自己去查：列表 N 行就是 N 次查询，
    /// 而且每次库一变都得重来一遍。这里**一条 `GROUP BY` 算完**，页面直接查表。
    ///
    /// ⚠️ **最爱那一份也算好了**（＝收藏数）：它的成员不在关联表里，
    /// 这件事只有数据层知道 —— 页面不该为它写一个 `if`。
    let playlistTrackCounts: Observable<[Playlist.ID: Int]>

    /// 被收藏的那些歌的 id。
    ///
    /// 用 id 集合而不是 `Favorite` 对象：列表要判断"这一行收藏没有"，拿到 id 集合做一次
    /// `contains` 就够，不必为每行的收藏单独查一次。
    let favoriteTrackIDs: Observable<Set<Track.ID>>

    /// 观察断了的时候会收到错误（库读不出来、文件坏了…）。
    ///
    /// ⚠️ **出错之后不会自动恢复** —— 上层收到它就该提示用户，别再等下一次更新。
    ///
    /// 🔴 **交付在主线程**（订阅方是页面：`bindLibraryErrors` 里直接碰 `HUD`）——
    /// 见 `init` 里那一句 `observe(on:)`，别以为"它本来就在主线程上"。
    let errors: Observable<Error>

    private let tracksRelay = BehaviorRelay<[Track]>(value: [])
    private let playlistsRelay = BehaviorRelay<[Playlist]>(value: [])
    private let trackCountsRelay = BehaviorRelay<[Playlist.ID: Int]>(value: [:])
    private let favoritesRelay = BehaviorRelay<Set<Track.ID>>(value: [])
    private let errorRelay = PublishRelay<Error>()

    // MARK: - 建立

    /// 建好之后立刻：**同步读一次**（首屏不空）→ **开启观察**。
    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        allTracks = tracksRelay.asObservable()
        allPlaylists = playlistsRelay.asObservable()
        playlistTrackCounts = trackCountsRelay.asObservable()
        favoriteTrackIDs = favoritesRelay.asObservable()
        // 🔴 **交付钉在主线程**：`errorRelay` 的 accept 点不都在主线程上 ——
        // 搜索那次读库现在跑在 `LibrarySearch` 自己的队列上（`matchingTrackIDs` 的 catch）。
        // 而订阅这条流的是页面（`HUD.showMessage`）。⇒ 一条流一个交付线程，写在自己的出口上，
        // 跟上面 `allTracks` 那条用 `.async(onQueue: .main)` 是同一个口径。
        errors = errorRelay.asObservable()
            .observe(on: MainScheduler.instance)

        try loadOnce()
        startObserving()
    }

    // MARK: - 查（一次性，不是流）

    /// 内存里这一刻的曲目快照 —— Intent / 装配同步读，不另开一次 DB。
    ///
    /// ⚠️ 跟 `allTracks` 同源（`tracksRelay`）；首屏在 `loadOnce` 之后就不会是空数组占位。
    var tracksNow: [Track] { tracksRelay.value }

    /// 内存里这一刻的歌单快照（同上）。
    var playlistsNow: [Playlist] { playlistsRelay.value }

    /// 按 id 取一首歌（进详情页时用）。
    func track(id: Track.ID) throws -> Track? {
        try writer.read { db in try Track.fetchOne(db, key: id) }
    }

    /// 取一个歌单里的歌，**按歌单里的位置排好**（不是按导入时间、也不是按歌名）。
    ///
    /// ⚠️ **`position` 后面必须吊一个 `rowid`**：`position` 只保证"号码小的在前"，
    /// 号码可能重复（历史数据、或者别处写进去的行）；两首号码一样时**先后是不确定的**
    /// —— 表现就是"同一个歌单打开两次，顺序不一样"。
    ///
    /// `rowid` 是 SQLite 的隐藏列，语义正好是「入库先后」，零成本 —— 跟 `fetchSnapshot`
    /// 里给列表兜底用的是同一招。索引 `idx_playlist_tracks_order` 建在 `(playlist_id, position)` 上，
    /// 而 `rowid` 本来就是索引条目的最后一级，所以这条排序**不会让索引失效**。
    func tracks(in playlistID: Playlist.ID) throws -> [Track] {
        try writer.read { db in try Self.fetchPlaylistTracks(db, playlistID: playlistID) }
    }

    /// 查询一批歌曲分别属于哪些歌单 —— 给「歌曲页多选 → 添加到播放列表」用。
    ///
    /// 一次读关联表和收藏表，不让歌单选择页按行逐个查库。
    func playlistMemberships(for trackIDs: [Track.ID]) throws -> [Playlist.ID: Set<Track.ID>] {
        let selected = Set(trackIDs)
        guard !selected.isEmpty else { return [:] }
        return try writer.read { db in
            // 关联表里的 playlist_id 是 TEXT；这里直接读字符串，避免把 UUID 文本
            // 交给 PlaylistTrack 的整行解码器，导致 RowDecodingError。
            let rows = try Row.fetchAll(db, sql: """
                SELECT "playlist_id", "track_id"
                FROM "playlist_tracks"
                """)
            var memberships: [Playlist.ID: Set<Track.ID>] = [:]
            for row in rows {
                guard let rawPlaylistID: String = row["playlist_id"],
                      let playlistID = UUID(uuidString: rawPlaylistID),
                      let trackID: Track.ID = row["track_id"],
                      selected.contains(trackID) else { continue }
                memberships[playlistID, default: []].insert(trackID)
            }

            let favoriteIDs = try Favorite.fetchAll(db, keys: Array(selected)).map(\.id)
            if !favoriteIDs.isEmpty {
                memberships[Playlist.favoritesID] = Set(favoriteIDs)
            }
            return memberships
        }
    }

    /// 这个歌单里的歌 —— **一条流**（加歌 / 移歌 / 改顺序 / 歌本身改了，都会推一份新的）。
    ///
    /// 🔴 **为什么必须有它**：上面那条一次性查询推不动界面 —— 用户在别处往这个歌单加了首歌，
    /// 详情页得自己跟着变。而现有的五条流里没有"某个歌单的成员"这一条
    ///（`allPlaylists` 只有歌单本身、`playlistTrackCounts` 只有数字）。
    ///
    /// ⚠️ **自持一条独立的观察**（订阅时起、退订时停）—— 不复用 `observation` 那个字段：
    /// 那是整份快照的观察，共用一条的话，两个读者会互相把对方的观察掐掉。
    ///
    /// ⚠️ fetch 里**按 `kind` 分了两支**（读关联表还是读收藏表）—— 这是**非恒定区域**，
    /// 所以只能用 `.tracking { }`，不能用 `trackingConstantRegion`（那样只会盯住先走的那一支）。
    func playlistTracks(_ playlistID: Playlist.ID) -> Observable<[Track]> {
        Observable.create { [weak self] observer in
            guard let self else {
                observer.onCompleted()
                return Disposables.create()
            }

            // 🔴 **先同步读一次** —— 跟 `loadOnce()` 是同一个姿势、同一个理由：
            // `ValueObservation` 的第一次回调是**异步**的，只靠它的话订阅那一刻**没有值**。
            //
            // 为什么这条流非补不可：详情页把「歌单本身 + 它的曲目 + 音质开关」三样交给
            // `combineLatest` 合成一份快照 —— 那三样里**只有这一条没有初值**，
            // 它不吭声整份快照就出不来。表现就是"点进歌单先空一下，过一拍才刷出来"。
            //
            // ⚠️ 读失败照样转出去（跟观察断了同一个口径），别悄悄吞掉 ——
            // 不然页面只会"永远空着"，而没有任何地方知道为什么。
            do {
                observer.onNext(
                    try self.writer.read { try Self.fetchPlaylistTracks($0, playlistID: playlistID) }
                )
            } catch {
                self.errorRelay.accept(error)
            }

            let observation = ValueObservation
                .tracking { db in try Self.fetchPlaylistTracks(db, playlistID: playlistID) }
                .start(
                    in: self.writer,
                    // 回主线程：订阅方（页面）都在主线程上刷新界面。
                    scheduling: .async(onQueue: .main),
                    onError: { [weak self] error in
                        // 观察断了就断了（跟整库那条一个口径）—— 转出去让页面提示，别悄悄不出声。
                        self?.errorRelay.accept(error)
                    },
                    onChange: { observer.onNext($0) }
                )
            return Disposables.create { observation.cancel() }
        }
    }

    /// 一个歌单里有哪些歌、按什么顺序 —— **一次性查询和上面那条流共用这一份**。
    ///
    /// 🔴 **「最爱的歌曲」那一行没有关联记录** —— 它的成员就是收藏表。
    /// 分派只在这一处：列表、详情页、播放都只管调这个方法，谁都不用知道这件事。
    private static func fetchPlaylistTracks(_ db: Database, playlistID: Playlist.ID) throws -> [Track] {
        guard let playlist = try Playlist.filter(Playlist.Columns.id(playlistID)).fetchOne(db) else {
            return []
        }
        if playlist.isFavorites { return try favoriteTracks(db) }

        let entries = try fetchPlaylistTrackEntries(db, playlistID: playlistID)
        let tracks = try Track.fetchAll(db, keys: entries.map(\.trackID))
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        // 用 entries 的顺序还原：`fetchAll(keys:)` 回来的是**库里**的顺序，不是歌单的顺序。
        return entries.compactMap { byID[$0.trackID] }
    }

    /// 读取普通歌单的关联记录。
    ///
    /// `playlist_id` 在 SQLite 中是 TEXT；不要用 `PlaylistTrack.fetchAll` 直接解码 UUID，
    /// 否则普通歌单一旦有记录，观察重读时会触发 `GRDB.RowDecodingError`。
    private static func fetchPlaylistTrackEntries(
        _ db: Database,
        playlistID: Playlist.ID
    ) throws -> [PlaylistTrack] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT "track_id", "position"
            FROM "playlist_tracks"
            WHERE "playlist_id" = ?
            ORDER BY "position", rowid
            """, arguments: [playlistID.uuidString])
        return rows.compactMap { row in
            guard let trackID: Track.ID = row["track_id"],
                  let position: Int = row["position"] else { return nil }
            return PlaylistTrack(
                playlistID: playlistID,
                trackID: trackID,
                position: position
            )
        }
    }

    /// 收藏的那些歌，**按收进来的先后**（早收的在前）。
    ///
    /// ⚠️ `added_at` 后面吊一个 `rowid`：老数据的 `added_at` 可能是 `NULL`（＝不知道什么时候收的），
    /// 而 `NULL` 之间、以及同一毫秒收进来的那些，先后得有个确定的说法 —— 跟别处一个道理。
    private static func favoriteTracks(_ db: Database) throws -> [Track] {
        let ids = try Favorite
            .order(Column("added_at"), Column.rowID)
            .fetchAll(db)
            .map(\.id)
        let tracks = try Track.fetchAll(db, keys: ids)
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// 按 id 取一个歌单（详情页要用）。
    func playlist(id: Playlist.ID) throws -> Playlist? {
        try writer.read { db in
            try Playlist.filter(Playlist.Columns.id(id)).fetchOne(db)
        }
    }

    /// 这首歌在哪些歌单里（删歌前提示"它还在 3 个歌单里"用）。
    func playlistsContaining(trackID: Track.ID) throws -> [Playlist] {
        try writer.read { db in
            let playlistIDs = try PlaylistTrack
                .filter(PlaylistTrack.Columns.trackID == trackID)
                .fetchAll(db)
                .map(\.playlistID)

            // ⚠️ 这里**不能**用 `Playlist.fetchAll(db, keys:)` —— 拿 UUID 当 key 会编成二进制，
            // 跟库里存的大写字符串对不上（见 `Playlist.Columns.id(_:)`）。
            // 逐个查：歌单数量本来就少，这点开销可以忽略。
            let playlists = try playlistIDs.compactMap { id in
                try Playlist.filter(Playlist.Columns.id(id)).fetchOne(db)
            }
            return playlists.sorted { $0.sortIndex < $1.sortIndex }
        }
    }

    /// 一条搜索词**归一化之后**长什么样 —— **「什么算空词」只有这一处**。
    ///
    /// 🔴 为什么要单开这一处：搜索框那边（`LibrarySearch`）要判"在不在搜"（决定列表给全量
    /// 还是给筛选结果），这一层要判"空词就别碰库"—— 那是**同一个决定**。规则要是各抄一遍
    /// （`trimmingCharacters(…)` 写两处），改一处忘一处，就会出现**界面说"没在搜"、库却给了
    /// 命中**（或者反过来）——两边看着都对，谁也发现不了。⇒ 规则只写在这里，两边都调它。
    static func normalizedSearchQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按关键词搜曲库 —— **命中的那些歌的 id**。
    ///
    /// ## 命中规则**只有这一处**，就一条
    ///
    /// > 歌名 / 艺人 / 专辑里有**这段字**（子串），**或者**全文索引认得这个词。
    ///
    /// 两半各管一半，缺一不可：
    /// - **子串那一半**（`instr`）：中文是连着写的，用户敲「周杰」就该搜到「周杰伦」。
    ///   索引**做不到**这件事 —— FTS5 默认分词器把一串汉字当成**一个整词**；
    /// - **索引那一半**（`track_search`）：拼音 / 首字母 —— 子串比不出来。只给拉丁字母用。
    ///
    /// ⚠️ **汉字不进索引**：搜的时候再转拼音，「周」会中「州 / 粥」。歌词也不在索引里 ——
    /// 列表只显示标题 / 艺人 / 专辑，搜歌词会冒出脸上没这个字的歌。这里是三字段子串；
    /// primuse 有汉字不转拼音、不查拼音表。
    ///
    /// ⚠️ **不许在别处再写一套"内存里比几个字段"**：同一个决定做两遍，两套规则迟早会飘
    /// （改了一处忘了另一处，而两边的结果都"看着像对的"）。命中怎么算，只有这里知道。
    ///
    /// ⚠️ 读失败时**把错误送到 `errors` 那条流**、返回空集合 —— **不抛**：
    /// 调用方在一个不能抛的地方（`SongsViewModel` 的合成流里）。而"曲库读不出来"本来就归
    /// 那条流管（见 `LibraryUnavailableViewController` 顶上那段）。
    func matchingTrackIDs(for query: String) -> Set<Track.ID> {
        // 「什么算空词」不在这儿 —— 走唯一那条规则（`normalizedSearchQuery`）。
        let trimmed = Self.normalizedSearchQuery(query)
        guard !trimmed.isEmpty else { return [] }

        do {
            return try writer.read { db in
                let byText = try String.fetchAll(db, sql: """
                    SELECT "id" FROM "tracks"
                    WHERE instr(lower("title"), lower(?1)) > 0
                       OR instr(lower("artist"), lower(?1)) > 0
                       OR instr(lower("album"), lower(?1)) > 0
                    """, arguments: [trimmed])

                guard let terms = Self.indexTerms(for: trimmed) else { return Set(byText) }
                let byIndex = try String.fetchAll(db, sql: """
                    SELECT "tracks"."id" FROM "track_search"
                    JOIN "tracks" ON "tracks"."rowid" = "track_search"."rowid"
                    WHERE "track_search" MATCH ?
                    """, arguments: [terms])
                return Set(byText).union(byIndex)
            }
        } catch {
            errorRelay.accept(error)
            return []
        }
    }

    // MARK: - 增

    /// 批量写入歌曲 —— **已经在库里的按 id 顶掉**（同一个 id 就是同一首歌）。
    ///
    /// 导入和重新扫描都走它：文件删了又导入回来时，顶掉那行旧记录，收藏和歌单跟着保留。
    func upsert(_ tracks: [Track]) throws {
        try writer.write { db in
            for track in tracks {
                // save = 主键已存在就改、不存在就插。
                try Self.withSearchKeysFilled(track).save(db)
            }
        }
    }

    /// 库里指纹对上的行。空指纹不查 —— 老行还没补哈希，对空串会把整库认成同一份。
    func tracks(withFingerprint fingerprint: String) throws -> [Track] {
        guard !fingerprint.isEmpty else { return [] }
        return try writer.read { db in
            try Track.filter(Column("fingerprint") == fingerprint).fetchAll(db)
        }
    }

    /// 写成一行。
    ///
    /// - 已经是库里这一行（同一路径 / 同一 id）⇒ 照写（刷新标签、补指纹）。
    /// - 新行且另有**活着的**同内容路径 ⇒ 不写，返回 `false`。
    ///
    /// 查 + 写在**同一事务**里：扫描 4 路并发时，第二个同内容的文件会看见第一个已经进库。
    ///
    /// ⚠️ **这一条只管 `tracks` 那一行** —— 内嵌歌词在侧表（`TrackLyrics`），
    /// 要一起写就用下面那条重载。「只补指纹」那条路（`saveFingerprint`）走这一条：
    /// 它**不该碰歌词**。
    func saveSkippingLiveDuplicate(_ track: Track) throws -> Bool {
        try writer.write { db in
            if try Self.isLiveDuplicate(track, in: db) {
                return false
            }
            try Self.withSearchKeysFilled(track).save(db)
            return true
        }
    }

    /// 写成一行，**并把这一趟读到的内嵌歌词一起写进侧表**（同一事务：要么都成、要么都不成）。
    ///
    /// - Parameter embeddedLyrics: 这一趟从文件标签里读到的歌词。
    ///   🔴 **`nil` ⇒ 删掉侧表那一行** —— 因为原来的语义就是「**照这一趟读到的写**」
    ///   （`TrackImporter` 拿 `metadata.lyrics` 直接顶掉原来那一列，读到 nil 就写 nil）。
    ///   这里保持**行为不变**，只是把那一列换了个存储。
    ///
    /// ⚠️ 「这一趟没读到」和「这首歌没有歌词」在这条路上**是同一件事**（都传 `nil`）——
    /// 跟 `TrackImporter` 里 `dateAdded` / `playCount` 那种「必须接着用库里的旧值」**不一样**：
    /// 歌词本来就属于"跟着文件标签走"的那一类。
    func saveSkippingLiveDuplicate(_ track: Track, embeddedLyrics: String?) throws -> Bool {
        try writer.write { db in
            if try Self.isLiveDuplicate(track, in: db) {
                return false
            }
            try Self.withSearchKeysFilled(track).save(db)
            try Self.storeLyrics(embeddedLyrics, for: track.id, in: db)
            return true
        }
    }

    /// 库里是不是**另有活着的**同内容行。查 + 判都收在这一处；在调用方那个事务里读，
    /// 才不会漏掉并发刚写进去的那一份。
    private static func isLiveDuplicate(_ track: Track, in db: Database) throws -> Bool {
        guard try Track.fetchOne(db, key: track.id) == nil, !track.fingerprint.isEmpty else {
            return false
        }
        let others = try Track
            .filter(Column("fingerprint") == track.fingerprint)
            .fetchAll(db)
        return ImportDuplicatePolicy.hasLiveDuplicate(
            ofRelativePath: track.path,
            otherPaths: others.map(\.path),
            isLive: MusicFileStore.fileExists(relativePath:)
        )
    }

    /// 打开文件、拷贝之前：库里已经有活着的同内容 ⇒ 不必再拷。
    func hasLiveDuplicate(fingerprint: String) throws -> Bool {
        let others = try tracks(withFingerprint: fingerprint)
        return ImportDuplicatePolicy.hasLiveDuplicate(
            ofRelativePath: "",
            otherPaths: others.map(\.path),
            isLive: MusicFileStore.fileExists(relativePath:)
        )
    }

    // MARK: - 「最爱的歌曲」

    /// 保证「最爱的歌曲」那一行在 —— **启动时调一次**（`AppServices` 装配时）。
    ///
    /// 幂等：有了就什么都不做。
    ///
    /// 🔴 **为什么它必须存在、又必须由代码补**：它不是用户建的歌单，而是**收藏这件事在列表里的
    /// 入口** —— 少了它，用户收藏的歌就只在播放页那颗心里看得见。所以它不能靠"用户自己建一个"，
    /// 也不能靠建库那一步塞进去（那样老库升级上来的就没有）。
    ///
    /// ⚠️ `sortIndex` 给 `-1`：**它不在用户歌单的手动序列里**（列表把它单摆一段），
    /// 给它一个比谁都小的值只是为了让"万一混在一起"时它排在最前。
    func ensureFavoritesPlaylist() throws {
        try writer.write { db in
            let existing = try Playlist
                .filter(Column("kind") == PlaylistKind.favorites.rawValue)
                .fetchOne(db)
            guard existing == nil else { return }

            let now = Date()
            try Playlist(
                id: Playlist.favoritesID,
                name: Playlist.favoritesName,
                kind: .favorites,
                artworkPath: nil,
                createdAt: now,
                sortIndex: -1
            ).insert(db)
        }
    }

    /// 建一个空歌单，排在现有歌单的**最后**。
    @discardableResult
    func createPlaylist(name: String) throws -> Playlist {
        try writer.write { db in
            let now = Date()
            let existing = try Playlist.fetchAll(db)
            let playlist = Playlist(
                id: UUID(),
                name: name,
                createdAt: now,
                sortIndex: (existing.map(\.sortIndex).max() ?? -1) + 1
            )
            try playlist.insert(db)
            return playlist
        }
    }

    /// 往歌单里加歌：**已经在里面的跳过**，新加的接在末尾。
    ///
    /// ⚠️ 往「最爱的歌曲」里加歌 = **收藏这些歌** —— 它的成员是收藏表，不是关联表（见 `tracks(in:)`）。
    func add(trackIDs: [Track.ID], to playlistID: Playlist.ID) throws {
        try writer.write { db in
            guard let playlist = try Playlist.filter(Playlist.Columns.id(playlistID)).fetchOne(db) else {
                return
            }
            if playlist.isFavorites {
                try Self.addToFavorites(db, trackIDs: trackIDs)
                return
            }

            let existing = try Self.fetchPlaylistTrackEntries(db, playlistID: playlistID)
            let alreadyIn = Set(existing.map(\.trackID))
            let wanted = trackIDs.filter { !alreadyIn.contains($0) }
            guard !wanted.isEmpty else { return }

            // ⚠️ 先剔掉**库里已经没有的** id。
            //
            // 外键确实会挡住不存在的 `track_id`，但那样是**整批写入失败** ——
            // 用户选了 100 首、其中 1 首刚好在别处被删掉，结果 99 首也加不进去。
            // 正确的结果是「能加的照加，那一首跳过」。
            let alive = Set(try Track.fetchAll(db, keys: wanted).map(\.id))

            var nextPosition = (existing.map(\.position).max() ?? -1) + 1
            for trackID in wanted where alive.contains(trackID) {
                try PlaylistTrack(playlistID: playlistID, trackID: trackID, position: nextPosition)
                    .insert(db)
                nextPosition += 1
            }
        }
    }

    /// 把这几首收进收藏 —— 「往最爱里加歌」落到的就是这一步。
    ///
    /// ⚠️ 先剔掉**库里已经没有的** id：外键确实会挡住不存在的 `track_id`，
    /// 但那样是**整批写入失败** —— 用户选了 100 首、其中 1 首刚好在别处被删掉，
    /// 结果 99 首也收不进来。正确的结果是「能收的照收，那一首跳过」。
    private static func addToFavorites(_ db: Database, trackIDs: [Track.ID]) throws {
        let alive = Set(try Track.fetchAll(db, keys: trackIDs).map(\.id))
        let now = Date()
        for trackID in trackIDs where alive.contains(trackID) {
            // 已经收过的跳过 —— 顺带保住了「第一次收进来」那个时间。
            try Favorite(id: trackID, addedAt: now).insert(db, onConflict: .ignore)
        }
    }

    // MARK: - 改

    /// 改一首歌（标签、封面路径、歌词……都走它）。
    func update(_ track: Track) throws {
        try writer.write { db in try Self.withSearchKeysFilled(track).update(db) }
    }

    // MARK: - 歌词（自定义层 ＋ 内嵌侧表）

    /// 存「编辑歌词」页写下的**自定义歌词**。
    ///
    /// 🔴 **只动 `customLyrics` 这一列，绝不碰内嵌歌词（侧表 `TrackLyrics`）/ 音频文件** ——
    /// 「改元数据 / 内嵌歌词」是**另一个入口**（`TrackEditor`）的职责。
    /// 传空串 ＝ **清掉自定义层**，显示时落回内嵌（`LyricsSourcePolicy`）。
    ///
    /// ⚠️ 这里**不做 trim / 归一**：编辑器给什么就存什么（原样保留用户的行内标记）。
    func saveCustomLyrics(_ text: String, for track: Track) throws {
        var copy = track
        copy.customLyrics = text
        try update(copy)
    }

    /// 一首歌的**内嵌歌词**（侧表）。`nil` ＝ 没有（＝侧表里没有那一行）。
    func lyrics(for id: Track.ID) throws -> TrackLyrics? {
        try writer.read { db in try TrackLyrics.fetchOne(db, key: id) }
    }

    /// 一批歌的内嵌歌词 —— **一条 `IN` 查询**，不是逐首。
    ///
    /// ⚠️ 为什么要批量：Siri 那条路（`SongEntity`）要把**全库**的歌都造出来，
    /// 逐首查就是 N+1。
    func lyrics(for ids: [Track.ID]) throws -> [Track.ID: TrackLyrics] {
        guard !ids.isEmpty else { return [:] }
        return try writer.read { db in
            let rows = try TrackLyrics.filter(ids.contains(Column("id"))).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        }
    }

    /// 单独写一首歌的**内嵌歌词** —— 「编辑歌曲信息页」改内嵌歌词那条路走它
    ///（导入那次是"顺带写"，走了 `saveSkippingLiveDuplicate` 的重载）。
    ///
    /// `nil` / 全空白 ⇒ **删掉侧表那一行**（没有行 ＝ 没有歌词）。
    func setLyrics(_ text: String?, for trackID: Track.ID) throws {
        try writer.write { db in
            try Self.storeLyrics(text, for: trackID, in: db)
        }
    }

    /// 歌单改名。
    ///
    /// 歌单不在了就**安静跳过**、不报错：那种情况几乎只可能是「在别处刚被删掉」，
    /// 而界面会从观察流立刻发现它没了、自己刷新 —— 不需要这里再报一次。
    ///
    /// ⚠️ 「最爱的歌曲」**可以改名** —— 挡的是删除。
    func rename(playlistID: Playlist.ID, to name: String) throws {
        try writer.write { db in
            guard var playlist = try Playlist.filter(Playlist.Columns.id(playlistID)).fetchOne(db) else {
                return
            }
            playlist.name = name
            try playlist.update(db)
        }
    }

    // MARK: - 歌单封面

    /// 🔴 **本类只碰库**。「先落盘 → 再写库 → 库没写成就撤文件」那套顺序
    /// 两头都碰，归 `Data/Artwork/PlaylistCoverService.swift` —— 那边是 `Data` 层的编排者
    /// （跟 `TrackImporter` / `TrackRemover` 同一角色）。这儿只留**一个**写 `artwork_path` 的窄口子。

    /// 把**当前封面**写进歌单那一行，返回**换下来**的旧路径（可能为 `nil`）。
    ///
    /// ⚠️ 手挑的图和生成的拼图**都走它** —— 封面只有这一个出处，界面不去磁盘上猜。
    /// 歌单不在了就抛错 —— 调用方据此撤掉刚落的那份文件。
    func writeCoverPath(_ newPath: String, playlistID: Playlist.ID) throws -> String? {
        var oldPath: String?
        try writer.write { db in
            guard var playlist = try Playlist.filter(Playlist.Columns.id(playlistID)).fetchOne(db) else {
                throw PlaylistCoverError.playlistMissing
            }
            oldPath = playlist.artworkPath
            playlist.artworkPath = newPath
            try playlist.update(db)
        }
        return oldPath
    }

    /// 收 / 取消收藏。
    ///
    /// ⚠️ 收藏时间**只在第一次收的那一刻填**：重复收同一首会被 `onConflict: .ignore` 挡掉，
    /// 所以「什么时候收的」不会被后来那次点击刷掉。
    func setFavorite(_ isFavorite: Bool, trackID: Track.ID) throws {
        try writer.write { db in
            if isFavorite {
                // 已经收藏过就别报错（快速连点两下会走到这儿）。
                try Favorite(id: trackID, addedAt: Date()).insert(db, onConflict: .ignore)
            } else {
                _ = try Favorite.deleteOne(db, key: trackID)
            }
        }
    }

    /// 播放次数 +1。
    ///
    /// 歌不在了就**安静跳过** —— 同上：界面会从观察流发现它没了。
    func increasePlayCount(trackID: Track.ID) throws {
        try writer.write { db in
            guard var track = try Track.fetchOne(db, key: trackID) else { return }
            track.playCount += 1
            try track.update(db)
        }
    }

    /// 重排歌单里的顺序 —— 传**完整的那个新顺序**。
    ///
    /// 传整个顺序比"把某一首挪到第几位"简单得多 —— 后者要重算中间所有歌的位置。
    ///
    /// 🔴 **这一趟必须让 `position` 变成「不重不漏的排列」**（0, 1, 2…）：
    /// 传进来的按新顺序排，**没传进来的接在后面**（留着它们原来的先后）。
    ///
    /// ⚠️ **不能让没传进来的各自维持原号码**（原来的契约是"不动"）：给 `A(0) B(1) C(2)`
    /// 传 `[C, A]`，C→0、A→1、而 B 还是 1 ⇒ **A 和 B 举同一个号码** ——
    /// 号码一样的两首谁在前是不确定的，读的时候怎么兜都救不回"顺序是错的"。
    ///
    /// 拖拽时传的本来就是完整列表 ⇒ 界面上看到的行为不变。
    func reorder(playlistID: Playlist.ID, orderedTrackIDs: [Track.ID]) throws {
        try writer.write { db in
            guard let playlist = try Playlist.filter(Playlist.Columns.id(playlistID)).fetchOne(db) else {
                return
            }

            // 「最爱的歌曲」没有关联表 —— 顺序落在收藏的 `added_at` 上（读的时候按它排）。
            if playlist.isFavorites {
                try Self.reorderFavorites(db, orderedTrackIDs: orderedTrackIDs)
                return
            }

            let existing = try Self.fetchPlaylistTrackEntries(db, playlistID: playlistID)
            guard !existing.isEmpty else { return }

            let byTrackID = Dictionary(uniqueKeysWithValues: existing.map { ($0.trackID, $0) })

            // 传进来的按给定顺序 —— 不在这个歌单里的 id 跳过（可能是别处刚加进来、
            // 或者已经被移走），重复出现的只认第一次。
            var ordered: [Track.ID] = []
            var taken: Set<Track.ID> = []
            for trackID in orderedTrackIDs
            where byTrackID[trackID] != nil && taken.insert(trackID).inserted {
                ordered.append(trackID)
            }
            // 没传进来的接在后面，保持它们原来的先后。
            let listed = Set(ordered)
            let unlisted = existing.map(\.trackID).filter { !listed.contains($0) }

            for (position, trackID) in (ordered + unlisted).enumerated() {
                guard var entry = byTrackID[trackID], entry.position != position else { continue }
                entry.position = position
                try entry.update(db)
            }
        }
    }

    /// 收藏顺序：按传入顺序重写 `added_at`（读收藏时 `ORDER BY added_at`）。
    private static func reorderFavorites(_ db: Database, orderedTrackIDs: [Track.ID]) throws {
        let existing = try Favorite.fetchAll(db)
        guard !existing.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        var ordered: [Track.ID] = []
        var taken: Set<Track.ID> = []
        for trackID in orderedTrackIDs where byID[trackID] != nil && taken.insert(trackID).inserted {
            ordered.append(trackID)
        }
        let listed = Set(ordered)
        let unlisted = existing.map(\.id).filter { !listed.contains($0) }
        let full = ordered + unlisted

        // 用递增时间钉死顺序；起点取现有最早时间，避免全挤在"现在"。
        let base = existing.compactMap(\.addedAt).min() ?? Date()
        for (index, trackID) in full.enumerated() {
            guard var favorite = byID[trackID] else { continue }
            let next = base.addingTimeInterval(TimeInterval(index))
            guard favorite.addedAt != next else { continue }
            favorite.addedAt = next
            try favorite.update(db)
        }
    }

    /// 按给定的顺序重写歌单的**手动序号** —— 列表页「手动排序」拖完之后调它。
    ///
    /// ⚠️ 传的是**完整的那个新顺序**（跟 `reorder` 同一条规矩）：只传"谁挪到第几位"的话，
    /// 中间那些歌的号码怎么变就没有一处说得清。
    ///
    /// ⚠️ 「最爱的歌曲」**不在这个序列里**（列表只对用户歌单排序）——
    /// 它不会被传进来，`sortIndex` 保持建的时候那个值。
    func applyPlaylistManualOrder(_ orderedIDs: [Playlist.ID]) throws {
        try writer.write { db in
            for (index, playlistID) in orderedIDs.enumerated() {
                guard var playlist = try Playlist.filter(Playlist.Columns.id(playlistID)).fetchOne(db),
                      playlist.sortIndex != index else { continue }
                playlist.sortIndex = index
                try playlist.update(db)
            }
        }
    }

    // MARK: - 删

    /// 删歌 —— **只删库里的记录**。
    ///
    /// ⚠️ **磁盘上的音乐文件不在这里删**：数据层不碰文件系统。
    /// 文件归 `ImportService` 管（它会按这些 id 找出对应文件再删）。
    /// 歌单里的关联和收藏条目会被外键自动清掉（`ON DELETE CASCADE`）。
    func delete(trackIDs: [Track.ID]) throws {
        try writer.write { db in
            _ = try Track.deleteAll(db, keys: trackIDs)
        }
    }

    /// 删歌单 —— 里面的歌**不受影响**，只是这层关联没了。
    ///
    /// ⚠️ **「最爱的歌曲」删不掉** —— 它是收藏那件事的入口，删了收藏就没地方看了。
    /// 挡在这儿而不是只挡在界面上，理由同 `rename`。
    ///
    /// ⚠️ 顺手清掉封面文件 —— 库行没了，那份文件就没人认领。
    func delete(playlistIDs: [Playlist.ID]) throws {
        var coverPaths: [String?] = []
        try writer.write { db in
            // ⚠️ 不用 `Playlist.deleteAll(db, keys:)` —— 拿 UUID 当 key 会编成二进制，
            // 跟库里存的大写字符串对不上（见 `Playlist.Columns.id(_:)`），那样一行都删不掉。
            for playlistID in playlistIDs {
                guard let playlist = try Playlist.filter(Playlist.Columns.id(playlistID)).fetchOne(db),
                      !playlist.isFavorites else { continue }
                coverPaths.append(playlist.artworkPath)
                _ = try Playlist.filter(Playlist.Columns.id(playlistID)).deleteAll(db)
            }
        }
        for coverPath in coverPaths {
            ArtworkStore.deletePlaylistCoverAssets(artworkPath: coverPath)
        }
    }

    /// 把歌从歌单里**移出去**（歌本身还在库里）。
    ///
    /// ⚠️ 从「最爱的歌曲」里移出去 = **取消收藏**（见 `tracks(in:)` 的分派）。
    func remove(trackIDs: [Track.ID], from playlistID: Playlist.ID) throws {
        try writer.write { db in
            guard let playlist = try Playlist.filter(Playlist.Columns.id(playlistID)).fetchOne(db) else {
                return
            }
            if playlist.isFavorites {
                _ = try Favorite.deleteAll(db, keys: trackIDs)
                return
            }

            for trackID in trackIDs {
                _ = try PlaylistTrack
                    .filter(PlaylistTrack.Columns.playlistID(playlistID)
                            && PlaylistTrack.Columns.trackID == trackID)
                    .deleteAll(db)
            }
        }
    }

    // MARK: - 文件不在本机（对账）

    /// 对账要的那一份投影：`id` ＋ 相对路径 ＋ **现在有没有**缺失标记。
    ///
    /// ⚠️ **单独读这三列**，不是把整首 `Track` 捞回来 —— 全库的 `lyrics` 进内存是纯浪费，
    /// 而对账只要这三个值（见 `LibraryReconcile.Entry`）。
    ///
    /// ⚠️ 「有没有标记」**让 SQL 直接算成一个布尔**（`IS NOT NULL`），不把那个日期读回来：
    /// 对账不需要知道是哪一刻，把 `Date` 解出来是白干一趟日期格式转换。
    func reconcileEntries() throws -> [LibraryReconcile.Entry] {
        try writer.read { db in
            try Row
                .fetchAll(db, sql: """
                    SELECT "id", "path", ("missing_since" IS NOT NULL) AS "is_missing"
                      FROM "tracks"
                    """)
                .map { row in
                    LibraryReconcile.Entry(
                        id: row["id"],
                        path: row["path"],
                        isMissing: row["is_missing"]
                    )
                }
        }
    }

    /// 把这些行标成「文件不在本机」。
    ///
    /// 🔴 SQL 里那句 `IS NULL` 是**保险**，不是把判据写了两遍：
    /// 判据在 `LibraryReconcile.Plan`（它决定「**要不要调**」），这一句保证「**调了也不白写**」——
    /// 已经是标记的行再写一次是 **0 行改动**，`sqlite3_update_hook` 就不发通知，观察不会白跑一趟。
    func markMissing(trackIDs: [Track.ID], at date: Date) throws {
        guard !trackIDs.isEmpty else { return }
        // `_ =`：`updateAll` 返回「改了几行」，这里不要 —— 但闭包会把它带出来，得显式丢。
        _ = try writer.write { db in
            try Track
                .filter(trackIDs.contains(Column("id")))
                .filter(Column("missing_since") == nil)
                .updateAll(db, [Column("missing_since").set(to: date)])
        }
    }

    /// 把标记清掉（文件回来了）。同上，`IS NOT NULL` 是保险。
    func clearMissing(trackIDs: [Track.ID]) throws {
        guard !trackIDs.isEmpty else { return }
        _ = try writer.write { db in
            try Track
                .filter(trackIDs.contains(Column("id")))
                .filter(Column("missing_since") != nil)
                .updateAll(db, [Column("missing_since").set(to: nil)])
        }
    }

    // MARK: - 私有 · 歌词

    /// 侧表的**唯一写口** —— 非空插/更新一行、空则删行（"没有行 ＝ 没有歌词"）。
    ///
    /// 🔴 收在这一处的原因：导入、重扫、编辑页三条路都要写它，规则要是各写一遍，
    /// 改一处忘一处 —— 迟早出现"这首没歌词、却躺着一行空的"。
    private static func storeLyrics(_ text: String?, for trackID: Track.ID, in db: Database) throws {
        if let normalized = normalizedLyrics(text) {
            try TrackLyrics(id: trackID, lyrics: normalized).save(db)
        } else {
            try TrackLyrics.filter(Column("id") == trackID).deleteAll(db)
        }
    }

    /// 空白歌词 ＝ 「没有」—— 判空**按 trim**，但**返回原文**（不 trim 掉用户的排版）。
    /// 口径与 `MetadataWriter.emptyToNil` 一致。
    private static func normalizedLyrics(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // MARK: - 私有 · 搜索

    /// 一个关键词 → 全文索引那半边的查询串，**都按前缀匹配**。
    ///
    /// 返回 `nil` ＝ 这个词在索引里没得搜（全是标点），只跑子串那一半。
    ///
    /// ⚠️ **只拿用户敲进来的字本身**。他打 `zjl` / `zhou`，索引里装的就是这些键，直接前缀命中。
    ///
    /// ⚠️ **有汉字就不走索引**：再转拼音，「周」会中「州」。歌名 / 艺人 / 专辑的汉字由子串那一半负责。
    ///
    /// ⚠️ **不再单独加一段"首字母"**：首字母缩写（`zjl`）本来就是索引那一列里的一个 token
    /// （见 `PinyinTransformer.searchKeys`），上面那一段已经能命中它 —— 再加一段是同一件事做两遍。
    ///
    /// ⚠️ 全是标点的关键词要在这里**挡掉**：`"-"*` 在 FTS5 里是"空短语"，会让查询**语法报错**
    /// 而不是搜不到（用户看到的是列表卡住不变）。
    private static func indexTerms(for query: String) -> String? {
        guard query.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        guard !containsHan(query) else { return nil }
        return quoteFTS5(query) + "*"
    }

    /// 是不是含汉字 —— 有就只走子串，不查拼音索引。
    ///
    /// 块范围跟 primuse `containsHan` 同一份 Unicode CJK（基本 + 扩展 A/B + 兼容）。
    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    /// 把一段用户输入变成 FTS5 的**字面量**：整段当一个词，里面的双引号翻倍转义。
    ///
    /// ⚠️ 必须包起来：用户敲进来的东西里可能有 `-` `"` `(` `:` 这些 **FTS5 的语法字符**，
    /// 不包会让"语法"本身出错（那是抛错，不是搜不到）。
    private static func quoteFTS5(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 给一首歌补上三列拼音搜索键 —— **写库的每一条路都经过它**（`upsert` / `update`）。
    ///
    /// 为什么放在写库这一处、而不是让每个调用方自己算：这是「只有一个地方知道」那条规矩 ——
    /// 导入、重新扫描、以后的手工改标签，谁都不用记得算拼音（漏一处就是"有些歌搜不出来"）。
    ///
    /// ⚠️ **一律重算，不沿用旧值**：拼音是 `title` / `artist` / `album` 的**纯函数**，
    /// 标题改了它就该跟着变。参考实现的写法是"已有值就不覆盖"、另外再靠一处「标题变了就把旧值
    /// 置空」来兜 —— 那要两处同时对才不出错；这里直接把"什么时候该作废"这个判断**去掉**。
    private static func withSearchKeysFilled(_ track: Track) -> Track {
        var filled = track
        filled.titlePinyin = PinyinTransformer.searchKeys(track.title)
        filled.artistPinyin = PinyinTransformer.searchKeys(track.artist)
        filled.albumPinyin = PinyinTransformer.searchKeys(track.album)
        return filled
    }

    // MARK: - 私有 · 观察

    /// 观察用的那一份快照 —— 三样一起取，一次推给三个流。
    ///
    /// 合成一个结构体而不是用元组：字段有名字，加东西的时候不会把 `.0` / `.1` 搞混。
    private struct LibrarySnapshot {
        var tracks: [Track]
        var playlists: [Playlist]
        var favoriteTrackIDs: Set<Track.ID>
        var playlistTrackCounts: [Playlist.ID: Int]
    }

    private static func fetchSnapshot(_ db: Database) throws -> LibrarySnapshot {
        // 歌单按手动顺序 —— 那是数据的一部分，不是显示排序。
        //
        // 🔴 **这一处有意不吊 `rowid` 兜底** —— 跟下面歌曲那一段**不一样**，不是漏了。
        // `sortIndex` 只由代码写：新建 = 现有最大 +1（`createPlaylist`）、拖完 = 重写成 0/1/2…
        //（`applyPlaylistManualOrder`）—— **两条路都给不出重复值**。
        // 真出现并列，就只有一种可能：**库被外面改坏了 / 是坏的老数据**。
        // 那正是「数据坏了」这件事本身该露出来的时候；再垫一层兜底只是把坏数据收拾得看着正常，
        // **反而把问题盖住** —— 所以这里不加。
        let playlists = try Playlist.fetchAll(db).sorted { $0.sortIndex < $1.sortIndex }
        let favoriteIDs = Set(try Favorite.fetchAll(db).map(\.id))

        var counts = try fetchTrackCounts(db)
        // 🔴 「最爱的歌曲」的成员**不在关联表里**（它就是收藏表）⇒ 它那一份数量得在这儿补上。
        // 补在这一层，页面拿到的就是一份"每个歌单各有几首"的完整答案，不用自己写 if。
        if let favorites = playlists.first(where: \.isFavorites) {
            counts[favorites.id] = favoriteIDs.count
        }

        return LibrarySnapshot(
            // ⚠️ 不按**显示方式**排（那是页面的决定，见 `allTracks`），但推出去的顺序必须是**确定的**：
            // 按 `rowid` 排，也就是「入库先后」。
            //
            // 为什么非要确定：页面排序时，**并列**那几首要靠「原始顺序」兜底
            // （同一毫秒落库的两首、空标题的歌，都是整片并列）。
            // 原始顺序本身都不确定的话，兜底就兜不住 —— 表现就是「每次打开顺序都不一样」。
            // `rowid` 是 SQLite 的隐藏列（不用另建索引、零成本），语义正好是入库先后。
            tracks: try Track.order(Column.rowID).fetchAll(db),
            playlists: playlists,
            favoriteTrackIDs: favoriteIDs,
            playlistTrackCounts: counts
        )
    }

    /// 每个歌单有几首歌 —— **一条 `GROUP BY` 算完**。
    ///
    /// ⚠️ key 要转回来：库里 `playlist_id` 存的是**大写字符串**（`Playlist` 的 UUID 策略），
    /// 而 `Playlist.ID` 是 `UUID` —— 直接当 UUID 解会全落空。
    ///
    /// ⚠️ 关联表里**没有的**（空歌单、以及「最爱的歌曲」）不会出现在结果里 ——
    /// 调用方按「查不到就是 0 首」处理。
    private static func fetchTrackCounts(_ db: Database) throws -> [Playlist.ID: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT "playlist_id", COUNT(*) AS "count"
            FROM "playlist_tracks"
            GROUP BY "playlist_id"
            """)
        var counts: [Playlist.ID: Int] = [:]
        for row in rows {
            guard let rawID: String = row["playlist_id"],
                  let id = UUID(uuidString: rawID) else { continue }
            counts[id] = row["count"]
        }
        return counts
    }

    private func apply(_ snapshot: LibrarySnapshot) {
        tracksRelay.accept(snapshot.tracks)
        playlistsRelay.accept(snapshot.playlists)
        trackCountsRelay.accept(snapshot.playlistTrackCounts)
        favoritesRelay.accept(snapshot.favoriteTrackIDs)
    }

    /// 启动时**同步**读一次。
    ///
    /// 必须做：`ValueObservation` 的第一次回调是**异步**的，只靠观察的话首屏会先闪一个空列表。
    private func loadOnce() throws {
        apply(try writer.read { try Self.fetchSnapshot($0) })
    }

    /// 盯住曲库，库一变就推新的一份出去。
    ///
    /// 观察的是**整份快照**（歌 + 歌单 + 收藏）：任何一张表变了都会重跑。
    /// 曲库规模下这点开销可以忽略，换来的是"不用逐个想哪张表变了要通知谁"。
    private func startObserving() {
        observation = ValueObservation
            .tracking { db in try Self.fetchSnapshot(db) }
            .start(
                in: writer,
                // 回主线程：订阅方（页面）都在主线程上刷新界面。
                scheduling: .async(onQueue: .main),
                onError: { [weak self] error in
                    // 观察到这里就断了 —— 转出去让上层提示用户，别悄悄不出声。
                    self?.errorRelay.accept(error)
                },
                onChange: { [weak self] snapshot in
                    self?.apply(snapshot)
                }
            )
    }
}

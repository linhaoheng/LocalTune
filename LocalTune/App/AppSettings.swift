import Foundation
import RxRelay
import RxSwift

/// 全 App 的设置 —— **业务代码里唯一该碰 `UserDefaults` 的地方**。
///
/// 为什么要有这一层：`UserDefaults.standard` 一旦散进页面和 ViewModel，
/// 「这个 App 到底存了哪些偏好」就没有一处能回答 —— 想知道得全工程搜字符串。
/// 各页菜单 / 面板改偏好时都走这里，**不另开设置页**。
///
/// ⚠️ 键名一律 **`域.键名` 两段式**（`songs.*` / `playlists.*` / `playback.*` / `app.*`）——
/// 看一个 key 就知道它属于哪一块。
///
/// ## 线程
///
/// **读写都在主线程**：偏好由界面动作触发，`BehaviorRelay` 也只给主线程订阅方用。
/// `UserDefaults` 本身线程安全，但本类的 relay **不当成跨线程总线** —— 别在后台队列写属性。
final class AppSettings {

    /// 键名集中在这儿 —— 外面不用知道字符串长什么样。
    private enum Key {
        static let songSortMode = "songs.sortMode"
        static let songSortDirection = "songs.sortDirection"
        static let playlistSortMode = "playlists.sortMode"
        static let playlistSortDirection = "playlists.sortDirection"
        static let playlistDetailSortMode = "playlistDetail.sortMode"
        static let playlistDetailSortDirection = "playlistDetail.sortDirection"
        static let iPadAutoCoverFlow = "playlists.iPadAutoCoverFlow"
        static let theme = "app.theme"
        static let showAudioQuality = "app.showAudioQuality"
        static let showPlayCount = "songs.showPlayCount"
        static let playbackMode = "playback.mode"
        /// 旧键 —— 仅迁移读一次，不再写入。
        static let legacyRepeatMode = "playback.repeatMode"
        static let legacyIsShuffled = "playback.isShuffled"
        /// EQ + 变速一份结构。不迁 `player.eq*` 那种一档一个键的写法。
        static let effects = "playback.effects"
        static let sleepFinishTrack = "playback.sleepFinishTrack"
        static let lyricsVisible = "lyrics.isVisible"
        static let lyricsFontSize = "lyrics.fontSize"
        static let lyricsAlignment = "lyrics.alignment"
        /// 歌词海报：上次挑的风格 / 画幅（空串 ＝ 还没挑过）＋ 画不画署名。
        static let lyricsPosterStyle = "lyrics.posterStyle"
        static let lyricsPosterCanvas = "lyrics.posterCanvas"
        static let lyricsPosterShowsCredit = "lyrics.posterShowsCredit"
        static let lyricsPosterPrefersMotion = "lyrics.posterPrefersMotion"
    }

    /// 存哪儿。
    ///
    /// ⚠️ 用**注入**而不是写死 `.standard`：以后写测试要换一套隔离的偏好，
    /// 写死的话到时候只能回来改业务代码。
    private let defaults: UserDefaults

    /// 音质显示开关的**真相** —— 它一变，两个页面都要跟着变。
    ///
    /// 🔴 **为什么是一条流、不只留个 `Bool`**：这个开关同时管着**两处**
    /// （列表行那一小枚、播放页的音质条），而开关本身只长在播放页的「更多」菜单里 ——
    /// 只存一个 `Bool` 的话，列表页要等下次进页面才知道它变了。
    /// `NotificationCenter` 通知能解决这件事；我们用它这一层现成的流。
    private let showAudioQualityRelay: BehaviorRelay<Bool>

    /// 播放次数**显示**开关的真相 —— 它一变，曲库 / 歌单列表行都要跟着显隐耳机角标。
    ///
    /// 🔴 **只管画不画，不管计不计**：次数始终按真实听满 30 秒记；这个开关只决定列表上
    /// 看不看得见。和音质开关一样用流，避免关了再开要等下次进页面才刷新。
    private let showPlayCountRelay: BehaviorRelay<Bool>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // ⚠️ 用 `object(forKey:)` 而不是 `bool(forKey:)` 判"存过没有"：
        // `bool(forKey:)` 读不到时也返回 `false`，分不出"存过 false"和"没存过"
        // （同下面 `playbackMode` 迁移那条理由）。**没存过时给 `false`** —— 见 `showAudioQuality`。
        showAudioQualityRelay = BehaviorRelay(
            value: defaults.object(forKey: Key.showAudioQuality) as? Bool ?? false
        )
        showPlayCountRelay = BehaviorRelay(
            value: defaults.object(forKey: Key.showPlayCount) as? Bool ?? false
        )
    }

    // MARK: - 曲库列表排序

    /// 曲库列表按什么字段排。
    ///
    /// 读不到、或者存的值已经不认识了（换过枚举档位）→ 回到「导入时间」：
    /// 宁可用默认值，也不能让列表排不出来。
    var songSortMode: SongSortMode {
        get { SongSortMode(rawValue: storedValue(forKey: Key.songSortMode)) ?? .importDate }
        set { defaults.set(newValue.rawValue, forKey: Key.songSortMode) }
    }

    /// 曲库列表是升序还是降序。
    var songSortDirection: SortDirection {
        get { SortDirection(rawValue: storedValue(forKey: Key.songSortDirection)) ?? .ascending }
        set { defaults.set(newValue.rawValue, forKey: Key.songSortDirection) }
    }

    // MARK: - 歌单列表排序

    /// 歌单列表按什么字段排。
    ///
    /// 读不到、或者存的值已经不认识了（换过枚举档位）→ 回到「创建时间」：
    /// 宁可用默认值，也不能让列表排不出来。
    ///
    /// ⚠️ **全 App 只有这一套歌单排序偏好** —— 别给**每个歌单**再存一套
    /// （`playlist.<uuid>.sortMode`），那是**无界增长的 key**：歌单删了，key 还留在盘上。
    var playlistSortMode: PlaylistSortMode {
        get { PlaylistSortMode(rawValue: storedValue(forKey: Key.playlistSortMode)) ?? .createdAt }
        set { defaults.set(newValue.rawValue, forKey: Key.playlistSortMode) }
    }

    /// 歌单列表是升序还是降序。
    ///
    /// ⚠️ 升降方向跟曲库列表**共用 `SortDirection`** —— 它答的是「升还是降」这一件事，
    /// 跟「按哪个字段排」无关（那是 `PlaylistSortMode`）。两边各来一个类型，就是同一个概念写两遍。
    var playlistSortDirection: SortDirection {
        get { SortDirection(rawValue: storedValue(forKey: Key.playlistSortDirection)) ?? .ascending }
        set { defaults.set(newValue.rawValue, forKey: Key.playlistSortDirection) }
    }

    /// 歌单详情页曲目按什么排 —— **全 App 一套**，不是每个歌单一套（那种无界 key 不做）。
    var playlistDetailSortMode: PlaylistDetailSortMode {
        get {
            PlaylistDetailSortMode(rawValue: storedValue(forKey: Key.playlistDetailSortMode))
                ?? .playlistOrder
        }
        set { defaults.set(newValue.rawValue, forKey: Key.playlistDetailSortMode) }
    }

    /// 歌单详情页是升序还是降序。
    var playlistDetailSortDirection: SortDirection {
        get {
            SortDirection(rawValue: storedValue(forKey: Key.playlistDetailSortDirection))
                ?? .ascending
        }
        set { defaults.set(newValue.rawValue, forKey: Key.playlistDetailSortDirection) }
    }

    /// iPad 歌单详情横屏要不要自动盖封面流。无值默认开。
    ///
    /// ⚠️ 用 `object(forKey:)` 判存过没有：`bool(forKey:)` 读不到也是 `false`，
    /// 会把「没存过」当成关。
    var iPadAutoCoverFlow: Bool {
        get {
            if defaults.object(forKey: Key.iPadAutoCoverFlow) == nil { return true }
            return defaults.bool(forKey: Key.iPadAutoCoverFlow)
        }
        set { defaults.set(newValue, forKey: Key.iPadAutoCoverFlow) }
    }

    // MARK: - 播放

    /// 当前播放模式（互斥四档）。
    ///
    /// 读不到 → 尝试旧键迁移一次并落盘新键、删旧键；再不行 → `.sequential`。
    var playbackMode: PlaybackMode {
        get { resolvedPlaybackMode() }
        set { defaults.set(newValue.rawValue, forKey: Key.playbackMode) }
    }

    /// 读出模式；若只有旧两开关则迁移写盘一次。
    func resolvedPlaybackMode() -> PlaybackMode {
        let raw = storedValue(forKey: Key.playbackMode)
        if let mode = PlaybackMode(rawValue: raw) {
            return mode
        }
        let migrated = Self.migratedPlaybackMode(
            legacyRepeat: defaults.string(forKey: Key.legacyRepeatMode),
            legacyShuffled: defaults.object(forKey: Key.legacyIsShuffled) as? Bool
        )
        defaults.set(migrated.rawValue, forKey: Key.playbackMode)
        defaults.removeObject(forKey: Key.legacyRepeatMode)
        defaults.removeObject(forKey: Key.legacyIsShuffled)
        return migrated
    }

    /// 旧两开关 → 互斥单档（曾开洗牌的一律落成 `.shuffle`）。
    static func migratedPlaybackMode(legacyRepeat: String?, legacyShuffled: Bool?) -> PlaybackMode {
        if legacyShuffled == true { return .shuffle }
        switch legacyRepeat {
        case "all": return .all
        case "one": return .one
        default: return .sequential
        }
    }

    // MARK: - EQ / 变速

    /// EQ 选中、曲线、用户预设、速率。一份 JSON，一次读写。
    ///
    /// ⚠️ 活状态在 `EffectsSession`：这里只是存档。读不到 / 解不开 → 出厂值（自定义平线 + 1×）。
    var effectsArchive: EffectsArchive {
        get {
            guard let data = defaults.data(forKey: Key.effects) else { return .factory }
            // 解不开 = 键坏了或换过结构，回到出厂。不敢把坏数据喂给节点。
            return (try? JSONDecoder().decode(EffectsArchive.self, from: data)) ?? .factory
        }
        set {
            // 值类型编码失败在这里几乎不会发生；发生就这一次不落盘，活状态仍在 Session。
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.effects)
        }
    }

    // MARK: - 睡眠

    /// 睡眠定时：到点后要不要把当前这首放完再停。
    ///
    /// 倒计时本身不落盘。缺键 = `false`。
    var sleepFinishTrack: Bool {
        get { defaults.bool(forKey: Key.sleepFinishTrack) }
        set { defaults.set(newValue, forKey: Key.sleepFinishTrack) }
    }

    // MARK: - 音质显示

    /// 要不要显示音质 —— 列表行那一小枚（格式名 ＋ 徽章）和播放页的音质条都归它管。
    ///
    /// 🔴 **真相在这条流上，`UserDefaults` 只是它的存档**：读盘只在 `init` 里做一次，
    /// 之后两个页面都从这条流拿 —— 各自去读盘的话，开关一改另一边不会知道。
    ///
    /// ⚠️ **没存过时是「关」**（`UserDefaults.bool` 缺键也是 `false`）——
    /// 用户要从播放页「更多」自己打开才看得见。要改默认，改 `init` 里那个 `?? false`。
    var showAudioQuality: Bool {
        get { showAudioQualityRelay.value }
        set {
            showAudioQualityRelay.accept(newValue)
            defaults.set(newValue, forKey: Key.showAudioQuality)
        }
    }

    /// 开关变了 —— 列表页和播放页都订它。
    ///
    /// ⚠️ `BehaviorRelay` ⇒ **订阅那一刻会先收到一次当前值**（不是"变了"）。
    /// 要跳掉那一次的调用方自己 `skip(1)`（播放页重建「更多」菜单就是这种情况）。
    var showAudioQualityChanges: Observable<Bool> { showAudioQualityRelay.asObservable() }

    // MARK: - 播放次数显示

    /// 要不要在列表行画「耳机 + 次数」—— **只管显示，不管统计**。
    ///
    /// 统计始终由 `PlayCountTracker` 按真实听满 30 秒记；关掉这个开关只是列表不画角标。
    ///
    /// ⚠️ **没存过时是「关」** —— 用户要从曲库「更多」自己打开才看得见。
    var showPlayCount: Bool {
        get { showPlayCountRelay.value }
        set {
            showPlayCountRelay.accept(newValue)
            defaults.set(newValue, forKey: Key.showPlayCount)
        }
    }

    /// 显示开关变了 —— 曲库 / 歌单详情 / 挑歌页都订它。
    ///
    /// ⚠️ `BehaviorRelay` ⇒ 订阅那一刻会先收到一次当前值；重建菜单的调用方自己 `skip(1)`。
    var showPlayCountChanges: Observable<Bool> { showPlayCountRelay.asObservable() }

    // MARK: - 歌词

    /// 播放页要不要显示歌词（竖屏是**封面与歌词二选一**）。
    /// 🔴 **只落在这儿**：别再配一个内存单例 `LyricsDisplayState` 去存同一份状态。
    ///
    /// ⚠️ **没存过时是「关」** —— 打开播放页默认看到封面。
    /// ⚠️ 这颗开关**只有播放页一个消费方**（进页面读一次、点引用键切一次），所以**不做成流**：
    /// 做成流就得有个订阅方一直挂着，而这里没有第二个页面关心它。
    var lyricsVisible: Bool {
        get { defaults.bool(forKey: Key.lyricsVisible) }
        set { defaults.set(newValue, forKey: Key.lyricsVisible) }
    }

    /// 歌词**外观**：字号 ＋ 对齐 —— **一次读写两键**（`lyrics.fontSize` / `lyrics.alignment`）。
    /// 🔴 **只落在这儿**：别再把它们抄进内存里的 `LyricsDisplay` 单例。
    ///
    /// ⚠️ **读不到 / 存的值不认识了都回默认**（字号 18、居中）—— 跟版式那几条同一个取向：
    /// 宁可用出厂值，也不能让歌词画不出来。越界值由 `LyricsAppearance.init` 就地钳。
    /// ⚠️ 顺手也不是一条**流**：这一页是唯一消费方（进页面读一次、面板改完回写一次），
    /// 做成流就得有个订阅方一直挂着，而这里没有第二个页面关心它（同 `lyricsVisible`）。
    var lyricsAppearance: LyricsAppearance {
        get {
            // ⚠️ 用 `object(forKey:) as? Double` 而不是 `float(forKey:)`：后者读不到时返回 0，
            // 分不出"存过 0"和"没存过"（同 `showAudioQuality` 那条理由）——0 会被钳成 16。
            // 🔴 **写成闭包，不要写成 `.map(CGFloat.init)`** —— 那会 `Ambiguous use of 'init'`：
            // 64 位上 `CGFloat` 就是 `Double` 的别名，于是 `init(_: Double)`（精确匹配）与
            // `init<Source: BinaryFloatingPoint>(_:)`（同样精确匹配）等好几个候选**排名打平**，
            // 编译器挑不出唯一一个。闭包把入参钉成 `Double` 后只剩 `CGFloat(Double)` 一条可用。
            // ⚠️ 同工程的 `.map(Int64.init)` / `.map(CollationBox.init)` 不歧义（前者入参只精确命中
            // `init(_: Int)`、后者只有一个 `init`）——**别照着它们把这里也改回裸 `init`**。
            let stored = (defaults.object(forKey: Key.lyricsFontSize) as? Double).map { CGFloat($0) }
            return LyricsAppearance(
                fontSize: stored ?? LyricsAppearance.defaultFontSize,
                alignment: LyricsAlignment(rawValue: storedValue(forKey: Key.lyricsAlignment)) ?? .center
            )
        }
        set {
            defaults.set(Double(newValue.fontSize), forKey: Key.lyricsFontSize)
            defaults.set(newValue.alignment.rawValue, forKey: Key.lyricsAlignment)
        }
    }

    // MARK: - 歌词海报

    /// 上次挑的歌词海报风格。**空串 ＝ 还没挑过** ⇒ 按那一刻能用的风格解析一个出来。
    ///
    /// 存的是一段**裸串**（`LyricsPosterStyleID.rawValue`）而不是枚举：以后加一种风格
    /// 不用回来改这一层。认不出来的串由 `LyricsPosterStyleCatalog` 退回默认，不会画不出海报。
    var lyricPosterStyleID: String {
        get { storedValue(forKey: Key.lyricsPosterStyle) }
        set { defaults.set(newValue, forKey: Key.lyricsPosterStyle) }
    }

    /// 上次挑的歌词海报画幅（`LyricsPosterCanvas.rawValue`）。**空串 ＝ 还没挑过** ⇒ 用该风格的默认档。
    ///
    /// ⚠️ 风格换了之后，存着的画幅可能不在新风格支持的范围里 —— 收敛那件事在
    /// `LyricsPosterStyleDescriptor.canvas(preferring:)`，这一层只管存取。
    var lyricPosterCanvas: String {
        get { storedValue(forKey: Key.lyricsPosterCanvas) }
        set { defaults.set(newValue, forKey: Key.lyricsPosterCanvas) }
    }

    /// 歌词海报上画不画右下角那行署名。**没存过时是「画」**。
    ///
    /// ⚠️ 用 `object(forKey:)` 判存过没有：`bool(forKey:)` 读不到也是 `false`，
    /// 会把「没存过」当成关（同 `iPadAutoCoverFlow`）。
    var lyricPosterShowsCredit: Bool {
        get {
            if defaults.object(forKey: Key.lyricsPosterShowsCredit) == nil { return true }
            return defaults.bool(forKey: Key.lyricsPosterShowsCredit)
        }
        set { defaults.set(newValue, forKey: Key.lyricsPosterShowsCredit) }
    }

    /// 歌词海报导成实况照片（动态）还是静态图。**没存过时是「动态」**。
    ///
    /// ⚠️ 同 `lyricPosterShowsCredit`：`bool(forKey:)` 读不到也是 `false`，会把
    /// 「没存过」当成关，所以用 `object(forKey:)` 判存过没有。
    var lyricPosterPrefersMotion: Bool {
        get {
            if defaults.object(forKey: Key.lyricsPosterPrefersMotion) == nil { return true }
            return defaults.bool(forKey: Key.lyricsPosterPrefersMotion)
        }
        set { defaults.set(newValue, forKey: Key.lyricsPosterPrefersMotion) }
    }

    // MARK: - 外观

    /// App 的外观档位（浅色 / 深色）。
    ///
    /// 读不到、或者存的值已经不认识了（换过枚举档位）→ 回到**浅色**：
    /// 宁可回到默认，也不能让 App 没有外观可用。
    var theme: AppTheme {
        get { AppTheme(rawValue: storedValue(forKey: Key.theme)) ?? .light }
        set { defaults.set(newValue.rawValue, forKey: Key.theme) }
    }

    // MARK: - 私有

    /// 取一个字符串值 —— 没存过就是空串，由调用方决定回到哪个默认档。
    private func storedValue(forKey key: String) -> String {
        defaults.string(forKey: key) ?? ""
    }
}

import Foundation
import GRDB

/// 一首歌。**只管数据**。
///
/// 这个文件里只有「数据长什么样」；**怎么显示成给人看的文字**在同目录的 `Track+Display.swift` 里。
/// 收藏那张表在 `Favorite.swift` 里 —— 一个文件一个概念，找东西不用猜。
///
/// ⚠️ **身份 = 它在 `music/` 里的路径（取 SHA256），不是内容**：
/// - 用**路径**当身份 ⇒ 同一个文件删掉再导入还是同一首，收藏和歌单跟得住；
/// - 用**内容**当身份 ⇒ 改个标签、换个编码这首就变成"另一首"，收藏全丢。
///
/// 内容指纹是**另一件事**（`fingerprint`）：导入 / 扫描问「库里是不是已经有这份字节」。
/// 活文件才跳过；死行不挡重导入。见 `ImportDuplicatePolicy`。
///
/// 艺人 / 专辑**以字符串存在本表上**，不另开 Artist / Album 表。
struct Track: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {

    static let databaseTableName = "tracks"

    // 🔴 属性名（`fileName`）和列名（`file_name`）的对应关系**不手写**，交给 GRDB 自动转。
    //
    // 它这两个策略的内部就是把 Foundation 那套 snake_case 算法原样搬过来的
    // （`EncodableRecord.swift:674` 的注释原话："Copied straight from swift-corelibs-foundation"），
    // 规则是**小写转大写处切词、连续大写当一个词**：
    //
    //     fileName   → file_name
    //     durationMs → duration_ms
    //     playlistID → playlist_id      ← 连续的 ID 算一个词，不会切成 play_list_i_d
    //
    // ⚠️ 代价是**属性名一个都不许随便改** —— 改了列名就跟着变，而列名对不上是
    // **静默错误**（不报错、只是查不到）。真要改属性名，得同时写一条迁移改列名。
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    // MARK: - 身份

    /// 主键 = 相对 `Documents/music` 路径的 SHA256。
    let id: String

    /// 相对 `Documents/music` 的路径。
    var path: String = ""
    var fileName: String = ""

    /// 文件内容的 SHA256。空串 ＝ 还没算过（老行补指纹之前）。
    ///
    /// ⚠️ **不当主键**。只给 `ImportDuplicatePolicy` 认「同一份字节」。
    var fingerprint: String = ""

    // MARK: - 标签
    //
    // 「没有值」在这张表里只有两种说法，按「这一项会不会总要显示」来分，别混用：
    //  - **总要显示的**（标题 / 艺人 / 专辑）用**空字符串**，永不是 `nil` ——
    //    列表每一行都要拼「标题」和「艺人 - 专辑」，用空串就不用到处判 `nil`，
    //    界面上"空"就显示成「未知艺人 / 未知专辑」。
    //  - **有就显示、没有就整项不显示的**（专辑艺人 / 流派 / 作曲 / 发行日期 / 编号 / 音质 / 封面 / 歌词）
    //    用 `nil` —— 它表达的是「这一项压根不存在」，不是「这一项是空的」。

    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var albumArtist: String?
    var genre: String?
    var composer: String?

    /// 注释（文件标签里的 comment）。没有就是 `nil` —— 跟流派 / 作曲同一档。
    var comment: String?

    /// 原样存标签里写的东西（`"2019"` / `"2019-05-01"` 都行），不切分、不转换。
    var releaseDate: String?

    var trackNumber: Int?
    var totalTracks: Int?
    var discNumber: Int?
    var totalDiscs: Int?

    // MARK: - 搜索索引键
    //
    // 三列**不是给人看的**，是给全文索引用的搜索键（全拼 + 连写全拼 + 首字母缩写，
    // 见 `PinyinTransformer.searchKeys`）。留着它们是为了让「敲 zjl 能找到周杰伦」
    // 这件事成立 —— 拼音必须**预先算好存起来**，不能在用户每次按键时现算几万次。
    //
    // ⚠️ 它们是 `title` / `artist` / `album` 的**纯函数**，由 `LibraryStore` 在写库那一刻
    // 现算现填（见那里），所以**构造一首歌时不用传** —— 这也是它们有默认值的原因：
    // 忘了填不会静默留错，写库那一步一定会重算。

    var titlePinyin: String?
    var artistPinyin: String?
    var albumPinyin: String?

    var durationMs: Int?

    // MARK: - 音质

    /// kbps —— 引擎给的就是 kbps，原样收下，不做换算。
    var bitRate: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?

    /// 文件格式名。
    var format: String?

    // MARK: - 封面

    /// 封面文件名 —— 在 `ArtworkStore.imagesDirectory` 那个目录下。
    var artworkPath: String?

    // MARK: - 文件记号（二次扫描提速）

    var fileSize: Int64?

    /// 文件修改时间的**微秒**整数。
    ///
    /// ⚠️ 刻意不用 `Date`：它的精度只到毫秒，写进去再读回来跟磁盘上的值永远不相等，
    /// "文件变没变"这个判断就废了。
    var fileModificationDate: Int64?

    /// 文件从**什么时候起**不在本机了。`nil` ＝ **在**。
    ///
    /// 🔴 它**不是**「文件被删了」的记号，而是「这一行指的那个文件，现在找不到」：
    /// 行照旧留着（播放次数 / 收藏 / 歌单归属都挂在它上面），文件挪回来**自己就清掉**
    /// —— 身份是路径，路径没变就是同一首。
    ///
    /// 什么时候标、什么时候清、读不进去的目录怎么算，都在 `LibraryReconcile` 那一处定。
    var missingSince: Date?

    // MARK: - 业务

    /// 导入时间。**刻意不给默认值**：「现在几点」这件事只有导入那一步知道，
    /// 让它必须被显式写出来 —— 给了默认值，哪天忘了赋时间也不会报错，只会静默记成错的。
    ///
    /// ⚠️ 它和 `id` 一样没有默认值，所以**构造一首歌时必须显式传这两个**。
    var dateAdded: Date

    /// 播放次数。**只用来显示**（列表上一个开关控制显不显示），**不参与排序**。
    var playCount: Int = 0

    // MARK: - 歌词
    //
    // 🔴 **内嵌歌词不在这张表上** —— 它拆到了侧表（`TrackLyrics`，表名 `track_lyrics`）。
    // 原因：SQLite 是**行存**库，即使 `SELECT "id"` 也要把整行读出来，而歌词一首 1~5 KB，
    // 留在 `tracks` 里会让**每次全表扫描多读近一倍字节**。见 `docs/设计/歌词拆侧表设计.md`。

    /// 「编辑歌词」页写的**自定义层**（用户自己那一份）。**空串 ＝ 没自定义层**（显示时落回内嵌）。
    ///
    /// 🔴 **和侧表那份内嵌歌词分开存的原因**：内嵌那份会在**重新扫描**时被音频文件里的歌词
    /// **覆盖**（`TrackImporter` 拿 `metadata.lyrics` 顶掉侧表那一行），而用户编辑的结果**必须活下来**
    /// —— 所以它住在这个**文件管不着**的列里。取用时的优先级由 `LyricsSourcePolicy` 一处决定
    ///（它现在吃「自定义层」＋ `TrackLyrics?`）。
    ///
    /// ⚠️ **它留在本表**：`NOT NULL DEFAULT ''`，绝大多数歌从没编辑过（空串占 1 字节）
    /// ⇒ **不是**扫描变慢的贡献者。搬它拿不到扫描收益，却要把「谁优先」拆到两个存储去。见设计文档 §2.3。
    var customLyrics: String = ""
}

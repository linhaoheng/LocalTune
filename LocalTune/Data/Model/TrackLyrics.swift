import Foundation
import GRDB

/// 一首歌的**内嵌歌词** —— 从 `tracks` 表垂直分出来的侧表（1:1）。
///
/// ## 为什么单独一张表
///
/// 🔴 **SQLite 是行存库**：`SELECT "id" FROM "tracks" WHERE …` 这条搜索扫描，**即使只要 id**，
/// 也会把**整行**读出来。而歌词一首 1~5 KB，留在 `tracks` 行里就让每次全表扫描
/// **多读近一倍字节**（实测 5 万首 63.8 → 39.7 ms）—— 而我们**从不搜歌词**
///（FTS5 索引装的是拼音三列）。拆到侧表之后，两张表各占各的页，扫 `tracks` 只读窄行。
/// 完整论证见 `docs/设计/歌词拆侧表设计.md`。
///
/// ## 形状
///
/// - **主键直接复用那首歌的 `id`**：1:1 附属实体，**跟 `Favorite` 完全同形状**。
///   ⚠️ 列名必须叫 `id`（不能叫 `track_id`）—— GRDB 认主键只看 `id` 这个名字。
/// - **`ON DELETE CASCADE`**：删歌时这行跟着走，不靠谁记得清（同 `Favorite` / `playlist_tracks`）。
/// - 🔴 **没有行 ＝ 这首歌没有内嵌歌词** —— **不对没歌词的歌插空行**（白写一遍）。
///   行既然在，`lyrics` 就不是可空的：把"没有行"和"有一行空的"变成两句话说同一件事，
///   迟早对不上。
///
/// ## 只装内嵌歌词，不装自定义层
///
/// `custom_lyrics` **留在 `tracks` 上** —— 它 `NOT NULL DEFAULT ''`，绝大多数歌从没编辑过
///（空串占 1 字节），**不是**扫描变慢的贡献者。搬它拿不到扫描收益，却要把「谁优先」那个判断
///（`LyricsSourcePolicy`）拆到两个存储去 —— 那是同一概念散在两处。判据见设计文档 §2.3。
struct TrackLyrics: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {

    static let databaseTableName = "track_lyrics"

    // 属性名 ↔ 列名不手写 —— 见 `Track` 里那段说明。这里两个名字本来就一样，
    // 但**照样写上**：跟 `Favorite` / `Track` 一个口径，免得日后加列时一处手写一处不写。
    // ⚠️ 属性名不许随便改（列名对不上是**静默错误**：不报错、只是查不到）。
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    /// 就是那首歌的 id（1:1 的另一半）。**列名刻意叫 `id`** —— GRDB 认主键只看这个名字。
    let id: Track.ID

    /// 内嵌标签里读到的那一份。**非空** —— 没有歌词的歌根本没有这一行（见类注释）。
    var lyrics: String
}

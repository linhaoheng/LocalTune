import Foundation
import GRDB

/// 歌单与歌曲的关联 —— 多对多的那张中间表。
///
/// 一条记录 = 「某个歌单里放了某首歌」，`position` 决定它在这个歌单内的位置。
///
/// 这张表**没有自己单独的编号**：「哪个歌单 + 哪首歌」这一对**本身就是主键**。
/// 这样同一首歌在同一个歌单里天然只可能出现一次，不用再额外加一条「不许重复」的规矩去堵。
///
/// 🔴 **复合主键：不需要在 Swift 这边额外声明任何东西。**
/// GRDB 执行 `update` / `delete` / `exists` 时会去**数据库表**里读主键
/// （`DAO.init` 里的 `try db.primaryKey(databaseTableName)`），把读到的**所有**主键列
/// 用 `AND` 连起来当条件 —— 自动生成的是
/// `UPDATE ... WHERE playlist_id=? AND track_id=?` 和
/// `DELETE FROM playlist_tracks WHERE playlist_id=? AND track_id=?`。
/// （证据：`MutablePersistableRecord+DAO.swift` 第 149 / 189 / 200 / 210 / 335 / 367 行，
/// `primaryKey.columns` 是**数组**，`conditionColumns` 用 `" AND "` 拼。）
///
/// ⚠️ 唯一的前提：**建表 SQL 里的主键列名，必须跟「属性名自动转出来的列名」一字不差**
/// （`playlistID` → `playlist_id`、`trackID` → `track_id`，由下面的
/// `databaseColumnEncodingStrategy` 自动转）。写错了不会静默成功 —— GRDB 会抛
/// `recordNotFound`（"一行都没更新到"），错得比较明显。
///
/// 用 `PersistableRecord` 而不是 `MutablePersistableRecord`：两列主键都是外面给的，
/// 没有"数据库自己生成 id 再回填给对象"这回事，所以不需要 Mutable 那一层。
///
/// 🔴 **单独一个文件**：它对应一张独立的表（`playlist_tracks`），跟 `Playlist` 是并列关系。
struct PlaylistTrack: Hashable, Codable, FetchableRecord, PersistableRecord {

    static let databaseTableName = "playlist_tracks"

    /// `Playlist.ID` 是 `UUID`，默认会存成 16 字节 BLOB，跟建表里的 `TEXT` 列对不上
    /// （`STRICT` 表会当场报错），所以显式改成大写字符串。
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    // 属性名 ↔ 列名（`playlistID` ↔ `playlist_id`）不手写 —— 见 `Track` 里那段说明。
    // ⚠️ 属性名不许随便改（列名对不上是静默错误）。
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    var playlistID: Playlist.ID
    var trackID: Track.ID

    /// 在这个歌单里的位置，从 0 起。
    var position: Int = 0
}

extension PlaylistTrack {

    /// 列名和查询条件的**单一出处** —— 别处不要再拼列名字符串。
    enum Columns {

        /// 拿 UUID 当条件**必须走它** —— 理由和 `Playlist.Columns.id(_:)` 完全一样：
        /// `playlist_id` 是 UUID 列、库里存的是大写字符串，直接比 UUID 会编成二进制、查不到。
        static func playlistID(_ value: Playlist.ID) -> SQLExpression {
            Column("playlist_id") == value.uuidString
        }

        /// `track_id` 是**字符串**列（`Track.ID` 就是路径哈希），所以可以直接比。
        static let trackID = Column("track_id")

        static let position = Column("position")
    }
}

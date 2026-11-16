import Foundation
import GRDB

/// 收藏 —— 「哪些歌被收藏了」的一张名单。
///
/// 一条收藏除了「是哪首歌」和「什么时候收的」没有别的信息，所以主键直接复用 `Track` 的 `id`。
/// 好处有两个：不可能出现「收藏了一首库里没有的歌」（外键挡着），
/// 删歌时这条收藏跟着自动消失（`ON DELETE CASCADE`）。
///
/// 🔴 **单独一个文件**：它对应一张独立的表（`favorites`），跟 `Track` 是并列关系，不是从属。
/// 从属关系的小东西（只为某个类型服务的错误、选项）才允许挤在同一个文件里。
struct Favorite: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {

    static let databaseTableName = "favorites"

    // 属性名 ↔ 列名（`addedAt` ↔ `added_at`）不手写 —— 见 `Track` 里那段说明。
    // ⚠️ 属性名不许随便改（列名对不上是静默错误）。
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    let id: Track.ID

    /// 收进收藏的时间。**可空**，而且**刻意不给默认值**。
    ///
    /// - **可空**：加这一列之前就有的收藏**没有真实时间**，老行只能是 `NULL`
    ///   （＝「不知道什么时候收的」）。编一个当前时间填进去就是造假数据，
    ///   以后按收藏时间排序时它会混在真的时间里面。
    /// - **不给默认值**：跟 `Track.dateAdded` 同一条规矩 —— 「现在几点」只有收收藏那一步知道，
    ///   让它必须被显式写出来，忘填是编译错误而不是静默记成错的。
    ///
    /// 存法和库里别的时间列**同一个口径**（GRDB 把 `Date` 编成能读的字符串）——
    /// 「时间」这个概念在一个库里只有一种存法，不跟别的列比大小的值（`FileStamp`）才用整数。
    var addedAt: Date?
}

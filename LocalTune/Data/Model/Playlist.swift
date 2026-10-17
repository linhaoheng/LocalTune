import Foundation
import GRDB

/// 一个歌单。
///
/// 这个文件里只有歌单本身；**歌单和歌的关联表在 `PlaylistTrack.swift` 里** —— 一个文件一个概念。
///
/// ⚠️ **「最爱的歌曲」也是这个类型的一行**（`kind == .favorites`），不是另一种东西 ——
/// 但它**没有关联记录**：它的成员就是收藏表（分派只有 `LibraryStore.tracks(in:)` 一处知道）。
struct Playlist: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {

    static let databaseTableName = "playlists"

    /// `UUID` 默认存成 16 字节 BLOB，跟建表里的 `TEXT` 列对不上（`STRICT` 表会当场报错），
    /// 所以要显式改成大写字符串 —— 存出来是 `"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"` 这种。
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    // 属性名 ↔ 列名（`createdAt` ↔ `created_at`）不手写，交给 GRDB 自动转 ——
    // 规则和注意事项见 `Track` 里那段说明（⚠️ 属性名不许随便改）。
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    let id: UUID

    var name: String = ""

    /// 这是哪一种歌单。
    ///
    /// ⚠️ **不是"能不能删"的开关，是"它是什么"** —— 界面拿它决定封面画心还是画音符，
    /// 数据层拿它决定成员从哪张表取。
    var kind: PlaylistKind = .user

    /// **这个歌单当前显示的那张封面** —— 存的是封面文件名，图在 `Library/` 下：
    /// 手挑的带 `covers/` 前缀（见 `ArtworkStore.coversPathPrefix`，**进备份**），
    /// 生成的拼图是裸文件名、落 `images/`（**不进备份**、能重算）。
    ///
    /// 🔴 **两档都写这一列** —— 界面画什么只由库决定，不去磁盘上猜
    ///（磁盘上的东西不在观察流的失效条件里，猜出来的值永远晚一拍）。
    ///
    /// ⚠️ **不给默认值**（跟 `createdAt` 同一条规矩）：`nil` 是「还没有封面」这个**真实状态**，
    /// 界面据此去画爱 / 占位 —— 给它编一个默认文件名就是假数据。
    var artworkPath: String?

    /// 建单时间。歌单列表按「创建时间」排序时用它。
    ///
    /// ⚠️ 跟 `Track.dateAdded` 同一条规矩：**时间一律不给默认值**。
    /// 给了默认值就等于「忘了填不报错，只是静默记成错的」。
    var createdAt: Date

    /// 歌单之间的排列顺序 —— 「手动排序」用的就是它，不靠时间。
    var sortIndex: Int = 0
}

// MARK: - 「最爱的歌曲」

extension Playlist {

    /// 是不是「最爱的歌曲」那一行。
    ///
    /// 🔴 **它是算出来的，不是存下来的列** —— 存下来的只有 `kind`。
    /// 两份都存的话，迟早有一份忘了改。
    var isFavorites: Bool { kind == .favorites }

    /// 「最爱的歌曲」那一行的 id —— **固定值，各版本之间必须一致**。
    ///
    /// ⚠️ 为什么写死而不是建的时候现生成：这个 id 会出现在导出的歌单文件里，
    /// 也可能被用户的引用带上；每次重装换一个的话，那些引用就全对不上了。
    ///
    /// ⚠️ 不用 `UUID(uuidString:)!` —— 本工程零裸 `!`。
    /// 直接给 16 个字节，顺便把「它长什么样」摆在眼前：版本位 `4`、变体位 `10`。
    static let favoritesID = UUID(uuid: (
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
    ))

    /// 「最爱的歌曲」那一行的**默认名**（新建那一行时用）。
    ///
    /// ⚠️ 用户**可以改名**（`LibraryStore.rename` 不挡）—— 身份靠 `kind` / 固定 id，不靠这个字符串。
    static let favoritesName = "最爱的歌曲"

    /// 列名和查询条件的**单一出处** —— 别处不要再拼列名字符串。
    enum Columns {

        /// 拿 UUID 当条件**必须走它**，不能写 `Column("id") == uuid`。
        ///
        /// 🔴 为什么：库里 `id` 存的是**大写字符串**（本类型的
        /// `databaseUUIDEncodingStrategy` 是 `.uppercaseString`，GRDB 内部就是 `uuid.uuidString`）；
        /// 而 `Column == uuid` 走的是 `UUID.databaseValue`，它的实现**写死是 16 字节二进制**
        /// （`GRDB/Core/Support/Foundation/UUID.swift:56`，注释原话 "Returns a BLOB database value"）。
        /// 两种格式对不上 → **一行都查不到，而且不报错**。
        static func id(_ value: UUID) -> SQLExpression {
            Column("id") == value.uuidString
        }
    }
}

/// 歌单的两种。
///
/// ⚠️ `String` 原始值**就是库里存的那一列**（GRDB 对 `RawRepresentable` 有现成支持），
/// 所以改 case 名 = 改库里的值，**不许随手改**。
enum PlaylistKind: String, Codable {

    /// 用户自己建的。
    case user

    /// 「最爱的歌曲」—— 全库只有一行（id 固定），**不可删**（改名可以）。
    case favorites
}

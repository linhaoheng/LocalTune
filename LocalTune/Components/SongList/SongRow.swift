import Foundation

/// 歌曲列表**一行**的展示内容 —— 已经排好版，行拿到它只管往上摆。
///
/// 🔴 为什么不让行直接拿 `Track`：拿 `Track` 的话，行就得自己决定
/// 「副标题写什么、封面从哪来」—— 那是**判断**，判断属于页面状态（VM），
/// 不属于行。行只做一件事：把给它的东西摆上去。
///
/// 所以「艺人 - 专辑」的拼接发生在 VM 里（用 `Track.artistAlbumLine`），
/// 行收到的是一个拼好的字符串。
///
/// ⚠️ **这一份归 `Components/`**：曲库页和歌单详情页显示的是**同一行**
/// （两个页面也共用同一个 `SongNormalCell`）—— 各写一份必然走散。
/// 它和 `SongTableCell` 是这个目录里**唯一**依赖 `Data` 层类型的那条边
///（`Track` / `AudioQualityTag`）：这一行本来就是"一首歌长什么样"，
/// 不认 `Track` 的话它什么都不是。箭头方向 `Components → Data` 是允许的。
struct SongRow: Hashable {

    /// 这一行代表哪首歌 —— 列表靠它做差量刷新。
    let id: Track.ID

    /// 主标题（歌名）。
    let title: String

    /// 归字母段用的文字 —— **只给分段用，界面上不显示**。
    ///
    /// 歌名有就用歌名；歌名是空的（比如没标签的音频文件）就用**文件名**：
    /// 这类文件本来按文件名各有各的首字母，不兜底的话会一股脑挤进 `#` 段，
    /// 而那一段在列表里全是空行，等于没得定位。
    let collationText: String

    /// 副标题（「艺人 - 专辑」）。
    let subtitle: String

    /// 封面文件名 —— 行拿去取图，取不到就画占位。
    let artworkPath: String?

    /// 音质那一小枚（格式名 ＋ 档位徽章）；`nil` ＝ **这一行不画它**。
    ///
    /// ⚠️ `nil` 有两个来源，对行来说是同一件事：**开关关着**，或者**这首歌读不到格式名**。
    /// 那两种情况都由 VM 判完再给 —— 行不认识那个开关，也不认识 `Track`。
    let quality: AudioQualityTag?

    /// 播放次数；`nil` ＝ **这一行不画耳机角标**（显示开关关着）。
    ///
    /// ⚠️ 行不认识那个开关 —— 开 / 关由 VM 判完再给。`0` 也会画出来（耳机 + 0）。
    let playCount: Int?

    /// 是不是喜爱的歌曲 —— 决定行尾菜单里那一项是「喜爱」还是「取消喜爱」。
    let isFavorite: Bool

    /// 🔴 **这一行指的那个文件，现在不在本机了**（＝ `Track.missingSince != nil`）。
    ///
    /// 行拿到它只做三件事：歌名压灰、封面降透明、把音质那两枚换成「不在本机」。
    /// 「为什么会有这种行、什么时候标上、文件回来了怎么清」全在 `LibraryReconcile` 那一处；
    /// 行不认识"扫描"，只认这一个布尔。
    ///
    /// ⚠️ 它**不是**「播放失败」：那是"文件在、但解不开"，两者的出路完全不同
    ///（一个要重新导入，一个要换一份文件）。
    ///
    /// ⚠️ 由 `make` 从 `track` 上取（跟 `artworkPath` 同一个口径）—— **不设成 `make` 的参数**：
    /// 设成参数，两个页面各自的 VM 就都要写一遍 `missingSince != nil` 这个映射。
    let isMissing: Bool
}

// MARK: - 从一首歌算出来

extension SongRow {

    /// 从一首歌算出一行展示内容 —— **全 App 只有这一处**知道"一首歌显示成什么样"。
    ///
    /// 🔴 为什么是它自己的构造器、而不是每个页面各写一个 `makeRow`：
    /// 曲库页和歌单详情页都要把 `Track` 变成一行。两处各写一遍的话，
    /// 「副标题拼什么、空标题拿什么兜底、音质开关怎么落到这一行上」就有了两份规则 ——
    /// 改一处忘一处，两页显示的歌就会不一样。
    ///
    /// - Parameters:
    ///   - showQuality: 音质开关开着没有。关着 ⇒ 这一行的 `quality` 是 `nil`
    ///     （行那边"有值就画、没有就不画"，不用自己认识那个开关）。
    ///   - showPlayCount: 播放次数**显示**开关开着没有。关着 ⇒ `playCount` 是 `nil`。
    ///     ⚠️ 跟「计不计次数」无关 —— 次数始终在记，这里只决定画不画。
    ///   - isFavorite: 这首歌在不在收藏里。
    ///
    ///     🔴 **不向 `Track` 要**：收藏是另一张表（`Favorite`），不是歌的属性
    ///     （见 `Track.swift` 顶上那段）。它由调用方（VM）拿 `LibraryStore.favoriteTrackIDs`
    ///     判完传进来 —— 行不认识那张表。
    static func make(
        _ track: Track,
        showQuality: Bool,
        showPlayCount: Bool,
        isFavorite: Bool
    ) -> SongRow {
        SongRow(
            id: track.id,
            title: track.title,
            collationText: collationText(for: track),
            subtitle: track.artistAlbumLine,
            artworkPath: track.artworkPath,
            quality: showQuality ? track.audioQualityTag : nil,
            playCount: showPlayCount ? track.playCount : nil,
            isFavorite: isFavorite,
            isMissing: track.missingSince != nil
        )
    }

    /// 归字母段用的文字：歌名有就用歌名，歌名是空的（没标签的音频文件）**用文件名兜底**。
    ///
    /// ⚠️ 只影响分段，**不影响显示** —— 列表那一行还是照原样显示歌名（空就是空）。
    private static func collationText(for track: Track) -> String {
        let trimmed = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? track.fileName : track.title
    }
}

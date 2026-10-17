import Foundation

/// 歌单列表**一行**的展示内容 —— 已经排好版，行拿到它只管往上摆。
///
/// 🔴 跟 `SongRow` 同一条规矩：**不让行直接拿 `Playlist`**。
/// 拿 `Playlist` 的话，行就得自己决定「副标题写什么、封面画哪一档」——
/// 那是**判断**，判断属于页面状态（`PlaylistsViewModel`），不属于行。
///
/// 所以「N 首歌」这句话在 VM 里拼好（曲目数从 `LibraryStore.playlistTrackCounts` 来），
/// 封面在 VM 里判好（`PlaylistCover`），行收到的是两个现成的值。
struct PlaylistRow: Hashable {

    /// 这一行代表哪个歌单 —— 行上那几个动作（改名 / 删除）和
    /// 「拖完把顺序写回去」都靠它认人。
    let id: Playlist.ID

    /// 歌单名。
    let title: String

    /// 副标题（「N 首歌」）。
    let subtitle: String

    /// 封面画哪一档。
    let cover: PlaylistCover

    /// 是不是「最爱的歌曲」那一行。
    ///
    /// ⚠️ **跟 `cover` 不是一回事、不能互相替代**：那一行也可以被挑一张封面图
    /// （那会儿 `cover` 是 `.artwork`），但"能不能删"这件事跟封面画什么无关 ——
    /// 行尾菜单里「删除」要按它置灰。
    let isFavorites: Bool
}

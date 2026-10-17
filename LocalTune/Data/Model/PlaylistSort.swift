import Foundation

/// 歌单列表按什么字段排。
///
/// ⚠️ `String` 原始值就是存在偏好里的那一串 —— 改 case 名 = 改用户盘上的值，
/// **不许随手改**（读不出来的会回到「创建时间」，见 `AppSettings.playlistSortMode`）。
///
/// ⚠️ 声明顺序 = 菜单里的显示顺序。
enum PlaylistSortMode: String, CaseIterable {

    /// 按建单时间。
    case createdAt

    /// 按歌单名。
    case name

    /// 按用户**拖出来的顺序**（`sortIndex`）。
    case manual

    /// 菜单上显示的名字。
    var menuTitle: String {
        switch self {
        case .createdAt: return "创建时间"
        case .name: return "歌单名"
        case .manual: return "手动"
        }
    }
}

/// 把歌单排成给人看的顺序 —— **纯函数**：不碰界面、不碰数据库，能单独测。
///
/// 跟 `SongSort` 是**同一个形状**（镜像比较 + 按传入顺序兜底），只是排的东西不同 ——
/// 所以规矩的说明都写在 `SongSort` 那一段，这儿不重复一遍。
///
/// ⚠️ 「最爱的歌曲」**不归它管**：列表把它单摆一段，永远在最上面（见 `PlaylistsViewModel`）。
enum PlaylistSort {

    /// 排序。
    ///
    /// - Parameters:
    ///   - playlists: 待排的歌单（**不含「最爱的歌曲」**）。顺序有意义：并列时按它兜底。
    ///   - direction: 升序还是降序。⚠️ `mode == .manual` 时**不看它**（见下）。
    static func sorted(
        _ playlists: [Playlist], mode: PlaylistSortMode, direction: SortDirection
    ) -> [Playlist] {
        let comesFirst: (Playlist, Playlist) -> Bool = { lhs, rhs in
            direction == .ascending
                ? isAscending(lhs, rhs, mode: mode)
                : isAscending(rhs, lhs, mode: mode)
        }

        return playlists.enumerated()
            .sorted { lhs, rhs in
                if comesFirst(lhs.element, rhs.element) { return true }
                if comesFirst(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 升序时 `lhs` 是否该排在 `rhs` 前面。
    private static func isAscending(_ lhs: Playlist, _ rhs: Playlist, mode: PlaylistSortMode) -> Bool {
        switch mode {
        case .createdAt:
            return lhs.createdAt < rhs.createdAt

        case .name:
            // 跟歌名同一条：`localizedStandardCompare` 才把「歌单 2」排在「歌单 10」前面。
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending

        case .manual:
            // 🔴 **手动排序没有方向**：顺序是用户拖出来的，升 / 降在这一档上没有意义。
            // 恒返回 `false` ⇒ 整列保持**传进来的顺序**（`allPlaylists` 已经按 `sortIndex` 排好），
            // 靠上面那个 `offset` 兜底稳住。
            //
            // ⚠️ 选到「手动」时，菜单里升降序那两项**置灰**：
            // 它们在这一档上不参与比较，让用户点得动却看不出变化，就是"点了没反应"。
            // 置灰在 `PlaylistsViewController.makeSortMenu` 那一处算（跟打勾同一条命）。
            return false
        }
    }
}

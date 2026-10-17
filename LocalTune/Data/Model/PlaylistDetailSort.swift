import Foundation

/// 歌单详情页里曲目按什么排 —— **只有这三档**（曲库页的 `SongSortMode` 没有「歌单顺序」）。
///
/// 🔴 **不复用 `SongSortMode`**：硬塞一个 `.playlistOrder` 进去，曲库页菜单会多出一项
///（`allCases` 两页共用）。见 `歌单详情页设计.md` §七。
enum PlaylistDetailSortMode: String, CaseIterable {

    /// 歌单里的顺序（`playlist_tracks.position` / 收藏的 `added_at`）。
    case playlistOrder

    /// 按导入时间（`Track.dateAdded`）。
    case importDate

    /// 按歌曲标题。
    case title

    /// 菜单上显示的名字。
    var menuTitle: String {
        switch self {
        case .playlistOrder: return "默认"
        case .importDate: return "导入时间"
        case .title: return "歌曲标题"
        }
    }
}

/// 把歌单详情里的曲目排成给人看的顺序 —— **纯函数**。
///
/// 跟 `SongSort` 同一套规矩（镜像比较 + 传入顺序兜底），字段不同。
enum PlaylistDetailSort {

    static func sorted(
        _ tracks: [Track],
        mode: PlaylistDetailSortMode,
        direction: SortDirection
    ) -> [Track] {
        // 「默认」= 歌单顺序：升序原样，降序整列颠倒。
        if mode == .playlistOrder {
            return direction == .ascending ? tracks : tracks.reversed()
        }

        let comesFirst: (Track, Track) -> Bool = { lhs, rhs in
            direction == .ascending
                ? isAscending(lhs, rhs, mode: mode)
                : isAscending(rhs, lhs, mode: mode)
        }

        return tracks.enumerated()
            .sorted { lhs, rhs in
                if comesFirst(lhs.element, rhs.element) { return true }
                if comesFirst(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func isAscending(_ lhs: Track, _ rhs: Track, mode: PlaylistDetailSortMode) -> Bool {
        switch mode {
        case .playlistOrder:
            return true
        case .importDate:
            return lhs.dateAdded < rhs.dateAdded
        case .title:
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

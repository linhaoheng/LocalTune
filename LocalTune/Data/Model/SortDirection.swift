import Foundation

/// 升序还是降序 —— **曲库列表和歌单列表共用这一个**。
///
/// ⚠️ 它答的是「往哪头排」这一件事，跟「按哪个字段排」无关（那是 `SongSortMode` /
/// `PlaylistSortMode`）。两边各来一个类型，就是同一个概念写两遍 ——
/// 改一处忘一处的时候，两个列表的升降会变成两套规矩。
///
/// ⚠️ 名字里**不带 `Song`**：它已经不是曲库专用的了。
///
/// ⚠️ **声明顺序 = 菜单里的显示顺序**（菜单上是「按降序排序」在前）。
/// 排序菜单直接走 `allCases`，所以别随手调换这两个的先后。
enum SortDirection: String, CaseIterable {

    case descending
    case ascending

    /// 菜单上显示的名字。
    var menuTitle: String {
        switch self {
        case .ascending: return "按升序排序"
        case .descending: return "按降序排序"
        }
    }
}

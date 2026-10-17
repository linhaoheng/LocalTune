import Foundation

/// 曲库列表按什么字段排 —— **只有这两种**（另外几种字段按规格砍掉了）。
enum SongSortMode: String, CaseIterable {

    /// 按导入时间。
    case importDate

    /// 按歌曲标题。
    case title

    /// 菜单上显示的名字。
    var menuTitle: String {
        switch self {
        case .importDate: return "导入时间"
        case .title: return "歌曲标题"
        }
    }
}

/// 把歌排成给人看的顺序 —— **纯函数**：不碰界面、不碰数据库，能单独测。
///
/// 放在数据层而不是页面里：排序规则和"怎么显示"无关，歌单页用的是同一套做法
/// （见 `PlaylistSort`），只是排的东西不同。
enum SongSort {

    /// 排序。
    ///
    /// - Parameters:
    ///   - tracks: 待排的歌。**顺序有意义**：并列时按这个顺序兜底（见下）。
    ///   - direction: 升序还是降序（`SortDirection`，跟歌单列表共用）。
    static func sorted(_ tracks: [Track], mode: SongSortMode, direction: SortDirection) -> [Track] {
        // 「谁该排前面」—— 降序是把两个参数**调个个儿**（镜像），不是把结果取反。
        //
        // ⚠️ 取反（`!comesFirst(a, b)`）会让相等元素互相"小于"对方 ——
        // 那不是合法的严格弱序（strict weak ordering），而 `sorted(by:)` 对
        // 无效比较器的元素顺序**不作保证**。镜像比较没有这个问题。
        let comesFirst: (Track, Track) -> Bool = { lhs, rhs in
            direction == .ascending
                ? isAscending(lhs, rhs, mode: mode)
                : isAscending(rhs, lhs, mode: mode)
        }

        return tracks.enumerated()
            .sorted { lhs, rhs in
                if comesFirst(lhs.element, rhs.element) { return true }
                if comesFirst(rhs.element, lhs.element) { return false }
                // 两个方向都不成立 = 并列 → 按**入库先后**兜底。
                //
                // ⚠️ 这一步不是锦上添花：`sorted(by:)` **不保证稳定**，
                // 而「同一毫秒落库的两首」「空标题的歌」都是整片并列 ——
                // 没有兜底，表现就是"每次打开顺序都不一样"。
                // 传进来的顺序（曲库出口给的）本来就是确定的入库先后。
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 升序时 `lhs` 是否该排在 `rhs` 前面。
    private static func isAscending(_ lhs: Track, _ rhs: Track, mode: SongSortMode) -> Bool {
        switch mode {
        case .importDate:
            return lhs.dateAdded < rhs.dateAdded

        case .title:
            // ⚠️ 用 `localizedStandardCompare`，不能换成 `<`：它按当前语言做**自然序**，
            // 「第 2 首」才排在「第 10 首」前面；普通 `<` 会把「第 10 首」排到前头。
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

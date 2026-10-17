import UIKit

/// 列表的数据源 —— 分段之后有**三件系统要问的事**都在这里回答：
/// 段头写什么、右缘索引条显示哪些字母、点到某个字母该滚到第几段。
///
/// ⚠️ 这三个方法 `UITableViewDiffableDataSource` 自己**都实现了**
/// （核过 SDK 的 `UIKit.swiftinterface`：6494 / 6504 / 6506 行，都是 `@objc open func`），
/// 所以全都要写 `override`，也不用再写 `@objc` —— 那层暴露是继承来的。
final class SongListDataSource: UITableViewDiffableDataSource<String, Track.ID> {

    /// 右缘索引条上要显示哪些字母 —— 空数组 = 整条不显示。
    ///
    /// ⚠️ 给的是**完整字母表**（`A`…`Z` 加 `#`），不是"有内容的那些"：
    /// 这样每个字母永远在同一条的同一个高度上，手指划下去有肌肉记忆。
    /// 代价是索引条看不出某个字母有没有歌（系统那条一律同色）。
    var indexTitles: [String] = []

    /// 索引条上换了字母 —— 转发出去（列表协作者拿它弹屏幕正中那个气泡）。
    ///
    /// ⚠️ 为什么副作用要挂在这儿：**只有这个回调**能知道"索引条被按着 / 划到了哪个字母"，
    /// 系统没有别的公开口子。这里只做转发，界面动作归列表协作者。
    var onIndexTitle: ((String) -> Void)?

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        // 段名兼作段的 id；不分段时只有一段、段名是空串 = 不画段头。
        guard let title = sectionIdentifier(for: section), !title.isEmpty else { return nil }
        return title
    }

    override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        indexTitles.isEmpty ? nil : indexTitles
    }

    override func tableView(
        _ tableView: UITableView,
        sectionForSectionIndexTitle title: String,
        at index: Int
    ) -> Int {
        onIndexTitle?(title)
        // "有内容的段名"就是当前快照里的段 id —— 不用另存一份。
        return SongSections.sectionIndex(
            forIndexTitle: title,
            among: snapshot().sectionIdentifiers
        )
    }
}

import UIKit

/// 把曲库列表按歌名的首字母**分段**（`A`…`Z`，外加一个 `#`）。
///
/// 🔴 **为什么这件事不在数据层、也不在 ViewModel 里**：
/// 分段要用的 `UILocalizedIndexedCollation` 是 **UIKit 的、只能在界面线程上用**。
/// 数据层的规矩是「不 import UIKit」（见 `Track+Display.swift` 顶上那段），
/// ViewModel 那条数据流也不在界面线程的上下文里 —— 所以这一步落在页面侧。
/// （它只**取数据**、不碰任何视图，跟 `AppColor` 里用 `UIColor` 是同一类用法。）
///
/// 效果：
/// - **只在「按标题排序 + 没在搜索」时**分段，别的排序字段是一整段；
/// - 中文歌名按**拼音**归段 —— 这是系统规则，不用自己写；
/// - **降序**：段内的先后先反过来，段的先后再整个反过来（`#` 段跑到最前面）；
///   **索引条也跟着反**（见 `indexTitles(descending:)`）—— 两边方向一致，手指才有位置感。
enum SongSections {

    /// 一段：段名 + 这一段里的行。
    ///
    /// 段名既当列表里的段头文字，也当这一段在差量数据源里的 id。
    struct Section: Equatable {

        /// 段名（`A`…`Z` 或 `#`）。
        let title: String

        let rows: [SongRow]
    }

    /// 完整的字母表（`A`…`Z` 加 `#`，共 27 个）。
    ///
    /// 用的就是分段用的那套系统段名，两边字母一定对得上。
    ///
    /// ⚠️ `private`：外面要的不是这份**原始顺序**，而是"按当前升降序摆好的那一份"——
    /// 见 `indexTitles(descending:)`。
    @MainActor
    private static var allTitles: [String] {
        UILocalizedIndexedCollation.current().sectionTitles
    }

    /// 索引条上要显示的字母表 —— **跟着段的先后走**。
    ///
    /// 降序时段的先后是整个反过来的（`#` 段跑到最前），索引条也跟着反：
    /// 这样"**索引条最上面那个字母**"永远等于"**列表最上面那一段**"，手指的位置感才对得上。
    @MainActor
    static func indexTitles(descending: Bool) -> [String] {
        let titles = allTitles
        return descending ? Array(titles.reversed()) : titles
    }

    /// 分段 —— **只保留有内容的段**（空段不出现）。
    ///
    /// ⚠️ 标了 `@MainActor`：里面的归段工具是 UIKit 的（标了只能在界面线程用）。
    /// 只标需要它的方法 —— `Section` 只是数据，不必跟着绑在主线程上。
    ///
    /// - Parameter descending: 降序时组内、组顺序都反过来。
    @MainActor
    static func group(_ rows: [SongRow], descending: Bool) -> [Section] {
        let collation = UILocalizedIndexedCollation.current()
        let boxes = rows.map(CollationBox.init)

        // 先让系统按它那套语言规则排一遍 —— 这样「同一段里的先后」一定合字母序。
        //
        // ⚠️ 这里**不沿用调用方已经排好的顺序**：我们自己那套排序（`SongSort` 的
        // `localizedStandardCompare`）和这套归段规则在中英混排时**可能给出不同的先后**，
        // 重排一次两者就始终是同一套 —— 段内不会出现「P 排在 A 前面」。
        let sorted = collation.sortedArray(
            from: boxes,
            collationStringSelector: #selector(getter: CollationBox.collationText)
        ) as? [CollationBox] ?? boxes

        var buckets = [[SongRow]](repeating: [], count: collation.sectionTitles.count)
        for box in sorted {
            let index = collation.section(
                for: box,
                collationStringSelector: #selector(getter: CollationBox.collationText)
            )
            guard buckets.indices.contains(index) else { continue }
            buckets[index].append(box.row)
        }

        var sections: [Section] = []
        for (index, bucket) in buckets.enumerated() where !bucket.isEmpty {
            sections.append(
                Section(
                    title: collation.sectionTitles[index],
                    rows: descending ? Array(bucket.reversed()) : bucket
                )
            )
        }

        return descending ? Array(sections.reversed()) : sections
    }

    /// 索引条上点到某个字母 → 该滚到**第几段**（段的下标）。
    ///
    /// 这个字母自己有内容就跳它自己；**没内容就跳到它后面最近的那个有内容的字母**
    /// （跟系统索引条的惯例一致：点一个没东西的字母，往下一段走）。
    ///
    /// ⚠️ 在**字母表**里往后找、再回**当前段顺序**里定位 —— 所以降序时也对：
    /// 降序下段的先后是反的，但"往后找"这件事跟段怎么排没关系。
    ///
    /// - Parameter titles: 当前**有内容的段名**，按它们在列表里出现的先后。
    @MainActor
    static func sectionIndex(forIndexTitle title: String, among titles: [String]) -> Int {
        guard !titles.isEmpty else { return 0 }
        if let exact = titles.firstIndex(of: title) { return exact }

        let alphabet = allTitles
        guard let start = alphabet.firstIndex(of: title) else { return 0 }
        for candidate in alphabet[start...] {
            if let section = titles.firstIndex(of: candidate) { return section }
        }
        // 它后面的字母一个都没内容 —— 落到最后一个有内容的段。
        return titles.count - 1
    }
}

/// `UILocalizedIndexedCollation` 只认 ObjC 对象（它要拿一个 selector 去问「这个归哪一段」），
/// 而 `SongRow` 是 Swift 值类型 —— 所以包一层。
///
/// ⚠️ 它**只在这个文件里存在一下下**：分完段就没用了，不往上层传。
private final class CollationBox: NSObject {

    /// 归段用的文字。名字必须和 `SongSections` 里那个 selector 对得上。
    @objc let collationText: String

    let row: SongRow

    init(_ row: SongRow) {
        collationText = row.collationText
        self.row = row
        super.init()
    }
}

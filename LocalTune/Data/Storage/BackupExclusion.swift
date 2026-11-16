import Foundation

/// 「这个目录不参与 iCloud 备份」这一个动作的**唯一出处**。
///
/// ## 为什么要有这个东西
///
/// 工程里有两个目录需要它，而**理由各不相同**：
/// - `Documents/music/`（用户的歌）—— 是他自己导进来的，可能几十 GB，进备份是纯浪费；
/// - `Library/images/`（封面）—— 能从音频标签重算出来，丢了没有损失。
///
/// 两处**各写一遍**的代价是规矩会走样：一处"只在目录新建时设一次"、另一处"每次存图都确认"，
/// 同一个标记两套态度。收成一个函数之后，两边只可能有一种做法。
///
/// ## 🔴 为什么必须「每次调用都确认」，不能「只在目录新建时设一次」
///
/// 目录**已经在了**的时候（上次设失败 / 从备份恢复回来 / 用户手动建过），
/// "只在新建时设"这条分支**压根不进** ⇒ 这个开关**永远没打开过**。
/// 而设失败本身是**静默的**（外面完全看不出来），所以坏起来没人知道。
///
/// 代价只有一次读：标记是**粘在目录上**的，设一次就对整个目录树有效（见下）。
enum BackupExclusion {

    /// 给一个目录打上「不参与 iCloud 备份」。
    ///
    /// 先读一下再写：打过了就直接返回，不必每次走这条路都落一次盘。
    ///
    /// ⚠️ **不抛错、也不上报**：这件事失败了只是"用户的备份会变大"，
    /// 没有哪个用户需要为它做点什么，我们也做不了什么 —— 下次走这条路会再试一遍。
    /// 所以两处 `try?` 都是**敢吞**的（读的时候目录还不存在也走这条路，
    /// 那时读出来是 `nil`，按"没打过"处理，正好由下面那一步把目录补上标记）。
    static func exclude(_ directory: URL) {
        let alreadyExcluded = (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
            .isExcludedFromBackup == true
        guard !alreadyExcluded else { return }

        var target = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}

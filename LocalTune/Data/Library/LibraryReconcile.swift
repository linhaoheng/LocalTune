import Foundation

/// 「库里的行」和「磁盘上的文件」对不上时，该写哪几行 —— **纯函数：只算，不碰库、不碰磁盘**。
///
/// 原理一句话：🔴 **磁盘是真相，库是索引。** 索引不许假装「我指的这份还在」，
/// 它只有两个诚实的选择 —— 跟着真相走，或者如实标一句「我指的这份现在不在」。
///
/// `ImportService.scanLibrary` 原来只做了**一半**（磁盘有、库没有 → 收进来）；
/// 这里补的是另一半（库有、磁盘没有 → 标上；标过的文件回来了 → 清掉）。
///
/// ## 🔴 两条红线
///
/// 1. **只收「值真的变了」的行。**
///    每次都把全库重写一遍的话，每扫一次就写几千行 ⇒ 观察重跑 ⇒ 整张列表重建，
///    而**绝大多数时候一个字都没变**。所以 `Plan` 里只放真变化 —— 没有变化时它是空的，
///    调用方据此**一行都不写**。
///
/// 2. **「读不进去的目录」不算「文件不在」。**
///    文件在、只是这一趟没读到（权限抖了一下 / 被别的进程占着）。
///    把它标成缺失就是撒谎，而且一次抖动会把**一整个文件夹**的歌标掉。
enum LibraryReconcile {

    /// 对账要的那一份投影。
    ///
    /// ⚠️ **刻意不带 `lyrics`**：全库的歌词进内存是纯浪费，而对账只要这三个值。
    struct Entry: Equatable {

        let id: Track.ID

        /// 相对 `Documents/music` 的路径（跟 `Track.path` 同一个口径）。
        let path: String

        /// 这一行现在**有没有**缺失标记。
        let isMissing: Bool
    }

    /// 这一趟要写哪几行。
    ///
    /// ⚠️ `isEmpty` 为真时调用方**必须一行都不写**（红线 1）—— 那正是"库里没有变化"的意思。
    struct Plan: Equatable {

        var markMissing: [Track.ID] = []

        var clearMissing: [Track.ID] = []

        var isEmpty: Bool { markMissing.isEmpty && clearMissing.isEmpty }
    }

    /// 算出这一趟要写哪几行。
    ///
    /// 逐行判，**三个分支的顺序不能换**：
    ///
    /// | 情况 | 判 | 为什么 |
    /// |---|---|---|
    /// | 路径在 `presentPaths` 里 | 文件在 ⇒ 有标记就清 | 文件回来了，标记该走 |
    /// | 不在，但落在某个 `unreadablePrefixes` 下 | **不判**（既不清也不标） | 读不进去 ≠ 不在（红线 2） |
    /// | 其余 | 文件不在 ⇒ 没标记就标 | |
    ///
    /// - Parameters:
    ///   - presentPaths: 这一趟**真的枚举到**的音频文件的相对路径。
    ///   - unreadablePrefixes: 这一趟**读不进去**的子目录的相对路径。它们底下的行一律不动。
    ///   - entries: 库里现在的每一行（见 `LibraryStore.reconcileEntries`）。
    static func plan(
        presentPaths: Set<String>,
        unreadablePrefixes: Set<String>,
        entries: [Entry]
    ) -> Plan {
        var plan = Plan()
        for entry in entries {
            if presentPaths.contains(entry.path) {
                if entry.isMissing { plan.clearMissing.append(entry.id) }
                continue
            }
            if isUnderAny(unreadablePrefixes, path: entry.path) { continue }
            if !entry.isMissing { plan.markMissing.append(entry.id) }
        }
        return plan
    }

    // MARK: - 「整机恢复」的判据

    /// 缺得太多 ⇒ 这**不是**「个别文件没了」，是「整个音乐目录不在本机」。
    ///
    /// 换手机恢复之后就是这个样子：库文件在 `Application Support`（**进备份**）⇒ 回来了；
    /// 音乐目录 `Documents/music/`（**排除备份**，见 `BackupExclusion`）⇒ 没有。
    /// 于是**全库**都成了缺失行 —— 那时候该给用户一条横幅解释一句，
    /// 而不是让他面对一屏灰行、以为曲库坏了。
    ///
    /// ⚠️ 它**只决定「要不要给一条横幅」**，**不影响写库** —— 库照实记。
    static func looksLikeWholeLibraryMissing(missing: Int, total: Int) -> Bool {
        guard total > 0, missing >= wholeLibraryMissingMinimum else { return false }
        return Double(missing) / Double(total) >= wholeLibraryMissingRatio
    }

    /// 比例阈值：**过半**。
    private static let wholeLibraryMissingRatio = 0.5

    /// 绝对下限 —— 🔴 **必须有**：一个 5 首的曲库缺 3 首也过 60%，
    /// 但那是「个别文件没了」，不是「整个目录不在本机」。
    private static let wholeLibraryMissingMinimum = 20

    // MARK: - 私有

    /// 这一条路径是不是落在某个「读不进去的目录」底下。
    ///
    /// ⚠️ 前缀比对**必须带上那个 `/`**：光比字符串的话，
    /// 读不进去的 `Album 1` 会把好好的 `Album 10` 也算成"在它底下"。
    private static func isUnderAny(_ prefixes: Set<String>, path: String) -> Bool {
        prefixes.contains { path.hasPrefix($0 + "/") }
    }
}

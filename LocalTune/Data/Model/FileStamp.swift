import Foundation

/// **文件记号** —— 二次扫描提速用。
///
/// 扫完记下每首歌的「文件大小 + 最后修改时间」，下次先比这个：**没变过就不读文件内容**。
/// 否则每扫一次都要把整首歌读一遍算指纹 —— 无损音乐一首几十上百 MB，几千首就是灾难。
///
/// ⚠️ 修改时间存**微秒整数（`Int64`）**，不用 `Date`：
/// 微秒保留亚秒精度，而且存进 SQLite 的 INTEGER 取回来**还是那个数**。
/// 用 `Date` 的话只编到毫秒，而文件修改时间的精度更高 —— 取回来永远不相等，
/// 于是每次都误判成「文件变过」，提速彻底失效。
struct FileStamp: Equatable, Sendable {

    /// 文件大小（字节）。
    let fileSize: Int64?

    /// 最后修改时间，**微秒**整数（Unix 时间戳）。
    let fileModificationDate: Int64?

    /// 从磁盘上读一个文件的记号 —— 读的是**磁盘现在**的大小和时间。
    ///
    /// 🔴 **读之前先把这个 URL 实例缓存过的属性值扔掉**，不扔就会读到**上一次**读到的值。
    ///
    /// `resourceValues(forKeys:)` 的规矩是「**先看这个 URL 自己缓存过没有**，有就直接给」
    /// （SDK 头文件原话）。而这份缓存**只在主线程**才会被自动清掉（下次 run loop 跑的时候）——
    /// 我们这两处读都在后台队列上，所以缓存**永远不清**：编辑器打开时用**同一个 `fileURL`**
    /// 读过一次「文件大小」，之后才把标签写回文件，这里再读回来就是**改之前**的记号。
    /// （实测：文件 100 字节 → 写成 150，同一个 URL 再读 = 100；
    /// 扔掉缓存才 = 150 —— 连 `contentModificationDate` 也一起是旧的。）
    ///
    /// 后果：库里记着一份**不存在的文件状态**，扫描就判「这个文件变过」，
    /// 把一次刷新报成「已导入」（见 `TrackImporter.needsMetadataRefresh`）。
    ///
    /// ⚠️ 缓存挂在这个 URL **底下**（不是副本自己的）⇒ 从副本上清，调用方那个实例的缓存也一起清掉。
    /// 所以调用方什么都不用做，**这两行就是唯一的防线**。
    static func read(_ url: URL) throws -> FileStamp {
        var scratch = url
        scratch.removeAllCachedResourceValues()
        let values = try scratch.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileStamp(
            fileSize: values.fileSize.map(Int64.init),
            fileModificationDate: modificationTimestamp(values.contentModificationDate)
        )
    }

    /// `Date` → 微秒整数。
    static func modificationTimestamp(_ date: Date?) -> Int64? {
        guard let date else { return nil }
        return Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }
}

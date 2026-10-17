import Foundation

/// 递归扫一个目录，把里面的音频文件找出来。
///
/// 结果**按文件名排序**（用 `localizedStandardCompare`，所以「第 2 首」会排在「第 10 首」前面）。
///
/// 空目录是正常情况（空曲库），**不抛错**，返回空的 `audioFiles`；
/// 只有**根目录本身打不开**才抛 `ScanError.enumerationFailed`。
enum LocalAudioScanner {

    enum ScanError: Error {
        /// 根目录打不开（不存在、没权限、或者那根本不是个目录）。
        case enumerationFailed
    }

    /// 一趟扫描的结果。
    struct ScanOutcome: Equatable, Sendable {

        /// 扫到的音频文件。
        let audioFiles: [URL]

        /// **读不进去**、被跳过的子目录。
        ///
        /// 🔴 它必须跟「空目录」分开带出来：不报这个数，用户就会以为
        /// 「扫完了、就这些歌」，而其实有一整个文件夹的歌没进来 ——
        /// **沉默的失败 = 用户以为做完了，其实没做完。**
        let unreadableFolders: [URL]
    }

    /// 扫出目录下所有能导入的音频文件。
    static func collectAudioFiles(in folderURL: URL) throws -> ScanOutcome {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .nameKey]

        // 读不进去的子目录攒在这儿（`errorHandler` 是**非逃逸**闭包，可以直接往外面这个
        // 局部变量里写；枚举本身是串行的，一行一个回调，所以不需要锁）。
        var unreadableFolders: [URL] = []

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            // 枚举途中撞上读不进去的子目录时**继续走完**，不整趟中断 ——
            // `return true` 就是「跳过这一个，接着下一个」。
            //
            // ⚠️ **跳过要记账**：那个目录里可能有整张专辑的歌，不记下来就等于
            // 「读不进去」和「本来就没歌」长得一模一样。
            errorHandler: { url, _ in
                unreadableFolders.append(url)
                return true
            }
        ) else {
            throw ScanError.enumerationFailed
        }

        var audioFiles: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            // 🔴 逐个文件地防御：单个文件 stat 不出来（正在被写入、权限抖一下、
            // 网盘占位文件还没下下来）就跳过它 —— **不能把整趟扫出来的结果一起丢掉**。
            // 早先这里是包住整趟枚举的一个 `try`：一个文件 stat 不出来，
            // 它前面和后面已经找到的文件会一起被丢掉，曲库每次都在同一个地方停下。
            // 敢吞 `try?` 这一下：丢一个读不出的文件、下次扫还能找回来；整趟结果丢了不可恢复 ——
            // 按「宁可少扫一个、也不清空一列」吞掉，直接跳过它。
            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { continue }
            guard values.isRegularFile == true, AudioFileTypes.isSupported(fileURL) else { continue }
            audioFiles.append(fileURL)
        }

        audioFiles.sort {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return ScanOutcome(audioFiles: audioFiles, unreadableFolders: unreadableFolders)
    }
}

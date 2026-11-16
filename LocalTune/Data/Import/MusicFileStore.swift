import Foundation

/// `Documents/music/` 这个目录本身，加上「把外面的文件安全地拷进来」这件事。
///
/// 放 `Documents` 而不是 `Caches`：这些是**用户自己的歌**，不能在存储紧张时被系统回收。
///
/// ⚠️ 读沙盒外的文件要先开安全域，`start` / `stop` **必须成对**（见 `withSecurityScope`）。
enum MusicFileStore {

    /// 音乐文件的目录：`Documents/music/`。
    static var musicDirectory: URL {
        URL.documentsDirectory.appending(path: "music", directoryHint: .isDirectory)
    }

    /// 确保目录存在并返回它。
    ///
    /// **每次**都确认这个目录不参与 iCloud 备份：导入的音频可能几十上百 GB，
    /// 而真正值得备份的是曲库数据库（歌单、收藏那些"用户攒出来的东西"）——
    /// 音频本身丢了还能重新导入。
    ///
    /// ⚠️ **不能只在"目录新建时"设一次**（早先就是这么写的）：目录已经在了的时候
    /// 那条分支压根不进，这个开关就**永远没打开过** —— 而设失败是静默的，坏起来没人知道。
    /// 详见 `BackupExclusion.exclude`。
    @discardableResult
    static func ensureMusicDirectory() throws -> URL {
        let directory = musicDirectory
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        BackupExclusion.exclude(directory)
        return directory
    }

    /// 给新拷进来的文件挑一个**不冲突**的目标路径，重名自动加 " 2" / " 3"。
    ///
    /// ⚠️ **不能"重名就跳过"** —— 那会把用户选的文件悄悄丢掉。
    /// ⚠️ 也**不能"先删同名文件再拷"** —— 那是直接删用户的歌。所以是"另起一个名字"。
    static func uniqueDestination(for fileName: String) throws -> URL {
        let directory = try ensureMusicDirectory()
        let first = directory.appending(path: fileName)
        guard !FileManager.default.fileExists(atPath: first.path(percentEncoded: false)) else {
            return uniqueDestination(for: fileName, in: directory)
        }
        return first
    }

    private static func uniqueDestination(for fileName: String, in directory: URL) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension
        let extensionSuffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"

        var index = 2
        while true {
            let candidate = directory.appending(path: base + " \(index)" + extensionSuffix)
            if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
            index += 1
        }
    }

    /// `music/` 里是不是已经躺着一份**同名又同内容**的？是就返回它。
    ///
    /// 两种情况会走到这儿：① 删除时选了「只删库」的话，文件会留在 `music/` 里变成孤儿；
    /// ② 用户把同一个文件又选了一遍。两种都是"想把这个文件放回库里" ——
    /// 认出那一份、直接收进库就行，不该再拷一份（用户看到的是「我就重新导入同一首，
    /// 怎么多出来一份」）。
    ///
    /// ⚠️ **判据是「同名 + 同内容」两个都要**：名字对上才可能是同一个文件；
    /// 内容对上才敢确定没认错（同名不同内容 = 这个位置已经换成别的歌了，那就该照常拷一份新的）。
    ///
    /// ⚠️ **只比"同名"那一个文件，不遍历整个目录**：遍历要哈希全库，代价太大。
    /// 而这两条路进来的名字一定是一样的。
    ///
    /// 这里回答的是"同一个文件还在不在"（同名同内容），
    /// 「两首歌算不算同一首」归 `ImportDuplicatePolicy`。
    static func reusableCopy(ofFileName fileName: String, matching fingerprint: String) -> URL? {
        let candidate = musicDirectory.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) else {
            return nil
        }
        // ⚠️ 敢吞 `try?` 这一下：指纹算不出来就当"这个副本**不可复用**"（返回 nil ⇒ 上层重新拷一份）。
        // 算不出指纹说明这个文件读不了 / 已损坏 —— 宁可重拷一遍，也不能把一个读不了的文件复用进来。
        guard let candidateFingerprint = try? FileFingerprint.sha256(of: candidate),
              candidateFingerprint == fingerprint
        else {
            return nil
        }
        return candidate
    }

    static func copy(from source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// `Track.path` 存的是**相对 `Documents/music`** 的路径 —— 不是绝对路径。
    ///
    /// 绝对路径不能进库：iOS 的沙盒容器路径每次重装 / 更新都会变，
    /// 存了绝对路径的话，每次更新完库里所有歌的身份全变（见 `TrackIdentity`）。
    static func relativePath(of url: URL) -> String {
        let root = musicDirectory.standardizedFileURL.path(percentEncoded: false)
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(root + "/") else {
            // 走到这里 = 有人把 **music/ 之外**的文件传进来了。这个函数的契约是只收
            // music/ 里的文件，兜底拿文件名顶上是个**危险的假答案**：
            // 相对路径直接决定一首歌的主键（见 `TrackIdentity`），两个不同文件夹里的
            // 同名文件会算出**同一个主键** —— 两行数据悄悄互相顶掉，而且不报错。
            //
            // 所以开发期当场炸出来（真机上不崩、只报一条，不影响线上行为）；
            // 线上保持原来的兜底，程序不至于因为一个坏输入直接死掉。
            assertionFailure("relativePath 只该收 music/ 目录里的文件，收到了：\(path)")
            return url.lastPathComponent
        }
        return String(path.dropFirst(root.count + 1))
    }

    /// 相对路径 → 磁盘上的位置。
    static func resolve(relativePath: String) -> URL {
        musicDirectory.appending(path: relativePath)
    }

    /// `music/` 里这一相对路径现在有没有文件。
    static func fileExists(relativePath: String) -> Bool {
        guard !relativePath.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: resolve(relativePath: relativePath).path(percentEncoded: false)
        )
    }

    /// 磁盘上这一份的**文件记号**（大小 ＋ 修改时间）；读不到就记「不知道」（空值）。
    ///
    /// 🔴 **全工程只有这一份**这个表达式。调用方各自读一次、然后从头传到尾：
    /// 「扫描」路在开头读一次，「打开文件」路在拷完之后对**目标文件**读一次，
    /// 编辑元数据在写完标签之后对**同一个文件**读一次（见 `TrackEditorViewModel.writeTags`）。
    ///
    /// ⚠️ 读不出记号**不让它毁掉这一首**：记号只服务「这个文件变过没有」这一次快速比对
    /// （`TrackImporter.needsMetadataRefresh`），缺了顶多重算一次。
    static func stamp(of url: URL) -> FileStamp {
        // 敢吞 `try?` 这一下：读不到记号就记「不知道」（空值），见上。
        (try? FileStamp.read(url)) ?? FileStamp(fileSize: nil, fileModificationDate: nil)
    }

    /// 删掉这一行指向的音频文件，返回「到底删掉没有」。
    ///
    /// 文件本来就不在、或者删不掉（权限 / 被别的进程占着）时返回 `false`，
    /// **不当成错误、也不上报**：对调用方来说这两种情况都是「这个文件现在动不了」，
    /// 库里那一行该删还是照删。
    @discardableResult
    static func delete(relativePath: String) -> Bool {
        let url = resolve(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    /// 沙盒外的 URL 要 `startAccessing` 才能读，用完**必须** `stop`。
    ///
    /// `defer` 保证成对 —— 抛错的那条路上也得放掉。
    static func withSecurityScope<T>(_ url: URL, operation: () async throws -> T) async throws -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        return try await operation()
    }
}

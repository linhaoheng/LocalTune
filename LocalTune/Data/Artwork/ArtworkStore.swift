import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 封面：三处目录、两种性质 ——
/// - `Library/images/`：标签封面 + 歌单拼图，**缓存**（能重建、排除备份）；
/// - `Library/custom/`：歌曲手挑的图，**数据**（删了就没了、**要进备份**）；
/// - `Library/covers/`：歌单手挑的图，**数据**（删了就没了、**要进备份**）。
///
/// 库里路径：
/// - `Track.artworkPath`：标签封面只存文件名；手挑存 `custom/<文件名>`；
/// - `Playlist.artworkPath`：**这个歌单当前显示的那张** —— 手挑的带 `covers/` 前缀（**数据**），
///   生成的拼图是裸文件名、落 `images/`（**缓存**）。🔴 **两档都进库**：界面画什么只由库决定
///   （磁盘上的东西不在观察流的失效条件里，让界面去磁盘上猜，值就永远晚一拍）。
///
/// ⚠️ 标签封面入参用 `Data` 保留**原始字节**，不做 jpeg 重压缩 ——
/// `jpegData(compressionQuality:)` 是有损的，这里要的是"原样保存那份封面"。
/// 手挑封面另走 `saveCustom` / `savePlaylistCover`：会先缩边再压成 JPEG（相册图常很大）。
///
/// ## 「算名字」和「落盘」为什么是两步（标签封面）
///
/// 名字要在**写库之前**就填进 `Track.artworkPath`，而那时候图还没写到盘上。
/// 所以先有纯计算的 `artworkFileName(for:named:)`，落盘是紧跟着的单独一步。
enum ArtworkStore {

    /// 封面文件的大小上限 —— 超过就不存。
    ///
    /// 内嵌封面偶尔是整页扫描图，动辄几十 MB。存下来只是白占沙盒、拖慢列表，
    /// 而标签封面本来就是**缓存**，没有它这首歌照样能用。
    static let maximumArtworkBytes = 20 * 1024 * 1024

    /// 歌曲手挑封面写入库路径时的目录前缀 —— `Track.artworkPath` 长成 `custom/….jpg`。
    static let customPathPrefix = "custom/"

    /// 歌单手挑封面写入库路径时的目录前缀 —— `Playlist.artworkPath` 长成 `covers/….jpg`。
    static let coversPathPrefix = "covers/"

    /// 封面名字里那段**内容指纹**取前几位。
    private static let contentTagLength = 8

    /// 标签封面 + 歌单拼图：`Library/images/`（缓存，排除备份）。
    static var imagesDirectory: URL {
        URL.libraryDirectory.appending(path: "images", directoryHint: .isDirectory)
    }

    /// 歌曲手挑封面：`Library/custom/`（**数据**，要进备份 —— **不**打排除标记）。
    static var customDirectory: URL {
        URL.libraryDirectory.appending(path: "custom", directoryHint: .isDirectory)
    }

    /// 歌单手挑封面：`Library/covers/`（**数据**，要进备份 —— **不**打排除标记）。
    ///
    /// 🔴 跟 `custom/` 分开：歌曲手挑和歌单手挑是两件东西；混在一个目录里，
    /// 清某一类时容易误伤另一类。
    static var coversDirectory: URL {
        URL.libraryDirectory.appending(path: "covers", directoryHint: .isDirectory)
    }

    /// 这条路径是不是歌曲手挑的封面。
    static func isCustomArtworkPath(_ artworkPath: String) -> Bool {
        artworkPath.hasPrefix(customPathPrefix)
    }

    /// 这条路径是不是歌单手挑的封面。
    static func isPlaylistCoverPath(_ artworkPath: String) -> Bool {
        artworkPath.hasPrefix(coversPathPrefix)
    }

    /// 这几个字节存下来该叫什么名字 —— **纯计算，不碰磁盘**。
    ///
    /// 名字 = `一首歌的标识` + `-` + `内容指纹前 8 位` + `.` + 扩展名。
    ///
    /// 🔴 **为什么要带内容指纹**：判据是「**封面文件的名字，必须是它内容的函数**」——
    /// 内容一变名字就变，于是三件事一起成立（**一处改动，不是三处兜底**）：
    /// - **换了封面马上看得到新图**：名字变了 ⇒ 缓存键变了（键里带文件名）⇒ 拿到的必然是新图。
    ///   所以 `save` 里**不需要**再加"存完清一次缓存"那种第二处保险；
    /// - **扩展名不会说谎**：扩展名跟着**这次的内容**重算，png 换成 jpg 时名字一起换。
    ///   （反过来说：沿用旧名字就等于让新字节顶着旧扩展名，正是这个文件顶上反对的事。）
    /// - **反复存同一张不会累积**：内容一样 ⇒ 名字一样 ⇒ 覆盖同一份。
    ///
    /// 前半段用 `Track.id`（**路径**的 SHA256），**不用音频文件名**：用文件名有两个麻烦 ——
    /// ① **会重名**：`music/rock/song.mp3` 和 `music/pop/song.mp3` 都叫 `song`
    ///    （扫描是递归的，子目录里的文件能同时存在），按文件名算的话后者会把前者的封面覆盖掉；
    /// ② 同一个文件在子目录之间挪动，名字就白变一次，封面要重存。
    ///
    /// ⚠️ 名字变了以后，**旧那份封面由调用方删掉**（见 `TrackImporter.save`）——
    /// 不删的话，每换一次封面就在 `Library/images/` 里留一个没人认领的孤儿。
    ///
    /// 认不出格式就返回 `nil`，**不猜**：系统都认不出的字节基本不是图片，存下去只是垃圾。
    ///
    /// ⚠️ 放弃存盘时**不记日志、也不上报** —— 封面是缓存，没有它这首歌照样能用，
    /// 没有任何人需要为此做点什么。
    static func artworkFileName(for data: Data, named name: String) -> String? {
        guard data.count <= maximumArtworkBytes else { return nil }
        guard let fileExtension = fileExtension(for: data) else { return nil }
        let contentTag = FileFingerprint.sha256(of: data).prefix(contentTagLength)
        return "\(name)-\(contentTag).\(fileExtension)"
    }

    /// 把标签封面写进 `imagesDirectory`（`Library/images/`）。
    ///
    /// **不返回成败、也不抛错** —— 标签封面是**缓存**、不是权威数据，写失败只是这首歌暂时没图，
    /// 它不配让整首歌算失败。
    static func save(_ data: Data, as fileName: String) {
        let directory = prepareImagesDirectory()
        // 敢吞 `try?` 这一下：标签封面是**缓存**（见上），写失败只让这首歌暂时没图，
        // 不配让整首导入算失败 —— 也不给用户报错。
        try? data.write(to: directory.appending(path: fileName), options: .atomic)
    }

    /// 把用户手挑的图落到 `Library/custom/`，返回写进 `Track.artworkPath` 的路径（带 `custom/` 前缀）。
    ///
    /// 失败返回 `nil`（认不出图 / 超限 / 写盘失败）—— 调用方应提示用户，**不要**假装换成了。
    ///
    /// 🔴 **这个目录要进备份**（手挑的图删了就没了），所以**不**打 `BackupExclusion`。
    static func saveCustom(_ data: Data, named trackID: String) -> String? {
        guard let fileName = artworkFileName(for: data, named: trackID) else { return nil }
        let directory = prepareCustomDirectory()
        let fileURL = directory.appending(path: fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }
        return customPathPrefix + fileName
    }

    /// 把歌单手挑的图落到 `Library/covers/`，返回写进 `Playlist.artworkPath` 的路径（带 `covers/` 前缀）。
    ///
    /// 失败返回 `nil` —— 调用方应提示用户，**不要**假装换成了。
    ///
    /// 🔴 **这个目录要进备份**（手挑的图删了就没了），所以**不**打 `BackupExclusion`。
    /// 名字带内容指纹：换图 ⇒ 名字变 ⇒ 缓存键变，不必另清缓存。
    static func savePlaylistCover(_ data: Data, playlistID: Playlist.ID) -> String? {
        guard let fileName = artworkFileName(for: data, named: playlistID.uuidString) else { return nil }
        let directory = prepareCoversDirectory()
        let fileURL = directory.appending(path: fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }
        return coversPathPrefix + fileName
    }

    /// 拼图文件名里那一段前缀 —— 后面接歌单 id。
    ///
    /// ⚠️ 它**不是** `covers/` 那种目录前缀：拼图是裸文件名，`url(forArtworkPath:)` 兜底落 `images/`。
    private static let collageNamePrefix = "playlist-collage-"

    /// 把拼图的 JPEG 字节落到 `Library/images/`，返回写进 `Playlist.artworkPath` 的文件名。失败返回 `nil`。
    ///
    /// ⚠️ **收字节不收图**：缩边 / 压 JPEG / 拼图是**画布**的活儿，
    /// 在 `Core/UI/CoverImageWriter`；这儿只管「把字节写进那个名字」。
    ///
    /// 🔴 **名字跟内容走**（跟手挑封面同一条规矩）：内容一变名字就变 ⇒ 缓存键跟着变、拿到的必然是新图，
    /// 所以**不需要**再"存完清一次缓存"；而且「重新生成」只有内容真变了才改库 ——
    /// 库里的值于是能**完整**决定界面画什么（固定名字做不到这一点：内容变了名字没变，
    /// 库就以为什么都没发生）。
    static func savePlaylistCollage(_ data: Data, playlistID: Playlist.ID) -> String? {
        guard let fileName = artworkFileName(
            for: data, named: collageNamePrefix + playlistID.uuidString
        ) else {
            return nil
        }
        let directory = prepareImagesDirectory()
        do {
            try data.write(to: directory.appending(path: fileName), options: .atomic)
        } catch {
            return nil
        }
        return fileName
    }

    /// 删掉一个歌单的封面文件。
    ///
    /// 删歌单时调：库行没了，那份文件就没人认领。
    ///
    /// ⚠️ **只删库里记的那一份**：手挑的和拼图都走 `Playlist.artworkPath`，
    /// 而"换封面"那两条路都会顺手删掉被换下来的旧文件（见 `PlaylistCoverService`）——
    /// 所以盘上不会留下没人认领的孤儿。
    static func deletePlaylistCoverAssets(artworkPath: String?) {
        delete(artworkPath: artworkPath)
    }

    /// 确保标签封面目录在、且**不参与 iCloud 备份**。
    private static func prepareImagesDirectory() -> URL {
        let directory = imagesDirectory
        // 敢吞：目录已在 / 竞态建过都无所谓；建失败则随后 write 也会失败，save 本身已声明不抛。
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        BackupExclusion.exclude(directory)
        return directory
    }

    /// 确保歌曲手挑封面目录在。**不**排除备份。
    private static func prepareCustomDirectory() -> URL {
        let directory = customDirectory
        // 敢吞：同 `prepareImagesDirectory`；随后 `saveCustom` 的 write 失败会返回 nil 给调用方。
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 确保歌单手挑封面目录在。**不**排除备份。
    private static func prepareCoversDirectory() -> URL {
        let directory = coversDirectory
        // 敢吞：同 `prepareImagesDirectory` / `prepareCustomDirectory` —— 目录已在或竞态建过都无所谓；
        // 真建不出 ⇒ 随后 `savePlaylistCover` 的 write 会失败、返回 `nil` 交给调用方去提示。
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func url(forArtworkPath artworkPath: String) -> URL {
        if isCustomArtworkPath(artworkPath) {
            let fileName = String(artworkPath.dropFirst(customPathPrefix.count))
            return customDirectory.appending(path: fileName)
        }
        if isPlaylistCoverPath(artworkPath) {
            let fileName = String(artworkPath.dropFirst(coversPathPrefix.count))
            return coversDirectory.appending(path: fileName)
        }
        return imagesDirectory.appending(path: artworkPath)
    }

    /// `Track.artworkPath` 记的那个文件，还在不在。
    static func exists(artworkPath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: url(forArtworkPath: artworkPath).path(percentEncoded: false)
        )
    }

    /// 删掉一张封面。
    ///
    /// ⚠️ **文件和内存缓存都要清**：只删文件的话，那张图还在缓存里，
    /// 同一个文件名再出现时（重存 / 重新导入）会画出**上一张**图。
    @discardableResult
    static func delete(artworkPath: String?) -> Bool {
        guard let artworkPath, !artworkPath.isEmpty else { return false }
        // ⚠️ 缓存键带尺寸（一个文件可能同时有 45 / 600 好几份），而 `NSCache` **没法遍历**、
        // 也就没法"只踢掉这一个文件的那几份" ⇒ 整层清掉。
        // 删封面是低频操作，清完下次要图重读一遍盘就是了。
        ThumbnailLoader.invalidateCache()

        let fileURL = url(forArtworkPath: artworkPath)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }

    /// 这几个字节是哪种图片格式 —— **问系统**，不猜魔数。
    private static func fileExtension(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source)
        else {
            return nil
        }
        return UTType(type as String)?.preferredFilenameExtension
    }
}

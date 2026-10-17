import Foundation

/// 歌单封面「换一张 / 生成一张」的**编排** —— 那两条顺序只在这一处。
///
/// 🔴 **为什么它不住在 `LibraryStore`**：宪法 §三·顺序 1 明写
/// 「`LibraryStore` 只碰库，`MusicFileStore` / `ArtworkStore` 只碰文件；顺序由一处定」。
/// 而「先落盘 → 再写库 → 库没写成就撤掉刚落的文件」这套顺序**两头都碰**，
/// 放进只许碰库的那一边就是越界。它是 `Data` 层的**编排者**，跟
/// `TrackImporter`（导入）/ `TrackRemover`（删除）同一角色。
///
/// ## 两条路的顺序都不能反
///
/// - **手挑**：先落盘 → 写库 → 写库失败就**撤掉刚落的那份**
///   （不留「盘上有图、库里没路径」的孤儿）；
/// - **生成**：先落拼图 → **成了**再写库（反过来的话拼图一失败，当前封面没了、盘上也没新图）。
///
/// 🔴 **两条路写的是同一列**（`Playlist.artworkPath` = 当前封面）—— 换封面是一次**真状态变化**，
/// 观察流自己就会重推，**不需要任何"硬推一把"的补丁**。
/// 界面那边也只认这一列（`PlaylistCover` 不碰磁盘）。
///
/// ## 它一个字都不提 `UIImage`
///
/// 两条路都是**收字节**：像素那一段（缩边 / 压 JPEG / 拼图）在
/// `Core/UI/CoverImageWriter`，由**装配层**（`App/AppArtwork`）以闭包注入进来。
/// 这一层于是只认「一串字节」和「一串路径」—— 数据层不该知道画布。
final class PlaylistCoverService {

    private let library: LibraryStore

    /// 「这串封面路径 → 一张拼图的 JPEG 字节」——**画布那一段**（`Core/UI`）的动作。
    ///
    /// 🔴 收尾拼图这一步以前是直接调 `CoverCollage`（那时它住在 `Data`）。
    /// 像素活儿搬走之后，这里改成**收一个动作**：调用方（`App/AppArtwork`）是唯一
    /// 同时认识 `Data/Artwork`（路径从哪来）和 `Core/UI`（画布怎么画）的地方。
    typealias CollageBuilder = (_ artworkPaths: [String]) -> Data?

    private let buildCollage: CollageBuilder

    init(library: LibraryStore, buildCollage: @escaping CollageBuilder) {
        self.library = library
        self.buildCollage = buildCollage
    }

    // MARK: - 手挑

    /// 用户手挑一张歌单封面 → 落 `Library/covers/` + 写 `artwork_path`。
    ///
    /// 🔴 **不学"只落盘、不写库、列表靠『文件在不在』猜"** 那套。
    /// 手挑是**数据**（落 `covers/`）、拼图是**缓存**（落 `images/`）—— 但**两档都写这一列**，
    /// 界面画什么只由库决定（见本类顶上那段）。
    ///
    /// ⚠️ **文件先落、库后写**：写库失败（歌单没了）就把刚落的文件撤掉并抛错 ——
    /// 不许留下「盘上有图、库里没路径」的孤儿。
    ///
    /// - Parameter data: 已经压好的 JPEG 字节（`CoverImageWriter.jpegDataForCustomCover` 的产物）。
    /// - Throws: 存不上 / 写库失败 / 歌单已不在。
    func applyPicked(_ data: Data, playlistID: Playlist.ID) throws {
        guard try library.playlist(id: playlistID) != nil else {
            throw PlaylistCoverError.playlistMissing
        }
        guard let newPath = ArtworkStore.savePlaylistCover(data, playlistID: playlistID) else {
            throw PlaylistCoverError.cannotSave
        }

        let oldPath: String?
        do {
            oldPath = try library.writeCoverPath(newPath, playlistID: playlistID)
        } catch {
            // 库没写成 ⇒ 刚落的那份没有主人，撤掉。
            ArtworkStore.delete(artworkPath: newPath)
            throw error
        }

        // 旧文件跟新文件名不同才删（内容指纹变了名字才变）；同名说明覆盖了同一份。
        if let oldPath, oldPath != newPath {
            ArtworkStore.delete(artworkPath: oldPath)
        }
    }

    // MARK: - 生成拼图

    /// 生成拼图封面 → 落 `Library/images/` 缓存 → **把这一列写成它**。
    ///
    /// 缩略图 + 拼图 + 写盘在**后台**（主线程只点菜单）；`completion` 回主线程。
    /// 源图按歌单顺序凑满 `CoverCollage.maxTileCount` 张就停 —— 不必整单缩略。
    ///
    /// - success(`true`) = 已生成；success(`false`) = 没有带封面的歌（「无法生成封面」）；
    /// - failure = 写盘失败等。
    func generate(
        playlistID: Playlist.ID,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Bool, Error>
            do {
                result = .success(try self.generateSync(playlistID: playlistID))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    // MARK: - 私有

    /// 后台线程上的生成本体 —— 只给上面的异步入口用。
    private func generateSync(playlistID: Playlist.ID) throws -> Bool {
        let tracks = try library.tracks(in: playlistID)
        // 只收**有图的歌**的路径，按歌单顺序 —— 凑不满几格是 `buildCollage` 那边的事。
        let paths = tracks.reduce(into: [String]()) { result, track in
            guard let path = track.artworkPath, !path.isEmpty else { return }
            result.append(path)
        }
        guard let data = buildCollage(paths) else { return false }

        // 先落拼图：失败则当前封面原状不动。
        guard let fileName = ArtworkStore.savePlaylistCollage(data, playlistID: playlistID) else {
            throw PlaylistCoverError.cannotSave
        }

        // 拼图就是「当前封面」—— 写这一列，界面才会换过来（库一写，观察流自然重推）。
        let oldPath: String?
        do {
            oldPath = try library.writeCoverPath(fileName, playlistID: playlistID)
        } catch {
            // 库没写成（歌单没了）⇒ 刚落的那份没有主人，撤掉。
            ArtworkStore.delete(artworkPath: fileName)
            throw error
        }
        if let oldPath, oldPath != fileName {
            ArtworkStore.delete(artworkPath: oldPath)
        }
        return true
    }
}

/// 歌单封面写失败 —— 页面变成人话。
enum PlaylistCoverError: LocalizedError {
    case cannotEncode
    case cannotSave
    case playlistMissing

    var errorDescription: String? {
        switch self {
        case .cannotEncode: return "这张图没法当成封面用"
        case .cannotSave: return "封面没存上"
        case .playlistMissing: return "这个歌单已经不在了"
        }
    }
}

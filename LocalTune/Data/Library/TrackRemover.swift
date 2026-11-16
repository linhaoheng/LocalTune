import Foundation

/// 删歌 —— **删文件 + 删库行**这两步的编排。
///
/// 为什么单独一个类：这两步分属两个地方（文件归 `MusicFileStore` / `ArtworkStore`，
/// 库行归 `LibraryStore`），而「先删文件、再删库行」这个**顺序**、
/// 和「删文件失败也不中断」这条规矩，不该让每个调用方各记一遍。
///
/// ⚠️ 对外只收 **id**、不收整首 `Track`：调用方（页面）手里是排好版的展示数据，
/// 它不该为了删一首歌去库里把整首歌捞回来 —— 那是这一层的活。
///
/// ⚠️ 顺序是**先文件、后库行**：反过来的话，库行删掉了、文件删失败，
/// 就会留下一堆没人认领的音频和封面在沙盒里越堆越多。
/// 按现在这个顺序，最坏情况是"文件没了、库行还在" —— 那种行会被扫描认出来是坏的，
/// 用户重新导入一次就修好了。
final class TrackRemover {

    /// 曲库出口 —— 取歌和删库行都只经过它。
    private let library: LibraryStore

    init(library: LibraryStore) {
        self.library = library
    }

    /// 删掉这些歌。
    ///
    /// - Parameter deleteFiles: `true` 连磁盘上的音频和封面一起删（"彻底不要了"）；
    ///   `false` 只从曲库去掉、文件留在原地 —— 那是**故意**的：
    ///   "删除"的语义就是从曲库去掉，而"扫描"的语义是把磁盘上的都收进来，
    ///   所以下次扫描它回来是对的，不是漏了。
    func remove(trackIDs: [Track.ID], deleteFiles: Bool) throws {
        if deleteFiles {
            // ⚠️ 两个返回值都不看：删文件失败**不该**让这次删除中断 ——
            // 文件可能已经被用户在"文件"App 里删掉了，那这一首歌该照删不误。
            // 漏下的孤儿文件没有危害：它就在 `music/` 里，**下次扫描会照常把它收进库**
            // （扫描按**路径**收，磁盘上有几首就收几首 —— 早先那句"按内容指纹判重复用"已经作废）。
            for track in try tracks(withIDs: trackIDs) {
                MusicFileStore.delete(relativePath: track.path)
                ArtworkStore.delete(artworkPath: track.artworkPath)
            }
        }
        try library.delete(trackIDs: trackIDs)
    }

    // MARK: - 私有

    /// 按 id 取回这几首歌 —— 只为拿它们的文件路径。
    ///
    /// 查不到的直接跳过：库里已经没有它了，那就没什么可删的。
    private func tracks(withIDs trackIDs: [Track.ID]) throws -> [Track] {
        try trackIDs.compactMap { try library.track(id: $0) }
    }
}

import UIKit

/// 曲库页**用户动作协作者** —— 行尾「更多」菜单 / 编辑 / 播放 / 删除 / 分享。
///
/// 页面私有协作者：这里只**转发** —— 确认弹窗经由页面这个出口；怎么改、怎么播都交给 VM
/// 或全局服务，协作者不认识 `LibraryStore`。
@MainActor
final class SongsActionsController: NSObject {

    // MARK: - 依赖

    private let viewModel: SongsViewModel

    /// 跳转 —— 编辑歌曲信息、加入播放列表都只从这里出去。
    private let router: AppRouter

    /// 弹确认弹窗、分享面板的出口。
    private weak var page: UIViewController?

    init(
        viewModel: SongsViewModel,
        router: AppRouter,
        page: UIViewController
    ) {
        self.viewModel = viewModel
        self.router = router
        self.page = page
    }

    // MARK: - 行尾「更多」菜单里的动作

    /// 行尾「更多」菜单。
    ///
    /// ⚠️ 这里只**转发**：确认弹窗是页面出口的事；怎么改、怎么播都交给 VM 或全局服务。
    func makeRowActions(for row: SongRow) -> SongRowActions {
        SongRowActions(
            onEdit: { [weak self] in
                self?.presentEditor(for: row)
            },
            onPlayNext: { [weak self] in
                self?.playNext(row)
            },
            onAddToPlaylist: { [weak self] in
                self?.addToPlaylist(row)
            },
            favorite: (
                isFavorite: row.isFavorite,
                toggle: { [weak self] in self?.toggleFavorite(row) }
            ),
            onShare: { [weak self] source in
                self?.share(row, from: source)
            },
            mainAction: SongRowAction(
                title: "删除",
                systemImage: "trash",
                isDestructive: true
            ) { [weak self] in
                self?.confirmDelete(row)
            }
        )
    }

    // MARK: - 具体动作

    /// 编辑歌曲信息。
    private func presentEditor(for row: SongRow) {
        router.presentTrackEditor(trackID: row.id)
    }

    /// 下一首播放。
    private func playNext(_ row: SongRow) {
        viewModel.playNext(id: row.id)
        HUD.showMessage("已加入下一首播放")
    }

    /// 添加到播放列表。
    private func addToPlaylist(_ row: SongRow) {
        router.presentAddTracksToPlaylists(trackIDs: [row.id])
    }

    /// 喜爱 / 取消喜爱。
    private func toggleFavorite(_ row: SongRow) {
        viewModel.toggleFavorite(id: row.id, isFavorite: row.isFavorite)
        // ⚠️ 不弹提示，行尾那个心形图标变了就是回执。
    }

    /// 共享。
    private func share(_ row: SongRow, from sourceView: UIView) {
        guard let page, let url = viewModel.fileURL(for: row.id) else { return }
        // 锚点就用触发它的那个按钮 —— `sourceRect` 活在锚点自己的坐标系里，不用转换。
        page.presentShareSheet([url], anchoredTo: sourceView)
    }

    // MARK: - 删除

    /// 删除确认 —— 两个选项：「删除」只从曲库去掉，「同时删除文件」连磁盘上的文件一起删。
    ///
    /// 这是系统弹窗，不是页面之间的跳转，所以不走 `AppRouter`。
    func confirmDelete(_ row: SongRow) {
        guard let page else { return }
        let alert = LibraryTrackDeleteConfirmation.makeAlert(
            songTitle: row.title,
            onDeleteLibraryOnly: { [weak self] in
                self?.delete([row.id], deleteFiles: false, message: "已删除")
            },
            onDeleteWithFiles: { [weak self] in
                self?.delete([row.id], deleteFiles: true, message: "已删除")
            }
        )
        page.present(alert, animated: true)
    }

    /// 用户确认之后才真删 —— 这里只转发动作，删法由 VM 定。
    ///
    /// - Parameter message: 删完那句提示。**单首和多选说的不是一句话**（规格里就是这样），
    ///   所以由调用方给，不在这儿猜。
    ///
    /// - Returns: 删成功了没有 —— 调用方拿它决定要不要跟着做后续（比如退出选择模式）。
    @discardableResult
    func delete(_ trackIDs: [Track.ID], deleteFiles: Bool, message: String) -> Bool {
        do {
            try viewModel.delete(trackIDs: trackIDs, deleteFiles: deleteFiles)
            HUD.showMessage(message, style: .success)
            return true
        } catch {
            // 删库行失败是数据库层面的事（删文件那步失败不算失败，见 `TrackRemover`）。
            HUD.showMessage("删除失败", detail: error.localizedDescription, style: .error)
            return false
        }
    }

    // MARK: - 移除找不到的歌

    /// 顶上那条横幅「移除这 N 首」的确认 —— 把库里**所有**「文件不在本机」的行去掉。
    ///
    /// 🔴 **`deleteFiles` 永远是 `false`**：文件本来就不在，去删它是空动作；
    /// 而且万一判断错了（比如外置盘刚好没插上），`true` 会**真的把文件删掉**。
    /// 这条路**永远**只是"去掉库里的行"。
    ///
    /// ⚠️ 要移除的 id **只取一次**，弹窗里那个条数也从这一份数出来 —— 跟多选删除同一条规矩：
    /// 弹窗时数一遍、点确认时再取一遍，就留下了"弹窗说 3 首、真删 2 首"的余地。
    ///
    /// ⚠️ 一首都没读到（或读库失败）就**不弹窗** —— 不拿一个空弹窗去问用户。
    func confirmRemoveMissing() {
        guard let page else { return }
        let ids: [Track.ID]
        do {
            ids = try viewModel.missingTrackIDs()
        } catch {
            HUD.showMessage("读取失败", detail: error.localizedDescription, style: .error)
            return
        }
        guard !ids.isEmpty else { return }

        AppAlert.present(
            from: page,
            title: "你确定移除这 \(ids.count) 首找不到的歌曲吗？",
            message: "只会去掉曲库里的记录，不会动磁盘上的文件。",
            actions: [
                AppAlert.Action("移除", style: .destructive) { [weak self] in
                    self?.delete(ids, deleteFiles: false, message: "已移除 \(ids.count) 首歌曲")
                },
            ]
        )
    }
}

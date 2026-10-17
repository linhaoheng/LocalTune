import UIKit

/// 歌单页**添加模式协作者** —— 歌曲页多选进入的「添加到播放列表」这一趟。
///
/// 页面私有协作者：歌单页仍复用同一个 `PlaylistsViewController`；这里只负责这一趟添加的
/// 行状态、点击歌单和关闭，不把这些动作塞回歌单页通用动作（`PlaylistsActionsController`）。
/// 这一趟的输入和已处理歌单在 `PlaylistAddingTracksState`（页面持有、注入进来）。
@MainActor
final class PlaylistsAddingTracksController: NSObject {

    // MARK: - 依赖

    private let viewModel: PlaylistsViewModel

    private unowned let tableView: UITableView

    /// 关掉这一趟（左上「取消」）的出口。
    private weak var page: UIViewController?

    /// 这一趟添加的输入歌曲和已处理歌单。
    private let addingTracks: PlaylistAddingTracksState

    init(
        viewModel: PlaylistsViewModel,
        tableView: UITableView,
        page: UIViewController,
        addingTracks: PlaylistAddingTracksState
    ) {
        self.viewModel = viewModel
        self.tableView = tableView
        self.page = page
        self.addingTracks = addingTracks
    }

    // MARK: - 这一趟的活

    /// 打开添加模式时先查出已经完整包含这批歌的歌单，行尾直接显示勾。
    func loadAddingMemberships() {
        do {
            addingTracks.addedPlaylistIDs = try viewModel.playlistsContainingAll(addingTracks.trackIDs)
        } catch {
            HUD.showMessage("歌单读取失败", detail: error.localizedDescription, style: .error)
        }
    }

    /// 添加模式复用歌单行，只把行尾「更多」换成不可点击的加号 / 勾。
    func showAddingCell(_ cell: PlaylistTableCell, row: PlaylistRow) {
        cell.show(row, addingTracks: addingTracks.addedPlaylistIDs.contains(row.id))
    }

    /// 点一个歌单就加入整批歌曲；页面不关闭，允许连续添加多个歌单。
    func addSelectedTracks(to row: PlaylistRow) {
        guard !addingTracks.addedPlaylistIDs.contains(row.id) else { return }
        do {
            try viewModel.addTracks(addingTracks.trackIDs, to: row.id)
            addingTracks.addedPlaylistIDs.insert(row.id)
            tableView.reloadData()
        } catch {
            HUD.showMessage("添加失败", detail: error.localizedDescription, style: .error)
        }
    }

    /// 添加模式的左上取消。
    @objc func closeAddingTracks() {
        page?.dismiss(animated: true)
    }
}

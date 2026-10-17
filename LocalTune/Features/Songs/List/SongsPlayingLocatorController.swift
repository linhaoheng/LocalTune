import UIKit

/// 曲库页「定位当前曲」悬浮钮**协作者** —— 装上、跟着播放 / 多选显隐、点一下滚过去。
///
/// 钮本身和显隐规则在 `Components/SongList/PlayingSongLocator`；这里只接线。
@MainActor
final class SongsPlayingLocatorController {

    // MARK: - 依赖

    private let viewModel: SongsViewModel

    /// 钮盖在页面视图上 —— 出口是页面。
    private unowned let page: UIViewController

    private unowned let tableView: UITableView

    /// 点钮滚到正在播那一首要问表格的数据源 —— 列表协作者持有它，页面装配时接上。
    private weak var listController: SongsListController?

    /// 「定位当前曲」悬浮钮宿主。
    private let playingLocator = PlayingSongLocator()

    init(viewModel: SongsViewModel, page: UIViewController, tableView: UITableView) {
        self.viewModel = viewModel
        self.page = page
        self.tableView = tableView
    }

    // MARK: - 装配期接线

    /// 页面把列表协作者的引用接上（见 `SongsViewController`）。
    func wire(listController: SongsListController) {
        self.listController = listController
    }

    // MARK: - 装 / 显隐 / 滚动

    /// 装到页面上 —— 默认藏着，等用户滚列表才露（见 `PlayingSongLocator`）。
    ///
    /// ⚠️ **只有正在播时才会露**：没点过歌 → 滑了也不出。这是产品规则，不是漏接。
    func install() {
        playingLocator.install(on: page.view, tableView: tableView) { [weak self] in
            self?.scrollToPlayingSong()
        }
        syncPlayingLocatorAvailability()
    }

    /// 有没有当前曲、是不是多选 —— 合成「能不能露」。
    func syncPlayingLocatorAvailability() {
        let hasTrack = viewModel.playbackChromeNow.currentTrackID != nil
        playingLocator.setAvailable(hasTrack && !viewModel.isSelectingNow)
    }

    /// 点钮：滚到正在播那一首（这首不在当前列表里就什么都不做）。
    func scrollToPlayingSong() {
        guard let id = viewModel.playbackChromeNow.currentTrackID,
              let path = listController?.indexPath(for: id)
        else { return }
        tableView.scrollToRow(at: path, at: .middle, animated: true)
    }

    // MARK: - 滚动回调（列表协作者转过来）

    func userBeganScrolling() {
        playingLocator.userBeganScrolling()
    }

    func scrollDidSettle() {
        playingLocator.scrollDidSettle()
    }
}

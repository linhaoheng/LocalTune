import UIKit

/// 歌单详情「定位当前曲」悬浮钮**协作者** —— 跟曲库页同一套零件，这里只接线。
@MainActor
final class PlaylistDetailPlayingLocatorController {

    // MARK: - 依赖

    private let viewModel: PlaylistDetailViewModel

    private unowned let page: UIViewController

    private unowned let tableView: UITableView

    /// 点钮滚到正在播那一首要问行位置 —— 列表协作者持有它，页面装配时接上。
    private weak var listController: PlaylistDetailListController?

    /// 「定位当前曲」悬浮钮宿主。
    private let playingLocator = PlayingSongLocator()

    init(viewModel: PlaylistDetailViewModel, page: UIViewController, tableView: UITableView) {
        self.viewModel = viewModel
        self.page = page
        self.tableView = tableView
    }

    // MARK: - 装配期接线

    /// 页面把列表协作者的引用接上（见 `PlaylistDetailViewController`）。
    func wire(listController: PlaylistDetailListController) {
        self.listController = listController
    }

    // MARK: - 装 / 显隐 / 滚动

    /// 装到页面上 —— 默认藏着，等用户滚列表才露。
    ///
    /// ⚠️ **只有正在播时才会露**：没点过歌 → 滑了也不出。这是产品规则，不是漏接。
    func install() {
        playingLocator.install(on: page.view, tableView: tableView) { [weak self] in
            self?.scrollToPlayingSong()
        }
        syncPlayingLocatorAvailability()
    }

    /// 有没有当前曲 —— 多选 / 手动排序时藏起来（跟曲库页同一条）。
    func syncPlayingLocatorAvailability() {
        let hasTrack = viewModel.playbackChromeNow.currentTrackID != nil
        playingLocator.setAvailable(
            hasTrack && !viewModel.isSelectingNow && !viewModel.isReorderingNow
        )
    }

    /// 强制藏起来（封面流盖着的时候）—— 撤掉盖层后由 `syncPlayingLocatorAvailability` 收回来。
    func forceHide() {
        playingLocator.setAvailable(false)
    }

    /// 点钮：滚到正在播那一首（不在这个歌单里就什么都不做）。
    func scrollToPlayingSong() {
        guard let id = viewModel.playbackChromeNow.currentTrackID,
              let path = listController?.indexPath(forTrackID: id)
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

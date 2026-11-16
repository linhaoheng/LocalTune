import UIKit

/// 歌单详情页的**表头协作者** —— 表头怎么挂上去、多高、封面怎么换。
///
/// 页面私有协作者：表头（封面 ＋ 两个键）归这里建、归这里挂。
///
/// ⚠️ 两个键的动作在**建它的时候**就接给了动作协作者：
/// 事后接的可选回调，漏了编译不吭声。
@MainActor
final class PlaylistDetailHeaderController {

    // MARK: - 依赖

    private unowned let tableView: UITableView

    private unowned let actionsController: PlaylistDetailActionsController

    /// 表头（封面 ＋ 两个键）。
    private let headerView: PlaylistDetailHeaderView

    init(
        tableView: UITableView,
        artworkProvider: @escaping ArtworkProvider,
        actionsController: PlaylistDetailActionsController
    ) {
        self.tableView = tableView
        self.actionsController = actionsController
        headerView = PlaylistDetailHeaderView(
            artworkProvider: artworkProvider,
            onPlayAll: { [weak actionsController] in actionsController?.playAll() },
            onShuffle: { [weak actionsController] in actionsController?.shuffleAll() }
        )
    }

    // MARK: - 挂 / 量 / 显示

    /// 封面换了。
    func show(cover: PlaylistCover) {
        headerView.show(cover: cover)
    }

    /// 把表头挂上表格。
    ///
    /// ⚠️ 这一刻表格可能还没有宽度（`viewDidLoad` 里刚建出来）—— 量高那一步会量不出来，
    /// 表头先以零高挂着，`viewDidLayoutSubviews` 再把它量正。所以**顺序不能反**：
    /// 先挂上、再量。
    func installHeader() {
        tableView.tableHeaderView = headerView
        sizeHeaderToFit()
    }

    /// 量一次表头的高度、写回它的 frame。
    ///
    /// 🔴 `tableHeaderView` 的高度**表格不会自己算** —— 它只读"挂上去那一刻"的 frame。
    /// 所以得自己量：给一个宽度（表格的宽度）、让系统按内容算高度。
    ///
    /// ⚠️ 高度和宽度都没变就**什么都不做**：`viewDidLayoutSubviews` 会被叫很多次，
    /// 每次重新挂一遍表头等于每帧都重建一次视图层级。
    ///
    /// ⚠️ 改完 frame 必须**再挂一次** —— 表格只在"挂"的那一刻读它的高度。
    func sizeHeaderToFit() {
        let width = tableView.bounds.width
        guard width > 0 else { return }

        let height = headerView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard headerView.frame.width != width || headerView.frame.height != height else { return }

        headerView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableHeaderView = headerView
    }
}

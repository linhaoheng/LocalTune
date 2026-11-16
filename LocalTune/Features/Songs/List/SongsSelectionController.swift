import UIKit

/// 曲库页**选择模式协作者** —— 进 / 出、底部工具条、多选删除、添加到播放列表。
///
/// 页面私有协作者：机制是**系统自带的编辑模式多选**（`setEditing` +
/// `allowsMultipleSelectionDuringEditing`）—— 行首那个勾由系统画，不用自己画一个。
/// ⚠️ 那两个开关在页面 `layoutTableView()` 里**一次设好**，这里只管「进 / 出」。
@MainActor
final class SongsSelectionController: NSObject {

    // MARK: - 依赖

    private let viewModel: SongsViewModel

    /// 多选后「添加到播放列表」的跳转出口。
    private let router: AppRouter

    /// 进出选择模式要动导航栏、工具条、底部让位这三样 —— 都长在页面上。
    private weak var page: SongsViewController?

    /// 编辑模式的开关、勾的同步都落在表格上。
    private unowned let tableView: UITableView

    /// 表格的勾 / 滚动定位都经同页协作者出去（页面装配时接上，见 `SongsViewController`）。
    private weak var listController: SongsListController?
    private weak var locatorController: SongsPlayingLocatorController?
    private weak var actionsController: SongsActionsController?

    init(
        viewModel: SongsViewModel,
        router: AppRouter,
        page: SongsViewController,
        tableView: UITableView
    ) {
        self.viewModel = viewModel
        self.router = router
        self.page = page
        self.tableView = tableView
    }

    // MARK: - 装配期接线

    /// 页面把同页协作者的引用接上（见 `SongsViewController`）。
    func wire(
        listController: SongsListController,
        locatorController: SongsPlayingLocatorController,
        actionsController: SongsActionsController
    ) {
        self.listController = listController
        self.locatorController = locatorController
        self.actionsController = actionsController
    }

    // MARK: - 状态

    /// 表格勾 ↔ 选中集合的对齐 —— 机制全工程一份（`TableSelectionSync`）。
    /// 「哪一行是哪首」由同页的 listController 回答；机制不认识任何业务 ——
    /// **编号类型由这一行填**（机制那边是泛型 `ID`，`Core/` 不认识 `Track`）。
    private lazy var selectionSync = TableSelectionSync<Track.ID>(
        tableView: tableView,
        directory: TableSelectionDirectory(
            idAt: { [weak self] indexPath in
                self?.listController?.itemIdentifier(at: indexPath)
            },
            indexPathFor: { [weak self] id in
                self?.listController?.indexPath(for: id)
            }
        )
    )

    /// 底部工具条上那两个**跟着选中数走**的键 —— 一首都没选时都要置灰。
    private var toolbarDeleteItem: UIBarButtonItem?
    private var toolbarAddItem: UIBarButtonItem?

    /// 选择模式里顶掉右侧那三个按钮的「取消」。
    ///
    /// ⚠️ 用系统的 `.cancel` 档 —— 标题由系统按语言给，不用自己写一个字符串。
    private lazy var cancelItem = UIBarButtonItem(
        barButtonSystemItem: .cancel,
        target: self,
        action: #selector(endSelect)
    )

    // MARK: - 选中集合变了

    /// 两个键同一条命：一首都没选就都点不动。分开写两条订阅迟早出现"一个亮一个灰"。
    func updateToolbarAvailability(_ ids: Set<Track.ID>) {
        let hasSelection = !ids.isEmpty
        toolbarDeleteItem?.isEnabled = hasSelection
        toolbarAddItem?.isEnabled = hasSelection
    }

    // MARK: - 进 / 出选择模式

    /// 进出选择模式时界面要跟着换的那一套。
    ///
    /// ⚠️ 工具条那几项**退出时不清** —— 条收上去之后就看不见了，而下次进来
    /// `installToolbarItems()` 会整个重设一遍。所以「清」这个动作本来就没有
    /// 要解决的问题；清了反倒得**等一个延迟**再动手（否则会先看到内容没了、条才收上去），
    /// 那个延迟里还得再判断一次「用户是不是又进来了」—— 一串本来不存在的麻烦。
    func applySelectingChrome(_ selecting: Bool) {
        guard let page else { return }
        tableView.setEditing(selecting, animated: true)
        // 底部那一整块让给系统工具条 —— 条子**和它底下那层材质一起**收
        //（只收条子的话，材质层还压在工具条上面，看着就是"进了多选没有工具条"）。
        page.bottomBlockHost?.setBottomBlockHidden(selecting)

        if selecting {
            // 先把项装好、再让条滑上来 —— 滑的过程中显示的就是最终那一批，不会先闪一下旧的。
            installToolbarItems(page: page)
            page.navigationController?.setToolbarHidden(false, animated: true)
            page.navigationItem.rightBarButtonItems = [cancelItem]
            page.navigationItem.leftBarButtonItem = nil
        } else {
            selectionSync.deselectAll()
            page.navigationController?.setToolbarHidden(true, animated: true)
            page.restoreDefaultRightBarItems()
        }
        // 多选一进一出，「正在播」高亮要跟着藏 / 露（行自己不认选择模式）；
        // 定位钮也不能在多选时露出来。
        listController?.refreshVisiblePlaybackState()
        locatorController?.syncPlayingLocatorAvailability()
    }

    // MARK: - 列表换了之后

    /// 列表内容换了之后收拾一遍选中集合 —— 编排在 `TableSelectionSync.prune`（先落状态、再对勾）。
    func pruneSelection(to availableIDs: [Track.ID]) {
        selectionSync.prune(to: availableIDs, state: viewModel)
    }

    // MARK: - 私有

    /// 装上底部工具条那几项 —— **四项，这个顺序**：
    /// 全选 / 取消全选 / **添加到播放列表** / 删除。
    ///
    /// ⚠️ 顺序有讲究：两个键并排那样「功能相近的挨着」不适用 ——
    /// **破坏性的留在最右**（「删除」），跟它前面那三项之间隔开一档。
    private func installToolbarItems(page: SongsViewController) {
        // 头两项（全选 / 取消全选）两页同款 —— 工厂一处出；后面的动作键各页自己的。
        let (selectAll, deselectAll) = SelectionToolbar.makeSelectAllItems(
            target: self,
            selectAll: #selector(toolbarSelectAll),
            deselectAll: #selector(toolbarDeselectAll)
        )
        let add = UIBarButtonItem(
            title: "添加到播放列表",
            style: .plain,
            target: self,
            action: #selector(toolbarAddToPlaylist)
        )
        let delete = UIBarButtonItem(
            title: "删除",
            style: .plain,
            target: self,
            action: #selector(toolbarDelete)
        )
        delete.tintColor = AppColor.destructive
        // 两个动作键都先置灰 —— 一首都没选时它们没有意义（选中一变由页面订阅点亮）。
        delete.isEnabled = false
        add.isEnabled = false
        toolbarDeleteItem = delete
        toolbarAddItem = add

        page.setToolbarItems([selectAll, deselectAll, add, delete], animated: false)
    }

    // MARK: - 工具条上那三个动作

    @objc private func toolbarSelectAll() {
        guard let listController else { return }
        let ids = listController.allRowIDs()
        viewModel.selectAll(ids)
        selectionSync.sync(to: Set(ids))
    }

    @objc private func toolbarDeselectAll() {
        viewModel.deselectAll()
        selectionSync.deselectAll()
    }

    @objc private func toolbarDelete() {
        confirmDeleteSelected()
    }

    /// 「添加到播放列表」—— 复用歌单页的列表和行，只切换到「选择歌单」模式。
    ///
    /// 入口是：把选中的歌曲传给歌单列表页的添加模式（`PlaylistAddingTracksState`），
    /// 再用导航控制器模态弹出；点一个歌单就把这批歌加入进去，页面不关，允许连续添加。
    ///
    /// 🔴 **点这个键就算这一趟完了 —— 弹模态之前先退出选择模式**（跟「删除」同构：
    /// "我点了这个动作"即任务完成，不必等模态关上）。
    @objc private func toolbarAddToPlaylist() {
        guard let listController else { return }
        let selectedIDs = viewModel.selectedIDsNow
        let trackIDs = listController.allRowIDs().filter { selectedIDs.contains($0) }
        guard !trackIDs.isEmpty else { return }
        viewModel.endSelect()
        router.presentAddTracksToPlaylists(trackIDs: trackIDs)
    }

    /// 导航栏那个「取消」。
    @objc func endSelect() {
        viewModel.endSelect()
    }

    // MARK: - 多选删除

    /// 多选删除的确认 —— **只有「删除」和「取消」两个选项**，不像单首那样再问一次
    /// 「要不要连文件一起删」：多选这一路**就是**"彻底不要了"，一次问清。
    ///
    /// 🔴 **文案是定死的**：「你确定删除这 N 首歌吗？」——
    /// 只有标题、**没有 message**。
    ///
    /// ⚠️ 这一句是**刻意不照常见做法**——常见做法写的是
    /// 「你确定要从**音乐库中**删除这 N 首歌吗？」，可它这一路**也是连文件一起删的**——
    /// 标题里那句「从音乐库中删除」读起来像是文件还留着，跟它实际干的事对不上。
    /// 我们这一句只说「删除」，不含糊。
    ///
    /// ⚠️ 哪天要在弹窗里补一句"文件也没了"，就给下面加回一个 `message:`，别处不用动。
    ///
    /// ⚠️ 要删的 id **只取一次**，提示语里那个条数也**从这一份数出来**。
    /// 分两处取（弹窗时数一遍、点确认时再取一遍）就留下了分叉的余地 ——
    /// 弹窗上说「这 3 首」、真删下去 2 首，而且没有任何地方会发现。
    private func confirmDeleteSelected() {
        guard let actionsController, let page else { return }
        let ids = Array(viewModel.selectedIDsNow)
        guard !ids.isEmpty else { return }

        AppAlert.present(
            from: page,
            title: "你确定删除这 \(ids.count) 首歌吗？",
            actions: [
                AppAlert.Action("删除", style: .destructive) { [weak actionsController, weak self] in
                    guard let actionsController else { return }
                    let deleted = actionsController.delete(ids, deleteFiles: true, message: "已删除 \(ids.count) 首歌曲")
                    // 删成功了才退出选择模式（失败就留在原地，用户还能重来）。
                    if deleted { self?.viewModel.endSelect() }
                },
            ]
        )
    }
}

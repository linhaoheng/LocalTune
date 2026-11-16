import UIKit

/// 歌单详情页**选择模式协作者** —— 工具条四项 + 勾选同步。
///
/// ## 工具条四项
///
/// 全选 / 取消全选 / **从播放列表中删除** / **删除**。
///
/// - 「从播放列表中删除」＝ 只移出这个歌单（最爱 = 取消喜爱），歌还在曲库；
/// - 「删除」＝ 从曲库删，弹窗再问要不要连文件（跟详情页同口径）。
///
/// ⚠️ 两项都是破坏性红。靠**文案**区分语义，不靠颜色；
/// 点「删除」还会再问一次「只删库 / 连文件」，踩错成本在第二层拦住。
///
/// 机制跟曲库页同一套：`setEditing` + `allowsMultipleSelectionDuringEditing`，
/// 行首那个勾由系统画；底部用导航控制器工具条。
@MainActor
final class PlaylistDetailSelectionController: NSObject {

    // MARK: - 依赖

    private let viewModel: PlaylistDetailViewModel

    /// 进出选择模式要动导航栏、工具条、底部让位 —— 都长在页面上。
    private weak var page: PlaylistDetailViewController?

    private unowned let tableView: UITableView

    /// 勾的同步、全选的行都问列表协作者；进出选择模式还要它刷可见行。
    private weak var listController: PlaylistDetailListController?

    /// 多选时定位钮要藏。
    private weak var locatorController: PlaylistDetailPlayingLocatorController?

    // MARK: - 状态

    /// 表格勾 ↔ 选中集合的对齐 —— 机制全工程一份（`TableSelectionSync`）。
    /// 「哪一行是哪首」由同页的 listController 回答；机制不认识任何业务 ——
    /// **编号类型由这一行填**（机制那边是泛型 `ID`，`Core/` 不认识 `Track`）。
    private lazy var selectionSync = TableSelectionSync<Track.ID>(
        tableView: tableView,
        directory: TableSelectionDirectory(
            idAt: { [weak self] indexPath in
                self?.listController?.song(at: indexPath)?.id
            },
            indexPathFor: { [weak self] id in
                self?.listController?.indexPath(forTrackID: id)
            }
        )
    )

    /// 选择模式工具条「从播放列表中删除」/「删除」—— 选中变了时一起点亮 / 置灰。
    private var toolbarRemoveItem: UIBarButtonItem?
    private var toolbarDeleteItem: UIBarButtonItem?

    /// 选择模式里顶掉右侧按钮的「取消」。
    private lazy var cancelSelectItem = UIBarButtonItem(
        barButtonSystemItem: .cancel,
        target: self,
        action: #selector(endSelect)
    )

    init(
        viewModel: PlaylistDetailViewModel,
        page: PlaylistDetailViewController,
        tableView: UITableView
    ) {
        self.viewModel = viewModel
        self.page = page
        self.tableView = tableView
    }

    // MARK: - 装配期接线

    /// 页面把同页协作者的引用接上（见 `PlaylistDetailViewController`）。
    func wire(
        listController: PlaylistDetailListController,
        locatorController: PlaylistDetailPlayingLocatorController
    ) {
        self.listController = listController
        self.locatorController = locatorController
    }

    // MARK: - 选中集合变了

    /// 两个破坏键同一条命：一首都没选就都点不动。
    func updateToolbarAvailability(_ ids: Set<Track.ID>) {
        let hasSelection = !ids.isEmpty
        toolbarRemoveItem?.isEnabled = hasSelection
        toolbarDeleteItem?.isEnabled = hasSelection
    }

    // MARK: - 进 / 出选择模式

    /// 进出选择模式时界面要跟着换的那一套。
    func applySelectingChrome(_ selecting: Bool) {
        guard let page else { return }
        tableView.setEditing(selecting, animated: true)
        page.bottomBlockHost?.setBottomBlockHidden(selecting)

        if selecting {
            installToolbarItems(page: page)
            page.navigationController?.setToolbarHidden(false, animated: true)
            page.navigationItem.rightBarButtonItems = [cancelSelectItem]
        } else {
            selectionSync.deselectAll()
            page.navigationController?.setToolbarHidden(true, animated: true)
            page.restoreDefaultRightBarItems()
        }
        listController?.refreshVisiblePlaybackState()
        locatorController?.syncPlayingLocatorAvailability()
    }

    // MARK: - 列表换了之后

    /// 列表内容换了之后收拾一遍选中集合 —— 编排在 `TableSelectionSync.prune`（先落状态、再对勾）。
    func pruneSelection(to availableIDs: [Track.ID]) {
        selectionSync.prune(to: availableIDs, state: viewModel)
    }

    // MARK: - 私有

    /// 装上底部工具条 —— 顺序：全选 / 取消全选 / 从播放列表中删除 / 删除。
    private func installToolbarItems(page: PlaylistDetailViewController) {
        // 头两项（全选 / 取消全选）两页同款 —— 工厂一处出；后面的动作键各页自己的。
        let (selectAll, deselectAll) = SelectionToolbar.makeSelectAllItems(
            target: self,
            selectAll: #selector(toolbarSelectAll),
            deselectAll: #selector(toolbarDeselectAll)
        )
        let remove = UIBarButtonItem(
            title: "从播放列表中删除",
            style: .plain,
            target: self,
            action: #selector(toolbarRemoveSelected)
        )
        remove.tintColor = AppColor.destructive
        remove.isEnabled = false
        toolbarRemoveItem = remove

        let delete = UIBarButtonItem(
            title: "删除",
            style: .plain,
            target: self,
            action: #selector(toolbarDeleteSelected)
        )
        delete.tintColor = AppColor.destructive
        delete.isEnabled = false
        toolbarDeleteItem = delete

        page.setToolbarItems([selectAll, deselectAll, remove, delete], animated: false)
    }

    // MARK: - 工具条动作

    @objc private func toolbarSelectAll() {
        guard let listController else { return }
        let ids = listController.songs.map(\.id)
        viewModel.selectAll(ids)
        selectionSync.sync(to: Set(ids))
    }

    @objc private func toolbarDeselectAll() {
        viewModel.deselectAll()
        selectionSync.deselectAll()
    }

    @objc private func toolbarRemoveSelected() {
        confirmRemoveSelected()
    }

    @objc private func toolbarDeleteSelected() {
        confirmDeleteSelectedFromLibrary()
    }

    /// 导航栏那个「取消」。
    @objc func endSelect() {
        viewModel.endSelect()
    }

    /// 「从播放列表中删除」确认 —— 文案分单 / 复数两句。
    ///
    /// ⚠️ 要移的 id **只取一次**，提示条数也从这一份数出来。
    private func confirmRemoveSelected() {
        guard let page else { return }
        let ids = Array(viewModel.selectedIDsNow)
        guard !ids.isEmpty else { return }

        let title = ids.count == 1
            ? "你确定要从播放列表中删除这首歌曲吗？"
            : "确定要从播放列表中删除这些歌曲吗？"
        // ⚠️ 键序是产品决定：这一处「取消」摆在**前面**（照抄原状），不走 cancel 参数。
        AppAlert.present(
            from: page,
            title: title,
            actions: [
                AppAlert.Action.cancel(),
                AppAlert.Action("删除", style: .destructive) { [weak self] in
                    self?.removeSelected(ids)
                },
            ],
            cancel: nil
        )
    }

    /// 「删除」确认 —— 删除（只删库）/ 同时删除文件 / 取消。
    private func confirmDeleteSelectedFromLibrary() {
        guard let page else { return }
        let ids = Array(viewModel.selectedIDsNow)
        guard !ids.isEmpty else { return }

        let title = ids.count == 1
            ? "你确定要从你的音乐库中删除这首歌吗？"
            : "你确定要从你的音乐库中删除这 \(ids.count) 首歌吗？"
        AppAlert.present(
            from: page,
            title: title,
            actions: [
                AppAlert.Action("删除", style: .destructive) { [weak self] in
                    self?.deleteSelected(ids, deleteFiles: false)
                },
                AppAlert.Action("同时删除文件", style: .destructive) { [weak self] in
                    self?.deleteSelected(ids, deleteFiles: true)
                },
            ]
        )
    }

    private func removeSelected(_ ids: [Track.ID]) {
        do {
            try viewModel.remove(trackIDs: ids)
            // 任务做完就退出选择模式。
            viewModel.endSelect()
        } catch {
            HUD.showMessage("移除失败", detail: error.localizedDescription, style: .error)
        }
    }

    private func deleteSelected(_ ids: [Track.ID], deleteFiles: Bool) {
        do {
            try viewModel.deleteFromLibrary(trackIDs: ids, deleteFiles: deleteFiles)
            // 任务做完就退出选择模式。
            viewModel.endSelect()
            let msg = ids.count == 1 ? "已删除 1 首歌曲" : "已删除 \(ids.count) 首歌曲"
            HUD.showMessage(msg, style: .success)
        } catch {
            HUD.showMessage("删除失败", detail: error.localizedDescription, style: .error)
        }
    }
}

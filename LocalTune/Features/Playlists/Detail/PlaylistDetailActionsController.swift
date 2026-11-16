import UIKit

/// 歌单详情页**动作协作者** —— 加号 / 更多菜单 / 搜索入口 / 播放 / 移除 / 封面 / 改名 / 删除 / 排序 / 手动排序。
///
/// 页面私有协作者：这里只**转发** —— 确认弹窗经由页面这个出口；怎么改、怎么排都交给 VM；
/// 拖出来的顺序从列表协作者那份 `songs` 拿（拖动那一下已经改好了）。
@MainActor
final class PlaylistDetailActionsController: NSObject {

    // MARK: - 依赖

    private let viewModel: PlaylistDetailViewModel

    /// 跳转 —— 加号弹挑歌页、行尾编辑、加入歌单、播放页都只从这里出去。
    private let router: AppRouter

    /// 弹窗、搜索框亮出来 —— 出口和零件都长在页面上。
    private weak var page: PlaylistDetailViewController?

    /// 手动排序：进之前看 `songs` 空不空、「完成」写回的就是这份顺序。
    private weak var listController: PlaylistDetailListController?

    /// 「封面流」菜单项的归处（盖流 / 收流、iPad 开关都在那边）。
    private weak var coverFlowController: PlaylistDetailCoverFlowController?

    // MARK: - 状态

    /// 这个歌单是不是「最爱的歌曲」—— 删除那一项置灰由它定。
    ///
    /// ⚠️ 快照来了由页面喂进来（`updateFavorites`），变了就**重建「更多」菜单**
    /// （那一项的置灰是建菜单时定死的）。
    private(set) var isFavorites = false

    init(
        viewModel: PlaylistDetailViewModel,
        router: AppRouter,
        page: PlaylistDetailViewController
    ) {
        self.viewModel = viewModel
        self.router = router
        self.page = page
    }

    // MARK: - 装配期接线

    /// 页面把同页协作者的引用接上（见 `PlaylistDetailViewController`）。
    func wire(
        listController: PlaylistDetailListController,
        coverFlowController: PlaylistDetailCoverFlowController
    ) {
        self.listController = listController
        self.coverFlowController = coverFlowController
    }

    // MARK: - 快照喂进来的状态

    func updateFavorites(_ newValue: Bool) {
        guard isFavorites != newValue else { return }
        isFavorites = newValue
        page?.moreItem.menu = makeMoreMenu()
    }

    // MARK: - 导航栏

    /// 「加号」—— 往这个歌单里加歌：弹出挑歌页（`Features/Playlists/Add/`）。
    @objc func addSongsTapped() {
        router.presentAddSongs(to: viewModel.playlistID)
    }

    /// 「更多」—— **分组照那一套**，不抄那些坑（每歌单排序 key、双删除、只拧右横、全局会话）。
    ///
    /// ⚠️ 分组：第一组是"看这个列表"（选择 / 搜索 / 封面流），第二组是"管这个歌单"
    /// （手动排序 / 排序 / 换封面 / 改名 / 删除）。
    func makeMoreMenu() -> UIMenu {
        let select = UIAction(
            title: "选择",
            image: UIImage(systemName: "checkmark.circle")
        ) { [weak self] _ in
            self?.viewModel.toggleSelect()
        }
        let search = UIAction(
            title: "搜索",
            image: UIImage(systemName: "magnifyingglass")
        ) { [weak self] _ in
            self?.revealSearch()
        }
        let coverFlow = makeCoverFlowMenuAction()
        let manualSort = UIAction(
            title: "手动排序",
            image: UIImage(systemName: "hand.tap")
        ) { [weak self] _ in
            self?.beginManualSorting()
        }
        let rename = UIAction(
            title: "重命名列表",
            image: UIImage(systemName: "pencil")
        ) { [weak self] _ in
            self?.renamePlaylist()
        }
        let delete = UIAction(
            title: "删除播放列表",
            // **「最爱的歌曲」那一行置灰**（它不能删，数据层也挡着）。
            image: UIImage(systemName: "trash"),
            attributes: isFavorites ? [.destructive, .disabled] : [.destructive]
        ) { [weak self] _ in
            self?.confirmDeletePlaylist()
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: [select, search, coverFlow]),
            UIMenu(
                options: .displayInline,
                children: [
                    manualSort,
                    makeSortMenu(),
                    changeCoverAction(),
                    generateCoverAction(),
                    rename,
                    delete
                ]
            )
        ])
    }

    /// 手机：动作「封面流」。iPad：开关「自动显示封面流」。
    private func makeCoverFlowMenuAction() -> UIAction {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let on = viewModel.iPadAutoCoverFlow
            return UIAction(
                title: "自动显示封面流",
                image: UIImage(systemName: "rectangle.stack"),
                state: on ? .on : .off
            ) { [weak self] _ in
                self?.toggleIPadAutoCoverFlow()
            }
        }
        return UIAction(
            title: "封面流",
            image: UIImage(systemName: "rectangle.stack")
        ) { [weak self] _ in
            self?.presentCoverFlowFromMenu()
        }
    }

    /// 排序子菜单 —— **3 档**（默认 / 导入时间 / 歌曲标题）+ 升降序。
    ///
    /// ⚠️ 打勾是**建菜单那一刻**的状态 —— 排序一变由页面 `bindSortMenuRebuild` 重建。
    /// ⚠️ 「默认」仍可比升 / 降（整列颠倒），所以升降序**不置灰**（跟列表页「手动」那档不一样）。
    private func makeSortMenu() -> UIMenu {
        let modeGroup = UIMenu(
            options: .displayInline,
            children: PlaylistDetailSortMode.allCases.map { mode in
                UIAction(
                    title: mode.menuTitle,
                    state: viewModel.sortMode == mode ? .on : .off
                ) { [weak self] _ in
                    self?.viewModel.setSortMode(mode)
                }
            }
        )
        let directionGroup = UIMenu(
            options: .displayInline,
            children: SortDirection.allCases.map { direction in
                UIAction(
                    title: direction.menuTitle,
                    state: viewModel.sortDirection == direction ? .on : .off
                ) { [weak self] _ in
                    self?.viewModel.setSortDirection(direction)
                }
            }
        )
        return UIMenu(
            title: "排序",
            image: UIImage(systemName: "arrow.up.arrow.down"),
            children: [modeGroup, directionGroup]
        )
    }

    private func changeCoverAction() -> UIAction {
        UIAction(
            title: "修改封面图片",
            image: UIImage(systemName: "photo")
        ) { [weak self] _ in
            self?.changeCover()
        }
    }

    private func generateCoverAction() -> UIAction {
        UIAction(
            title: "生成封面",
            image: UIImage(systemName: "square.grid.2x2")
        ) { [weak self] _ in
            self?.generateCover()
        }
    }

    private func presentCoverFlowFromMenu() {
        coverFlowController?.presentCoverFlowFromMenu()
    }

    private func toggleIPadAutoCoverFlow() {
        coverFlowController?.toggleIPadAutoCoverFlow()
        // 开关的勾是建菜单那一刻定死的 —— 拧完重建（跟排序勾同一条命）。
        page?.moreItem.menu = makeMoreMenu()
    }

    /// 把搜索框亮出来、键盘顶上来 —— 「更多」菜单里那一项就调它。
    ///
    /// 三步，**一步都不能少**（跟曲库页那份是同一条规格）。
    private func revealSearch() {
        guard let page else { return }
        page.navigationItem.hidesSearchBarWhenScrolling = false
        page.searchController.isActive = true
        DispatchQueue.main.async { [weak page] in
            page?.searchController.searchBar.becomeFirstResponder()
            page?.navigationItem.hidesSearchBarWhenScrolling = true
        }
    }

    // MARK: - 表头两个键

    /// 「播放」—— 关洗牌、退掉单曲循环（若有），从这个歌单第一首开播。
    func playAll() {
        guard viewModel.playAll() else { return }
    }

    /// 「随机播放」—— 开洗牌、退掉单曲循环（若有），随机挑一首起播。
    func shuffleAll() {
        guard viewModel.shuffleAll() else { return }
    }

    // MARK: - 行尾「更多」

    /// 行菜单 —— **没有「喜爱 / 取消喜爱」**；底项文案叫「删除」，
    /// 点下去是**从歌单移除**（弹窗文案也照那一套）。
    func makeRowActions(_ row: SongRow) -> SongRowActions {
        SongRowActions(
            onEdit: { [weak self] in
                self?.router.presentTrackEditor(trackID: row.id)
            },
            onPlayNext: { [weak self] in
                self?.playNext(row)
            },
            onAddToPlaylist: { [weak self] in
                self?.router.presentAddTracksToPlaylists(trackIDs: [row.id])
            },
            favorite: nil,
            onShare: { [weak self] source in
                self?.share(row, from: source)
            },
            mainAction: SongRowAction(
                title: "删除",
                systemImage: "trash",
                isDestructive: true
            ) { [weak self] in
                self?.confirmRemove(row)
            }
        )
    }

    private func playNext(_ row: SongRow) {
        viewModel.playNext(id: row.id)
        HUD.showMessage("已加入下一首播放")
    }

    private func share(_ row: SongRow, from sourceView: UIView) {
        guard let page, let url = viewModel.fileURL(for: row.id) else { return }
        // 锚点就用触发它的那个按钮 —— `sourceRect` 活在锚点自己的坐标系里，不用转换。
        page.presentShareSheet([url], anchoredTo: sourceView)
    }

    /// 行尾「删除」—— 菜单叫删除，弹窗是「从歌单中移除」。
    ///
    /// ⚠️ 最爱那一行也弹（`confirmRemove` 不分最爱）—— 「喜爱直接切、不确认」
    /// 指的是菜单里那一项「取消喜爱」，这一页已经不摆那一项了。
    func confirmRemove(_ row: SongRow) {
        guard let page else { return }
        AppAlert.present(
            from: page,
            title: "从歌单中移除《\(row.title)》？",
            actions: [
                AppAlert.Action("移除", style: .destructive) { [weak self] in
                    self?.remove([row.id])
                },
            ]
        )
    }

    /// 用户确认之后才真移 —— 这里只转发动作，怎么移由 VM 定。
    private func remove(_ trackIDs: [Track.ID]) {
        do {
            try viewModel.remove(trackIDs: trackIDs)
        } catch {
            HUD.showMessage("移除失败", detail: error.localizedDescription, style: .error)
        }
    }

    // MARK: - 封面

    private func changeCover() {
        guard let page else { return }
        PlaylistCoverPickerSession.present(
            from: page,
            playlistID: viewModel.playlistID,
            onPicked: { [weak self] _, image in
                guard let self else { return }
                do {
                    try self.viewModel.setPlaylistCover(image)
                } catch {
                    HUD.showMessage("换封面失败", detail: error.localizedDescription, style: .error)
                }
            },
            onFailed: { PlaylistCoverMessaging.showPickFailure($0) }
        )
    }

    private func generateCover() {
        guard let page else { return }
        viewModel.generatePlaylistCover { result in
            switch result {
            case .success(false):
                PlaylistCoverMessaging.presentNoSourceArtwork(from: page)
            case .success(true):
                break
            case .failure(let error):
                HUD.showMessage("生成封面失败", detail: error.localizedDescription, style: .error)
            }
        }
    }

    // MARK: - 改名 / 删除

    /// 「重命名列表」—— 判据只走 `viewModel.canRename`（`PlaylistNaming` 一处）。
    ///
    /// 🔴 **名字清空时「保存」是灰的**（比「空名字照写进库」好）—— 判据交给 `AppAlert` 接线。
    func renamePlaylist() {
        guard let page else { return }
        let currentName = page.title ?? ""
        AppAlert.prompt(
            from: page,
            title: "重新命名",
            initialText: currentName,
            confirmTitle: "保存",
            isValid: { [weak self] text in
                self?.viewModel.canRename(to: text) ?? false
            },
            onConfirm: { [weak self] name in
                do {
                    try self?.viewModel.rename(to: name)
                } catch {
                    HUD.showMessage("改名失败", detail: error.localizedDescription, style: .error)
                }
            }
        )
    }

    /// 「删除播放列表」—— 先确认。删完由快照变空 → 页面 `apply` 请路由退回去。
    func confirmDeletePlaylist() {
        guard !isFavorites, let page else { return }

        AppAlert.present(
            from: page,
            title: "您确定要从音乐库中删除此播放列表吗？",
            actions: [
                AppAlert.Action("删除", style: .destructive) { [weak self] in
                    guard let self else { return }
                    do {
                        try self.viewModel.deletePlaylist()
                    } catch {
                        HUD.showMessage("删除失败", detail: error.localizedDescription, style: .error)
                    }
                },
            ]
        )
    }

    // MARK: - 手动排序

    /// 进手动排序。
    ///
    /// 🔴 **先清搜索再进编辑态**（跟歌单列表页同一条）：搜索结果是临时子集，
    /// 在子集上拖没有意义；清词同步推全量快照，进编辑态之后落表不再重画。
    func beginManualSorting() {
        guard let listController, !listController.songs.isEmpty else { return }
        viewModel.setSearchText("")
        page?.searchController.isActive = false
        viewModel.beginReordering()
    }

    /// 「完成」—— 把拖出来的顺序写回去。
    @objc func finishManualSorting() {
        guard let listController else { return }
        do {
            try viewModel.finishReordering(listController.songs.map(\.id))
        } catch {
            HUD.showMessage("排序没保存上", detail: error.localizedDescription, style: .error)
        }
    }

    /// 「取消」—— 什么都不写库；VM 恢复排序字段并显式重推快照。
    @objc func cancelManualSorting() {
        viewModel.cancelReordering()
    }
}

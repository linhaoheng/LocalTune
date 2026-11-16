import UIKit

/// 歌单页**动作协作者** —— 改名 / 删除 / 新建 / 封面 / 添加到播放列表 / 两个菜单 / 手动排序。
///
/// 页面私有协作者：弹窗、清搜索、进编辑态都是页面出口的事（页面 `weak` 注入）；
/// 改名、删除、写顺序、新建、封面都交给 VM —— 协作者不认识 `LibraryStore`。
/// 挑图走 `PlaylistCoverPickerSession`（闭包捕获 id，选完可裁）。
@MainActor
final class PlaylistsActionsController: NSObject {

    // MARK: - 依赖

    private let viewModel: PlaylistsViewModel

    /// 「加入歌单」要走跳转 —— 只从 `AppRouter` 出去。
    private let router: AppRouter

    /// 弹警告、弹选图会话的出口。
    private weak var page: UIViewController?

    /// 进手动排序前先把搜索退掉 —— 搜索框归页面装配（挂导航栏），这里只是收它。
    private unowned let searchController: UISearchController

    /// 「完成」写回顺序时读的**就是**列表那份 `userRows` —— 页面装配时接上。
    private weak var listController: PlaylistsListController?

    init(
        viewModel: PlaylistsViewModel,
        router: AppRouter,
        page: UIViewController,
        searchController: UISearchController
    ) {
        self.viewModel = viewModel
        self.router = router
        self.page = page
        self.searchController = searchController
    }

    // MARK: - 装配期接线

    /// 列表协作者 —— 页面把两边的 `weak` 引用接好（见 `PlaylistsViewController`）。
    func wire(listController: PlaylistsListController) {
        self.listController = listController
    }

    // MARK: - 行上的五项

    /// 「修改封面图片」—— 相册选图 + 系统裁剪 → 存 `Library/covers/`。
    func changeCover(_ row: PlaylistRow) {
        guard let page else { return }
        PlaylistCoverPickerSession.present(
            from: page,
            playlistID: row.id,
            onPicked: { [weak self] playlistID, image in
                guard let self else { return }
                do {
                    try self.viewModel.setPlaylistCover(image, playlistID: playlistID)
                } catch {
                    HUD.showMessage("换封面失败", detail: error.localizedDescription, style: .error)
                }
            },
            onFailed: { PlaylistCoverMessaging.showPickFailure($0) }
        )
    }

    /// 「生成封面」—— 拿歌单里带封面的歌拼 1/2/3/4 张；有手挑则直接盖掉（不弹确认）。
    /// 缩略 + 拼图在后台，点菜单不堵主线程。
    func generateCover(_ row: PlaylistRow) {
        guard let page else { return }
        viewModel.generatePlaylistCover(playlistID: row.id) { result in
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

    /// 「添加到播放列表」—— 把本歌单里的歌批量加进别的歌单（复用曲库多选那条路）。
    func addToPlaylist(_ row: PlaylistRow) {
        let trackIDs: [Track.ID]
        do {
            trackIDs = try viewModel.trackIDs(in: row.id)
        } catch {
            HUD.showMessage("读取歌单失败", detail: error.localizedDescription, style: .error)
            return
        }
        guard !trackIDs.isEmpty else {
            HUD.showMessage("这个歌单里还没有歌曲")
            return
        }
        router.presentAddTracksToPlaylists(trackIDs: trackIDs)
    }

    /// 「重新命名」。
    ///
    /// 🔴 **名字清空时「保存」是灰的、按不动** ——
    /// 早先那一版是"不写库 + 弹一句「歌单名不能为空」"，用户得先按错一次才知道；
    /// 更糙的做法是直接把空名字原样写进库。
    /// 现在改成让那个键**根本按不动**，一开始名字就是空的也一样灰。
    ///
    /// ⚠️ 判据（去空白之后空不空）只在 `viewModel.canRename(to:)` 那一处，
    /// 这里**不许再写一遍** `trimmingCharacters`。
    func rename(_ row: PlaylistRow) {
        guard let page else { return }
        // 🔴 名字清空时「保存」是灰的、按不动 —— 判据只在
        // `viewModel.canRename(to:)`，这里把判据交给 `AppAlert` 接线，自己不重写 trim。
        AppAlert.prompt(
            from: page,
            title: "重新命名",
            initialText: row.title,
            confirmTitle: "保存",
            isValid: { [weak self] text in
                self?.viewModel.canRename(to: text) ?? false
            },
            onConfirm: { [weak self] name in
                // ⚠️ 名字空时这个键是灰的、进不来；真进来了 VM 也挡着（双保险）。
                do {
                    try self?.viewModel.renamePlaylist(id: row.id, to: name)
                } catch {
                    HUD.showMessage("改名失败", detail: error.localizedDescription, style: .error)
                }
            }
        )
    }

    /// 「删除播放列表」—— 先确认。
    func confirmDelete(_ row: PlaylistRow) {
        // ⚠️ 双保险：数据层也挡着（见 `LibraryStore.delete`），界面上那一项的「删除」本来就置灰了。
        guard !row.isFavorites, let page else { return }

        AppAlert.present(
            from: page,
            // 🔴 标题 —— 原先那句「你确定要删除歌单《X》吗？」是我们自己写的，对齐掉。
            title: "您确定要从音乐库中删除此播放列表吗？",
            // ⚠️ **没有说明行**：原先那句「歌单里的歌曲不会被删除。」
            // 是我们自己加的，那边只有标题 —— 对齐掉。
            actions: [
                AppAlert.Action("删除", style: .destructive) { [weak self] in
                    guard let self else { return }
                    do {
                        try self.viewModel.deletePlaylists([row.id])
                        HUD.showMessage("歌单已删除", style: .success)
                    } catch {
                        HUD.showMessage("删除失败", detail: error.localizedDescription, style: .error)
                    }
                },
            ]
        )
    }

    // MARK: - 新建

    /// 新建一个歌单 —— 导航栏那个加号，**同一个入口**。
    @objc func createPlaylistTapped() {
        guard let page else { return }
        AppAlert.prompt(
            from: page,
            title: "新建播放列表",
            placeholder: "歌单名称",
            confirmTitle: "保存",
            onConfirm: { [weak self] name in
                do {
                    // ⚠️ 名字留空**不报错**：VM 会用默认名兜底（一个歌单总得有个名字，
                    // 而"点了保存什么都没发生"更让人摸不着头脑）。
                    try self?.viewModel.createPlaylist(name: name)
                } catch {
                    HUD.showMessage("新建失败", detail: error.localizedDescription, style: .error)
                }
            }
        )
    }

    // MARK: - 菜单

    /// 导航栏那个「更多」—— **手动排序 + 排序**两项。
    func makeMoreMenu() -> UIMenu {
        let manual = UIAction(
            title: "手动排序",
            image: UIImage(systemName: "hand.tap")
        ) { [weak self] _ in
            self?.beginManualSorting()
        }
        return UIMenu(children: [manual, makeSortMenu()])
    }

    /// 排序子菜单 —— **两组**（排序字段 / 升序降序），两组之间那条分割线由系统画。
    ///
    /// ⚠️ 每组都套一层 `.displayInline` 的 `UIMenu`：**两组之间那条分割线就是它画出来的**
    /// （不用自己插一个分隔项）。组内则是「当前项打勾」。
    ///
    /// ⚠️ 打勾是**建菜单那一刻**的状态，菜单自己不会变 —— 排序一变就得重建（见页面 `bind()`）。
    ///
    /// 🔴 **选到「手动」时，升降序那两项置灰**：
    /// 手动那一档**压根不比升 / 降**（顺序是用户拖出来的，见 `PlaylistSort.isAscending`），
    /// 原先两项照样能点、点了也确实没变化 —— 手感就是"点了没反应"。
    /// 置灰之后用户一眼看得出"这两项在这一档上不算数"，不必点了才知道。
    /// ⚠️ 跟打勾**同一条命**：算的是"建菜单那一刻"的档位，排序一变由页面重建。
    private func makeSortMenu() -> UIMenu {
        let directionDisabled = viewModel.sortMode == .manual

        let modeGroup = UIMenu(
            options: .displayInline,
            children: PlaylistSortMode.allCases.map { mode in
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
                let action = UIAction(
                    title: direction.menuTitle,
                    state: viewModel.sortDirection == direction ? .on : .off
                ) { [weak self] _ in
                    self?.viewModel.setSortDirection(direction)
                }
                // 手动档下两项都置灰（理由见上）—— 勾**留着**，用户还看得见当前存的是哪个方向。
                if directionDisabled {
                    action.attributes = .disabled
                }
                return action
            }
        )

        return UIMenu(
            title: "排序",
            image: UIImage(systemName: "arrow.up.arrow.down"),
            children: [modeGroup, directionGroup]
        )
    }

    // MARK: - 手动排序

    /// 进手动排序。
    private func beginManualSorting() {
        // ⚠️ 先把搜索清掉：搜索出来的只是一屏"临时的子集"，在那个子集上拖顺序没有意义
        // —— 拖完写回去的是**整个**用户歌单的顺序。
        //
        // 🔴 **顺序不能反**：这一句必须**先**清搜索词、再进编辑态。
        // 清搜索词是**同步**推一份新快照（列表变回全量），列表据此把 `userRows` 换掉；
        // 而进编辑态之后快照就不再往上画了（见 `PlaylistsListController.apply`）——
        // 反过来的话，拖的会是刚才那一屏搜索结果。
        // 下面那句 `isActive = false` 只是把搜索框收起来，跟数据无关。
        viewModel.setSearchText("")
        searchController.isActive = false
        // 进编辑态、换导航栏那两颗按钮都是订阅 `isReordering` 之后自动发生的（见页面 `bind()`）。
        viewModel.beginReordering()
    }

    /// 「完成」—— 把拖出来的顺序写回去。
    @objc func finishManualSorting() {
        guard let listController else { return }
        // ⚠️ 顺序就从 `userRows` 拿：拖动那一下已经把它改好了（见 `PlaylistsListController` 的
        // `moveRowAt`），它就是用户眼前那个顺序。别去问 VM —— 它手里那份还是"库里的顺序"呢。
        do {
            try viewModel.finishReordering(listController.userRows.map(\.id))
        } catch {
            HUD.showMessage("排序没保存上", detail: error.localizedDescription, style: .error)
        }
    }

    /// 「取消」—— 什么都不写库；VM 恢复排序字段并显式重推快照，页面照着重画。
    @objc func cancelManualSorting() {
        viewModel.cancelReordering()
    }
}

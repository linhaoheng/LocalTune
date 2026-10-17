import RxSwift
import SnapKit
import UIKit

/// 歌单页 —— **只做三件事：订阅快照 → 渲染 → 把用户动作转给 VM**。
///
/// 这里不排序、不查库、不拼字符串：排序和过滤是 `PlaylistsViewModel` 的事，
/// 数据是 `LibraryStore` 的事。
///
/// ⚠️ **列表、动作、添加模式分给三个页面私有协作者**（这个文件只留"这一页本身"：装配、订阅、布局骨架、导航栏）：
/// - `PlaylistsListController` —— 列表的**结构**（两段、拖拽、怎么画一行、快照落表）；
/// - `PlaylistsActionsController` —— 用户动作（新建 / 改名 / 删除 / 两个菜单 / 手动排序的进出）；
/// - `PlaylistsAddingTracksController` —— 歌曲页多选进入的添加模式。
///
/// 🔴 **这一页没有空状态** —— 不摆「还没有歌单」那句话、也没有「新建歌单」按钮：
/// 「最爱的歌曲」恒占一行，列表**永远不会是空的**，摆一句"你还没有歌单"是假话；
/// 而"新建"在导航栏上本来就有入口（那个加号）。
/// ⚠️ 「搜了没搜着」是另一回事 —— 那条走 `bindSearchFeedback()` 弹一句提示，不在这儿。
final class PlaylistsViewController: BaseViewController {

    // MARK: - 依赖

    /// 跨页跳转 —— 点一行进歌单详情页（这一件事归列表协作者，装配时递给它）。
    private let router: AppRouter

    /// 页面状态 —— 订阅在 `bind()` 里，其余都由协作者自己持有。
    private let viewModel: PlaylistsViewModel

    /// 非空时，这一页是从歌曲页多选进入的「选择歌单」模式（归添加模式协作者用）。
    private let addingTracks: PlaylistAddingTracksState?

    /// 添加模式是不是开着 —— 决定标题、导航栏和表格表面（装配只看它）。
    private var isAddingTracks: Bool { addingTracks != nil }

    // MARK: - 零件

    private let tableView = BaseTableView(frame: .zero, style: .plain)

    /// 搜索框 —— **挂导航栏上**，它不是页面里的一块。
    ///
    /// ⚠️ 进手动排序时要先把搜索退掉（动作协作者收它，装配时递过去）。
    private let searchController = UISearchController(searchResultsController: nil)

    /// 搜索转发器 —— **页面必须持有它**（`searchResultsUpdater` 只持 `weak`，没人抱住就静默失灵）。
    /// 🔴 `lazy`：装配时才碰 `viewModel`，let 属性初始化阶段还没轮到它。
    private lazy var searchForwarder = SearchTextForwarder(target: viewModel)

    // MARK: - 协作者

    /// 列表协作者 —— 两段内容跟它走；装配时把同页另外两个协作者的引用接上。
    private lazy var listController: PlaylistsListController = {
        let controller = PlaylistsListController(
            viewModel: viewModel,
            tableView: tableView,
            router: router,
            artworkProvider: artworkProvider
        )
        controller.actionsController = actionsController
        controller.addingController = addingController
        actionsController.wire(listController: controller)
        return controller
    }()

    /// 动作协作者 —— 行上五动作、两个菜单、手动排序。
    private lazy var actionsController = PlaylistsActionsController(
        viewModel: viewModel,
        router: router,
        page: self,
        searchController: searchController
    )

    /// 添加模式协作者 —— 只有从歌曲页多选进来才存在。
    private lazy var addingController: PlaylistsAddingTracksController? = {
        guard let addingTracks else { return nil }
        return PlaylistsAddingTracksController(
            viewModel: viewModel,
            tableView: tableView,
            page: self,
            addingTracks: addingTracks
        )
    }()

    // MARK: - 导航栏

    /// 导航栏右两颗（默认那一组）。
    private lazy var addItem = UIBarButtonItem(
        barButtonSystemItem: .add,
        target: actionsController,
        action: #selector(PlaylistsActionsController.createPlaylistTapped)
    )

    /// 导航栏最右边那个「更多」。
    ///
    /// ⚠️ 菜单里的打勾看的是**建菜单那一刻**的排序状态，而 `UIBarButtonItem` 的菜单
    /// 建好之后**不会自己刷新**。所以排序一变就得重建这个菜单（见 `bindSortMenuRebuild()`）。
    private lazy var moreItem = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis.circle"),
        menu: actionsController.makeMoreMenu()
    )

    /// 手动排序里顶掉上面那两颗的「完成」/「取消」。
    ///
    /// ⚠️ 用系统的 `.done` / `.cancel` 档 —— 标题由系统按语言给，不用自己写字符串。
    private lazy var doneItem = UIBarButtonItem(
        barButtonSystemItem: .done,
        target: actionsController,
        action: #selector(PlaylistsActionsController.finishManualSorting)
    )
    private lazy var cancelItem = UIBarButtonItem(
        barButtonSystemItem: .cancel,
        target: actionsController,
        action: #selector(PlaylistsActionsController.cancelManualSorting)
    )

    // MARK: - 建立

    /// 取图的动作 —— 装配层（`App/AppArtwork.image`）给，配行时递给列表协作者。
    private let artworkProvider: ArtworkProvider

    init(
        library: LibraryStore,
        covers: PlaylistCoverService,
        settings: AppSettings,
        router: AppRouter,
        artworkProvider: @escaping ArtworkProvider,
        addingTrackIDs: [Track.ID] = []
    ) {
        self.router = router
        self.artworkProvider = artworkProvider
        self.addingTracks = addingTrackIDs.isEmpty
            ? nil
            : PlaylistAddingTracksState(trackIDs: addingTrackIDs)
        viewModel = PlaylistsViewModel(
            library: library,
            settings: settings,
            covers: covers
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isAddingTracks ? "添加到播放列表" : "歌单"
        addingController?.loadAddingMemberships()
        layout()
        bind()
    }

    // MARK: - 布局

    private func layout() {
        layoutTableView()
        layoutNavigationItems()
    }

    private func layoutTableView() {
        // 表格的数据源 / 代理由列表协作者在 init 里认领（见 `PlaylistsListController`）。
        // 添加模式照挑歌页：页面、列表和导航栏都用系统分组表面；普通歌单页仍用 pageBackground。
        view.backgroundColor = isAddingTracks ? .systemGroupedBackground : AppColor.pageBackground
        tableView.backgroundColor = isAddingTracks ? .systemGroupedBackground : AppColor.pageBackground
        tableView.separatorColor = AppColor.separator
        // 行高交给系统按内容算（下限在行自己身上）—— 固定行高会把放大后的字裁掉。
        // 估算值取"字没放大时的行高"：系统拿它先排版，滚起来才不用逐行现算。
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = PlaylistTableCell.minimumHeight
        tableView.register(
            PlaylistTableCell.self,
            forCellReuseIdentifier: PlaylistTableCell.reuseIdentifier
        )

        view.addSubview(tableView)
        tableView.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    private func layoutNavigationItems() {
        if isAddingTracks {
            // 这是模态页面里带搜索框的导航控制器；搜索激活时必须由本页提供呈现上下文，
            // 否则系统可能把搜索状态盖到下面的歌曲页上。
            definesPresentationContext = true
            // 添加模式保留歌单列表页右上角原有的「更多」和「加号」；左上另放取消。
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel,
                target: addingController,
                action: #selector(PlaylistsAddingTracksController.closeAddingTracks)
            )
            navigationItem.rightBarButtonItems = [moreItem, addItem]
        } else {
            // ⚠️ `rightBarButtonItems` 数组是**从右往左**数的：数组第 0 个在最右边。
            // 所以屏幕上从左到右是「加号」/「更多」。
            navigationItem.rightBarButtonItems = [moreItem, addItem]
        }

        // 搜索框挂**导航栏**上，往下滚就收起来（系统默认就是它，写出来是为了让人看得见这条规格）。
        if !isAddingTracks {
            searchController.searchResultsUpdater = searchForwarder
            // ⚠️ 不设的话，一进搜索状态底下的列表会被压暗 —— 我们搜的是**同一张表**
            //（结果就在原地换），不需要那层遮罩。
            searchController.obscuresBackgroundDuringPresentation = false
            searchController.searchBar.placeholder = "歌单"
            navigationItem.searchController = searchController
            navigationItem.hidesSearchBarWhenScrolling = true
        }
    }

    // MARK: - 数据

    private func bind() {
        viewModel.snapshot
            .subscribe(onNext: { [weak self] snapshot in
                self?.listController.apply(snapshot)
            })
            .disposed(by: disposeBag)

        bindSortMenuRebuild()
        bindSearchFeedback()
        bindLibraryErrors()
        bindReordering()
    }

    /// 库读不出来 —— **弹一次提示，别装没事**。
    ///
    /// ⚠️ 文案与取舍在 `LibraryErrorNotice` 一处（曲库页 / 歌单页共用）。
    private func bindLibraryErrors() {
        LibraryErrorNotice.bind(viewModel.errors, disposedBy: disposeBag)
    }

    /// 排序一变就**重建「更多」菜单** —— 菜单里那两个勾是"建的时候"定死的，不会自己跟着走。
    ///
    /// ⚠️ `skip(1)`：订阅那一刻会立刻收到一次"当前值"，那不算"变了"；不跳掉就是白建一次。
    private func bindSortMenuRebuild() {
        viewModel.sortState
            .skip(1)
            .subscribe(onNext: { [weak self] _, _ in
                self?.moreItem.menu = self?.actionsController.makeMoreMenu()
            })
            .disposed(by: disposeBag)
    }

    /// 「未找到相关歌单」—— **只在从"有结果"变成"没结果"那一刻弹一次**。
    ///
    /// ⚠️ 不能每敲一个字都弹：搜「abcd」会连弹四次，而用户只是还没敲完。
    /// `distinctUntilChanged` 把重复的挡掉、只放行 `true`，拿到的就是"翻上去"那一下。
    private func bindSearchFeedback() {
        viewModel.snapshot
            .map(\.foundNothing)
            .distinctUntilChanged()
            .filter { $0 }
            .subscribe(onNext: { _ in
                HUD.showMessage("未找到相关歌单")
            })
            .disposed(by: disposeBag)
    }

    /// 进 / 出手动排序 —— 进出编辑态、换导航栏那两颗按钮。
    ///
    /// ⚠️ `skip(1)`：订阅那一刻会先收到一次"现在没在排序"，那不是"变了"。
    private func bindReordering() {
        viewModel.isReordering
            .skip(1)
            .subscribe(onNext: { [weak self] isReordering in
                self?.setReordering(isReordering)
            })
            .disposed(by: disposeBag)
    }

    // MARK: - 导航栏状态

    /// 进 / 出手动排序。
    private func setReordering(_ isReordering: Bool) {
        tableView.setEditing(isReordering, animated: true)
        if isReordering {
            navigationItem.rightBarButtonItems = [doneItem, cancelItem]
        } else {
            restoreDefaultRightBarItems()
        }
    }

    /// 把导航栏右侧恢复成**默认那两颗**（更多 / 加号）。
    ///
    /// ⚠️ 顺手重建「更多」的菜单 —— 菜单里那几个勾是**建的那一刻**定死的，不重建就还是旧状态。
    private func restoreDefaultRightBarItems() {
        moreItem.menu = actionsController.makeMoreMenu()
        navigationItem.rightBarButtonItems = [moreItem, addItem]
    }
}

// MARK: - 搜索转发

// 🔴 `UISearchResultsUpdating` 是 @objc 协议 —— 页面不遵循它，把转发交给
// `searchForwarder`（装配见 `viewDidLoad`）；转发逻辑全工程一份（`SearchTextForwarder`）。

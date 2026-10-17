import RxSwift
import SnapKit
import UIKit

/// 歌单详情页 —— **只做三件事：订阅快照 → 渲染 → 把用户动作转给 VM**。
///
/// 这里不查库、不排序、不拼字符串、不做跳转决定：歌单名和封面来自 `PlaylistDetailViewModel`，
/// 曲目来自 `LibraryStore`，退回去走 `AppRouter`。
///
/// ⚠️ **表头、列表、动作、选择、定位钮、封面流分给六个页面私有协作者**
/// （这个文件只留"这一页本身"：装配、订阅、布局骨架、导航栏）：
/// - `PlaylistDetailHeaderController` —— 表头（挂上去、量高、两个键接线）；
/// - `PlaylistDetailListController` —— 列表的**结构**（数据源、点一行、拖拽）；
/// - `PlaylistDetailActionsController` —— 用户动作（播放 / 菜单 / 改名删除 / 手动排序…）；
/// - `PlaylistDetailSelectionController` —— 选择模式（工具条 / 勾选同步 / 批量移除）；
/// - `PlaylistDetailPlayingLocatorController` —— 右下「定位当前曲」悬浮钮；
/// - `PlaylistDetailCoverFlowController` —— iPad / 手机封面流门控、chrome、方向。
///
/// 🔴 **这一页没有空状态那一块**：歌单空了就只是列表里没有行 ——
/// 表头照常、**页脚也不出统计**（那行字清掉，见 `apply`），两个键点下去**什么都不做**
///（见 `PlaylistDetailActionsController`）。
@MainActor
final class PlaylistDetailViewController: BaseViewController {

    // MARK: - 依赖

    /// 跨页跳转 —— 两处用它：这个歌单在别处被删掉时要请它退回去（本文件 `apply`），
    /// 以及各协作者的跳转（装配时递出去）。
    private let router: AppRouter

    /// 封面流格子取图 —— 装配层注入，格子不碰 `ArtworkStore`（装配时递给协作者）。
    private let artworkProvider: ArtworkProvider

    /// 页面状态 —— 订阅在 `bind()` 里，其余都由协作者自己持有。
    private let viewModel: PlaylistDetailViewModel

    // MARK: - 零件

    private let tableView = BaseTableView(frame: .zero, style: .plain)

    /// 底部那行统计 —— 跟曲库页共用同一个零件。
    private let footerView = ListFooterView()

    /// 索引条按下时、屏幕正中那个气泡（跟曲库页同一零件；显示归列表协作者）。
    private let indexBubble = IndexBubble()

    /// 搜索框 —— **挂导航栏上**，它不是页面里的一块。
    ///
    /// 🔴 **别用 KVC 改取消键文案**（私有属性，审核风险）。
    ///
    /// 搜索转发器 —— **页面必须持有它**（`searchResultsUpdater` 只持 `weak`，没人抱住就静默失灵）。
    private lazy var searchForwarder = SearchTextForwarder(target: viewModel)

    /// ⚠️ 是 `internal`：动作协作者要亮出它（菜单里那一项「搜索」）。
    lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchResultsUpdater = searchForwarder
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchBar.placeholder = "歌曲"
        return controller
    }()

    // MARK: - 协作者

    /// 动作协作者 —— 菜单、播放、移除、改名删除、手动排序。
    private lazy var actionsController = PlaylistDetailActionsController(
        viewModel: viewModel,
        router: router,
        page: self
    )

    /// 选择模式协作者 —— 工具条、勾选同步、批量移除。
    private lazy var selectionController = PlaylistDetailSelectionController(
        viewModel: viewModel,
        page: self,
        tableView: tableView
    )

    /// 表头协作者 —— 挂表头、量高。
    private lazy var headerController = PlaylistDetailHeaderController(
        tableView: tableView,
        artworkProvider: artworkProvider,
        actionsController: actionsController
    )

    /// 定位钮协作者 —— 装 / 显隐 / 滚动定位。
    private lazy var locatorController = PlaylistDetailPlayingLocatorController(
        viewModel: viewModel,
        page: self,
        tableView: tableView
    )

    /// 封面流协作者 —— 门控、嵌子页、chrome、强制锁、转屏。
    private lazy var coverFlowController = PlaylistDetailCoverFlowController(
        viewModel: viewModel,
        router: router,
        artworkProvider: artworkProvider,
        page: self
    )

    /// 列表协作者 —— 数据源、点行、拖拽；装配时把同页其余协作者的引用接上
    ///（它们的 `weak` 引用比生命周期短不了）。
    private lazy var listController: PlaylistDetailListController = {
        let controller = PlaylistDetailListController(
            viewModel: viewModel,
            tableView: tableView,
            router: router,
            artworkProvider: artworkProvider,
            indexBubble: indexBubble,
            actionsController: actionsController,
            locatorController: locatorController
        )
        locatorController.wire(listController: controller)
        selectionController.wire(
            listController: controller,
            locatorController: locatorController
        )
        coverFlowController.wire(
            listController: controller,
            locatorController: locatorController
        )
        actionsController.wire(
            listController: controller,
            coverFlowController: coverFlowController
        )
        return controller
    }()

    // MARK: - 导航栏

    /// 导航栏右两颗之一：「加号」（往这个歌单里加歌）。
    ///
    /// ⚠️ `rightBarButtonItems` 数组是**从右往左**数的：数组第 0 个在最右边。
    private lazy var addItem = UIBarButtonItem(
        barButtonSystemItem: .add,
        target: actionsController,
        action: #selector(PlaylistDetailActionsController.addSongsTapped)
    )

    /// 导航栏最右边那个「更多」。
    ///
    /// ⚠️ **菜单要重建** —— 排序勾 / 「是不是最爱」置灰都是建菜单那一刻定死的。
    /// ⚠️ 是 `internal`：动作协作者在「最爱」变化和 iPad 封面流开关变化时重建它。
    lazy var moreItem = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis.circle"),
        menu: nil
    )

    /// 手动排序里的「完成」。
    private lazy var doneReorderItem = UIBarButtonItem(
        barButtonSystemItem: .done,
        target: actionsController,
        action: #selector(PlaylistDetailActionsController.finishManualSorting)
    )

    /// 手动排序里的「取消」。
    private lazy var cancelReorderItem = UIBarButtonItem(
        barButtonSystemItem: .cancel,
        target: actionsController,
        action: #selector(PlaylistDetailActionsController.cancelManualSorting)
    )

    // MARK: - 建立

    init(
        playlistID: Playlist.ID,
        library: LibraryStore,
        covers: PlaylistCoverService,
        settings: AppSettings,
        trackRemover: TrackRemover,
        playManager: PlayManager,
        router: AppRouter,
        artworkProvider: @escaping ArtworkProvider
    ) {
        self.router = router
        self.artworkProvider = artworkProvider
        viewModel = PlaylistDetailViewModel(
            playlistID: playlistID,
            library: library,
            covers: covers,
            settings: settings,
            trackRemover: trackRemover,
            playManager: playManager
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    /// **见过这个歌单没有。** 用来分开「在别处被删掉」和「打开时它就已经不在」。
    private var hasSeenPlaylist = false

    override func viewDidLoad() {
        super.viewDidLoad()
        layout()
        // 菜单第一次在这儿建：`moreItem` 的 `menu:` 初始化时 `self` 还没成形，不能调实例方法。
        moreItem.menu = actionsController.makeMoreMenu()
        bind()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        coverFlowController.handleCoverFlowWillAppear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        coverFlowController.handleCoverFlowDidAppear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 仅真离开（pop/dismiss）时封面流协作者才动手；present 播页不进那条。
        coverFlowController.handleCoverFlowWillDisappear()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coverFlowController.handleCoverFlowTransition(to: size, with: coordinator)
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        coverFlowController.coverFlowInterfaceOrientations
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        headerController.sizeHeaderToFit()
    }

    // MARK: - 布局

    private func layout() {
        // 表格的数据源 / 代理由列表协作者在 init 里认领（见 `PlaylistDetailListController`）。
        tableView.backgroundColor = AppColor.pageBackground
        tableView.separatorColor = AppColor.separator
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = SongTableCell.minimumHeight
        tableView.register(SongTableCell.self, forCellReuseIdentifier: SongTableCell.reuseIdentifier)

        // 选择模式要用：编辑态能点选、能多选。
        // ⚠️ **手动排序进编辑时会临时关掉**（见 `setReordering`）—— 不关的话行首会冒出圈。
        tableView.allowsSelectionDuringEditing = true
        tableView.allowsMultipleSelectionDuringEditing = true

        // 右侧字母索引条：用副标题色。不设的话它会跟 tint 走成蓝色。
        tableView.sectionIndexColor = AppColor.subtitle

        view.addSubview(tableView)
        tableView.snp.makeConstraints { $0.edges.equalToSuperview() }

        headerController.installHeader()
        footerView.attach(to: tableView)
        layoutNavigationItems()

        // 气泡压在页面正中 —— 最后加，保证它在表格上面。
        view.addSubview(indexBubble)
        tableView.onIndexBarTouch = { [weak self] isTouching in
            if !isTouching { self?.indexBubble.hide() }
        }

        locatorController.install()
    }

    private func layoutNavigationItems() {
        navigationItem.rightBarButtonItems = [moreItem, addItem]
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = true
        // 🔴 压栈进来的页面得设它：搜索激活时 UIKit 要找呈现上下文。
        definesPresentationContext = true
    }

    // MARK: - 数据

    private func bind() {
        viewModel.snapshot
            .subscribe(onNext: { [weak self] snapshot in
                self?.apply(snapshot)
            })
            .disposed(by: disposeBag)

        viewModel.playbackChrome
            .subscribe(onNext: { [weak self] chrome in
                self?.listController.refreshVisiblePlaybackState()
                self?.locatorController.syncPlayingLocatorAvailability()
                self?.coverFlowController.setPlaying(chrome.isPlaybackActive)
            })
            .disposed(by: disposeBag)

        // 库读不出来 —— **弹一次提示，别装没事**（文案与取舍在 `LibraryErrorNotice` 一处）。
        LibraryErrorNotice.bind(viewModel.errors, disposedBy: disposeBag)

        bindSortMenuRebuild()
        bindReordering()

        // 选择模式：**进 / 出**换导航栏和工具条；**选中变了**更新两个破坏键。
        //
        // ⚠️ 两条流**分开订** —— 合成一条的话，每勾一行都会重跑一遍「换导航栏」。
        // ⚠️ `skip(1)`：订阅那一刻会立刻收到一次当前值，那不算「变了」。
        viewModel.isSelecting
            .skip(1)
            .subscribe(onNext: { [weak self] in self?.selectionController.applySelectingChrome($0) })
            .disposed(by: disposeBag)

        viewModel.selectedIDs
            .subscribe(onNext: { [weak self] ids in
                self?.selectionController.updateToolbarAvailability(ids)
            })
            .disposed(by: disposeBag)
    }

    /// 排序一变就**重建「更多」菜单** —— 勾是建的时候定死的。
    private func bindSortMenuRebuild() {
        viewModel.sortState
            .skip(1)
            .subscribe(onNext: { [weak self] _, _ in
                self?.moreItem.menu = self?.actionsController.makeMoreMenu()
            })
            .disposed(by: disposeBag)
    }

    /// 进 / 出手动排序 —— 进出编辑态、换导航栏那两颗按钮。
    private func bindReordering() {
        viewModel.isReordering
            .skip(1)
            .subscribe(onNext: { [weak self] isReordering in
                self?.setReordering(isReordering)
            })
            .disposed(by: disposeBag)
    }

    /// 列表内容换了 —— 编排：列表协作者落表，选中集合 / 页脚 / 封面流跟在后面。
    private func apply(_ snapshot: PlaylistDetailViewModel.Snapshot) {
        // 🔴 手动排序中**不重画**：那会儿 `songs` 是用户拖出来的顺序，
        // 快照推来的还是库里旧的 —— 照着重画，正在拖的行会跳回去。
        guard !viewModel.isReorderingNow else { return }

        guard let info = snapshot.info else {
            if hasSeenPlaylist { router.pop(from: self) }
            return
        }
        hasSeenPlaylist = true

        title = info.name
        headerController.show(cover: info.cover)

        // 「是不是最爱」变了就重建菜单（删除那一项的置灰是建菜单时定死的）。
        actionsController.updateFavorites(info.isFavorites)

        let visibleIDs = listController.apply(snapshot)

        // 列表内容换了之后收拾一遍选中集合（跟曲库页同一条）。
        selectionController.pruneSelection(to: visibleIDs)

        if visibleIDs.isEmpty {
            footerView.clear()
        } else {
            footerView.show(count: visibleIDs.count, totalDurationMs: snapshot.totalDurationMs)
        }

        coverFlowController.refreshCoverFlowAfterSnapshotChange()
    }

    // MARK: - 导航栏状态

    private func setReordering(_ isReordering: Bool) {
        if isReordering {
            // 🔴 手动排序只要拖柄，不要行首圈 —— 进编辑前也关这两项。
            tableView.allowsSelectionDuringEditing = false
            tableView.allowsMultipleSelectionDuringEditing = false
            tableView.setEditing(true, animated: true)
            navigationItem.rightBarButtonItems = [doneReorderItem, cancelReorderItem]
        } else {
            tableView.setEditing(false, animated: true)
            tableView.allowsSelectionDuringEditing = true
            tableView.allowsMultipleSelectionDuringEditing = true
            restoreDefaultRightBarItems()
        }
        listController.refreshVisiblePlaybackState()
        locatorController.syncPlayingLocatorAvailability()
    }

    /// 把导航栏右侧恢复成默认那两颗（更多 / 加号），并重建菜单勾。
    /// 选择模式退出时要用（那会儿右侧被「取消」占着，见 `PlaylistDetailSelectionController`）。
    func restoreDefaultRightBarItems() {
        moreItem.menu = actionsController.makeMoreMenu()
        navigationItem.rightBarButtonItems = [moreItem, addItem]
    }
}

// MARK: - 搜索转发

// 🔴 `UISearchResultsUpdating` 是 @objc 协议 —— 页面不遵循它，把转发交给
// `searchForwarder`（装配见 `searchController`）；转发逻辑全工程一份（`SearchTextForwarder`）。

// MARK: - 方向控制标记

/// iPhone：播放页和**歌单详情**自己声明 `ControlsWindowOrientation`；其余竖屏。
extension PlaylistDetailViewController: ControlsWindowOrientation {}

import RxSwift
import SnapKit
import UIKit

/// 曲库页 —— **只做三件事：订阅快照 → 渲染 → 把用户动作转给 VM**。
///
/// 这里不排序、不查库、不拼字符串、不做跳转决定：排序和过滤是 `SongsViewModel` 的事，
/// 数据是 `LibraryStore` 的事，跳转是 `AppRouter` 的事。
///
/// ⚠️ **列表、选择、动作、导入、空状态、定位钮分给六个页面私有协作者**
/// （这个文件只留"这一页本身"：装配、订阅、导航栏菜单）：
/// - `SongsListController` —— 列表的**结构**（差量数据源、分段、段头、索引条、行怎么消失）；
/// - `SongsSelectionController` —— 选择模式（进 / 出、底部工具条、多选删除、添加到播放列表）；
/// - `SongsActionsController` —— 行尾「更多」菜单 / 播放 / 删除 / 分享；
/// - `SongsImportController` —— 导入入口（打开文件 / 扫描）与选完文件之后那一下；
/// - `SongsEmptyStateController` —— 空状态（空的时候显示什么、按钮点了干什么）；
/// - `SongsPlayingLocatorController` —— 右下「定位当前曲」悬浮钮。
///
/// ⚠️ 底部那行统计**不在这儿** —— 它是跟歌单详情页共用的零件，在 `Components/SongList/`。
final class SongsViewController: BaseViewController {

    // MARK: - 依赖

    /// 导入 / 扫描的入口 —— 装配时递给导入协作者。
    private let importService: ImportService

    /// 跳转 —— 点行开播放页（列表协作者）、多选后添加到播放列表（选择协作者）、
    /// 行尾编辑 / 加入歌单（动作协作者）都从这里出去。
    private let router: AppRouter

    /// 外观设置（深浅色）—— **只有这个文件用**（导航栏那个切换按钮）。
    private let settings: AppSettings

    /// 页面状态 —— 订阅在 `bind()` 里，其余都由协作者自己持有。
    private let viewModel: SongsViewModel

    // MARK: - 零件

    private let tableView = BaseTableView(frame: .zero, style: .plain)

    /// 索引条按下时、屏幕正中那个气泡。
    ///
    /// ⚠️ 要**加在页面视图上**（见 `layout()`），显示时才拿得到"页面正中"这个参照；
    /// 显示它的是列表协作者（索引条回调在那边），装配时递过去。
    let indexBubble = IndexBubble()

    /// 底部那行统计（「12首歌, 时间: 05:07」）—— 跟歌单详情页共用同一个零件。
    ///
    /// ⚠️ 挂给表格的是**它自己**（不是里面那个 label）—— 为什么得多一层、为什么挂上之后
    /// 不能碰它的 frame，都在 `ListFooterView` 顶上写着。
    private let footerView = ListFooterView()

    /// 顶上那条**「音乐文件不在本机」**的横幅 —— 只在整份曲库都像丢了时才挂上去。
    ///
    /// ⚠️ 它**只解释、不藏行**：列表照实显示（每一行自己带「不在本机」小标）。
    /// 把行藏起来就是**静默跳过** —— 用户会以为歌丢了。
    private let missingBanner = MissingFilesBanner()

    /// 横幅现在该显示什么 —— `(几首, 要不要显示)`。
    ///
    /// ⚠️ **存这一份是必需的**，不是缓存：`apply(snapshot)` 的第一趟会赶在
    /// **表格还没有宽度**的时候跑（订阅那一刻库就推了第一份快照）。那会儿量出来的高度是错的
    ///（宽度 0 ⇒ 文字挤成一列），所以得把"该显示什么"记下来，等布局完再量一遍。
    private var missingBannerState: (count: Int, shows: Bool) = (0, false)

    /// 上一次给横幅量高度用的表格宽度 —— 没变就不重量。
    private var lastBannerWidth: CGFloat = 0

    /// 上一次给横幅量高度时的条数 —— 条数一变文案就变长变短，高度也得重量。
    private var lastBannerCount: Int = -1

    // MARK: - 协作者

    /// 动作协作者 —— 行尾菜单、删除、分享。
    private lazy var actionsController = SongsActionsController(
        viewModel: viewModel,
        router: router,
        page: self
    )

    /// 导入协作者 —— 打开文件 / 扫描，选完文件之后那一下也归它。
    private lazy var importController = SongsImportController(
        importService: importService,
        page: self
    )

    /// 空状态协作者 —— 占位的摆 / 收，按钮走了导入协作者那个入口。
    private lazy var emptyStateController = SongsEmptyStateController(
        page: self,
        importController: importController
    )

    /// 定位钮协作者 —— 装 / 显隐 / 滚动定位。
    private lazy var locatorController = SongsPlayingLocatorController(
        viewModel: viewModel,
        page: self,
        tableView: tableView
    )

    /// 列表协作者 —— 差量数据源、分段、点行、滚动回调都归它；
    /// 装配时把同页其余协作者的引用接上（它们的 `weak` 引用比生命周期短不了）。
    private lazy var listController: SongsListController = {
        let controller = SongsListController(
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
            locatorController: locatorController,
            actionsController: actionsController
        )
        return controller
    }()

    /// 选择模式协作者 —— 进 / 出、底部工具条、多选删除。
    private lazy var selectionController = SongsSelectionController(
        viewModel: viewModel,
        router: router,
        page: self,
        tableView: tableView
    )

    /// 取图的动作 —— 装配层（`App/AppArtwork.image`）给，配行时递给列表协作者。
    private let artworkProvider: ArtworkProvider

    // MARK: - 建立

    init(
        library: LibraryStore,
        importService: ImportService,
        trackRemover: TrackRemover,
        settings: AppSettings,
        playManager: PlayManager,
        router: AppRouter,
        artworkProvider: @escaping ArtworkProvider
    ) {
        self.importService = importService
        self.router = router
        self.settings = settings
        self.artworkProvider = artworkProvider
        // 🔴 播放器**不**留在页面手里 —— 往下传给 VM，由 VM 决定"播哪首"（见 `SongsViewModel.playTrack`）。
        // 页面只负责"用户点了哪一行"，不认识播放器、不直接调它。
        viewModel = SongsViewModel(
            library: library,
            settings: settings,
            trackRemover: trackRemover,
            playManager: playManager,
            artworkProvider: artworkProvider
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "歌曲"
        layout()
        bind()
    }

    /// 🔴 横幅的高度**表格自己不会算**，只能等宽度真有了再量一遍（见 `missingBannerState`）。
    /// 第一趟快照是赶在布局之前到的，那会儿量出来是错的 —— 这里补上。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutMissingBannerIfNeeded()
    }

    // MARK: - 布局

    private func layout() {
        layoutTableView()
        layoutNavigationItems()
        // 底部统计条 —— 挂法（给一次高度、之后不许再碰 frame）封在组件里。
        footerView.attach(to: tableView)
        // 横幅上那两个键 —— 「重新导入」走现成的导入入口，「移除」走动作协作者
        //（页面只把动作转出去，不认识导入服务和删歌那条路）。
        missingBanner.onReimport = { [weak self] in self?.importController.presentFilePicker() }
        missingBanner.onRemoveMissing = { [weak self] in self?.actionsController.confirmRemoveMissing() }
        // 气泡压在页面正中 —— 最后加，保证它在表格上面。
        view.addSubview(indexBubble)
        // **手指一松就把气泡收掉** —— 表格那边旁听了系统索引条上的触摸
        //（索引条自己是不会说"我松手了"的）。
        tableView.onIndexBarTouch = { [weak self] isTouching in
            if !isTouching { self?.indexBubble.hide() }
        }
        // 定位钮盖在最上面（滚动时才露）。
        locatorController.install()
    }

    private func layoutTableView() {
        tableView.prefetchDataSource = self
        tableView.backgroundColor = AppColor.pageBackground
        tableView.separatorColor = AppColor.separator
        // 选择模式下那个勾的颜色 = **强调色**。
        // ⚠️ 勾是**系统的子视图**，`tintColor` 会顺着继承下去，所以设在表格上就够，不用逐个 cell 设。
        // ⚠️ 系统只有**这一个**颜色设置管那个勾 —— 空心圈的边和选中后的填充是同一个值，
        // 分不开（要分开就得自己画一个圈）。
        tableView.tintColor = AppColor.accent
        // 右侧字母索引条：用副标题色。不设的话它会跟 tint 走成蓝色。
        tableView.sectionIndexColor = AppColor.subtitle
        // 行高交给系统按内容算（下限在行自己身上）—— 固定行高会把放大后的字裁掉。
        // 估算值取"字没放大时的行高"：系统拿它先排版，滚起来才不用逐行现算。
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = SongTableCell.minimumHeight
        tableView.register(SongTableCell.self, forCellReuseIdentifier: SongTableCell.reuseIdentifier)
        // 表格的 delegate 由列表协作者在 init 里认领（见 `SongsListController`）；
        // 数据源是差量源，由它建好即接（建与挂是同一个表达式）。
        // 选择模式要用的两个开关 —— **一次设好，之后不再动**：
        // 编辑模式下能选中、能多选，而那个勾是**系统画的**（不用自己画一个）。
        // ⚠️ 这两个只管**编辑模式**；非编辑模式能不能点选是另一个开关（`allowsSelection`，
        // 默认就是开的）—— 那一路是"点一行 = 播这一首"，见 `+Selection` 的 `didSelectRowAt`。
        tableView.allowsSelectionDuringEditing = true
        tableView.allowsMultipleSelectionDuringEditing = true

        view.addSubview(tableView)
        tableView.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    private func layoutNavigationItems() {
        // ⚠️ `rightBarButtonItems` 数组是**从右往左**数的：数组第 0 个在最右边。
        // 所以屏幕上从左到右是「加号」/「主题」/「更多」——
        // 跟规格里「从左到右 加号 / 主题 / 更多」的排法一致。
        navigationItem.rightBarButtonItems = [moreItem, themeItem, importItem]
        // 无障碍标签说的是「**点了会变成什么**」，不是「现在是什么」。
        themeItem.accessibilityLabel = nextTheme.title

        // 搜索框挂**导航栏**上 —— 它不是页面里的一块，是导航栏的一部分。
        navigationItem.searchController = searchController
        // 往下滚就收起来。系统默认就是它，写出来是为了让人看得见这条规格。
        navigationItem.hidesSearchBarWhenScrolling = true
        // 搜索时"被压住的那层上下文"——**不设**（曲库页也不设）。
        // 只在「歌单详情」「添加歌曲到歌单」那两页设它，那两页是压栈进来的、各带自己的搜索。
    }

    /// 「加号」菜单 —— 就这两项。
    ///
    /// ⚠️ 用的是 `UIBarButtonItem(image:menu:)`（iOS 14 起）。**没有** `image:primaryAction:menu:`
    /// 这个构造器 —— 核过 SDK 头文件 `UIBarButtonItem.h:92`，带 `image:` 的只有
    /// `image:style:target:action:`、`image:menu:`、`title:image:target:action:menu:` 这几种。
    private lazy var importItem = UIBarButtonItem(
        image: UIImage(systemName: "plus"),
        menu: makeImportMenu()
    )

    /// 导航栏那个「主题」按钮 —— 浅色 / 深色来回换，图标跟着换。
    ///
    /// ⚠️ 用 `customView` 包一个自绘按钮，不是普通的 `UIBarButtonItem(image:)`：
    /// 要的是「换图时**一张缩掉、一张长出来**」，系统那种只能直接换一张图，没有那个过程。
    ///
    /// ⚠️ 图标顺序**跟着 `AppTheme.allCases` 走**，别手写 —— 换档位顺序时两边一起变。
    ///
    /// ⚠️ 尺寸也得自己定（`barButtonIconPointSize`）：自绘的吃不到导航栏给
    /// `UIBarButtonItem` 的那层规格，不指定就按默认大小渲 —— 夹在旁边两个系统按钮中间会小一圈。
    private lazy var themeButton: IconTransitionButton = {
        let configuration = UIImage.SymbolConfiguration(pointSize: AppMetrics.barButtonIconPointSize)
        let icons = AppTheme.allCases.compactMap {
            UIImage(systemName: $0.iconName, withConfiguration: configuration)
        }
        // 🔴 **出生就露当前那一档** —— 图标数组是按 `AppTheme.allCases` 顺序建的，
        // 而「现在在哪一档」只有 `settings.theme` 知道，得在这儿指给它。
        // 不指的话按钮会停在数组第 0 张（浅色）—— 窗口已经是深色、图标还是太阳，
        // 就是「切深色后重进 App」看到的那一幕。
        let button = IconTransitionButton(
            icons: icons,
            initialIndex: themeIconIndex(of: settings.theme),
            iconColor: AppColor.accent
        )
        button.addTarget(self, action: #selector(toggleTheme), for: .touchUpInside)
        return button
    }()

    /// 某一档在图标数组里的下标。
    ///
    /// 图标按 `AppTheme.allCases` 的顺序建 ⇒ 下标就是这一档在 `allCases` 里的位置。
    /// **换算只此一处**：建按钮时指初始图、点击时指目标图，两处都走它。
    private func themeIconIndex(of theme: AppTheme) -> Int {
        // `allCases` 是全量 ⇒ 一定找得到；`?? 0` 只是给编译器一个兜底。
        AppTheme.allCases.firstIndex(of: theme) ?? 0
    }

    private lazy var themeItem = UIBarButtonItem(customView: themeButton)

    /// 点一下会变成的那一档。
    private var nextTheme: AppTheme {
        settings.theme == .dark ? .light : .dark
    }

    /// 图标比颜色渐变**晚多久**开始动（秒）。
    ///
    /// 实机调出来的手感值：太早（跟渐变同时）会"颜色没动图标先换"，太晚（等渐变走完）慢半拍。
    private static let iconSwitchDelay: TimeInterval = 0.15

    /// 换一档：**先让颜色渐变过去，图标随后跟上**。
    ///
    /// 🔴 顺序不能反。反过来（图标先动、颜色后变）看着像两件事各干各的；
    /// 颜色先动、图标随后，才是「同一件事的两个阶段」。
    ///
    /// ⚠️ 界面这边**不用自己重画** —— `AppColor` 那一层是动态色，
    /// 窗口外观一变，系统会自己重取一遍。
    @objc private func toggleTheme() {
        let next = nextTheme
        settings.theme = next

        // 渐变那一下别让再点 —— 不然图标会连换两次，跟颜色对不上。
        themeButton.isUserInteractionEnabled = false

        AppAppearance.applyTheme(next, animated: true) { [weak self] in
            self?.themeButton.isUserInteractionEnabled = true
        }

        // ⚠️ 图标**不等渐变走完**（那样慢半拍）—— 晚多久见 `iconSwitchDelay`。
        let index = themeIconIndex(of: next)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.iconSwitchDelay) { [weak self] in
            guard let self else { return }
            self.themeButton.showIcon(at: index)
            self.themeItem.accessibilityLabel = self.nextTheme.title
        }
    }

    private func makeImportMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: "打开文件",
                image: UIImage(systemName: "folder")
            ) { [weak self] _ in
                self?.importController.presentFilePicker()
            },
            UIAction(
                title: "扫描本地音频",
                image: UIImage(systemName: "doc.text.viewfinder")
            ) { [weak self] _ in
                self?.importController.startScan()
            }
        ])
    }

    /// 搜索转发器 —— **页面必须持有它**（`searchResultsUpdater` 只持 `weak`，没人抱住就静默失灵）。
    private lazy var searchForwarder = SearchTextForwarder(target: viewModel)

    /// 搜索框。
    ///
    /// ⚠️ `obscuresBackgroundDuringPresentation = false`：不设的话，一进搜索状态
    /// 底下的列表会被压暗 —— 我们搜的是**同一张表**（结果就在原地换），不需要那层遮罩。
    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchResultsUpdater = searchForwarder
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchBar.placeholder = "歌曲"
        return controller
    }()

    /// 导航栏最右边那个「更多」。
    ///
    /// ⚠️ 菜单里的打勾看的是**建菜单那一刻**的排序状态，而 `UIBarButtonItem` 的菜单
    /// 建好之后**不会自己刷新**。所以排序一变就得重建这个菜单（见 `bindSortMenuRebuild()`）。
    private lazy var moreItem = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis.circle"),
        menu: makeMoreMenu()
    )

    /// 「更多」菜单。
    ///
    /// 四项：选择 / 搜索 / 排序 / 播放次数显示 —— 顺序和图标照规格。
    ///
    /// ⚠️ 「播放次数」只控**列表画不画**，不控统计；统计始终按真实听满 30 秒记。
    private func makeMoreMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: "选择",
                image: UIImage(systemName: "checkmark.circle")
            ) { [weak self] _ in
                self?.viewModel.toggleSelect()
            },
            UIAction(
                title: "搜索",
                image: UIImage(systemName: "magnifyingglass")
            ) { [weak self] _ in
                self?.revealSearch()
            },
            makeSortMenu(),
            UIAction(
                title: "播放次数",
                image: UIImage(systemName: "headphones"),
                state: viewModel.showPlayCount ? .on : .off
            ) { [weak self] _ in
                self?.viewModel.toggleShowPlayCount()
            }
        ])
    }

    /// 把导航栏右侧恢复成**默认那三个**（更多 / 主题 / 加号）。
    ///
    /// ⚠️ 顺手重建「更多」的菜单 —— 菜单里那几个勾是**建的那一刻**定死的，不重建就还是旧状态。
    /// 选择模式退出时要用（那会儿右侧被「取消」占着）。
    func restoreDefaultRightBarItems() {
        moreItem.menu = makeMoreMenu()
        navigationItem.rightBarButtonItems = [moreItem, themeItem, importItem]
    }

    /// 排序子菜单 —— **两组**（排序字段 / 升降序），两组之间那条分割线由系统画。
    ///
    /// ⚠️ 每组都套一层 `.displayInline` 的 `UIMenu`：**两组之间那条分割线就是它画出来的**
    /// （不用自己插一个分隔项）。组内则是「当前项打勾」。
    ///
    /// ⚠️ 打勾是**建菜单那一刻**的状态，菜单自己不会变 —— 排序一变就得重建（见 `bind()`）。
    private func makeSortMenu() -> UIMenu {
        let modeGroup = UIMenu(
            options: .displayInline,
            children: SongSortMode.allCases.map { mode in
                UIAction(
                    title: mode.menuTitle,
                    state: viewModel.sortMode == mode ? .on : .off
                ) { [weak self] _ in
                    self?.viewModel.setSortMode(mode)
                }
            }
        )

        let orderGroup = UIMenu(
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
            children: [modeGroup, orderGroup]
        )
    }

    /// 菜单里的「搜索」—— 把搜索框亮出来、光标放进去、**键盘弹起来**。
    ///
    /// 三步**缺一不可**：
    ///
    /// 1. 先把「滚动时收起」**临时关掉** —— 搜索框这会儿可能已经被滚上去了，
    ///    关掉它才会留在屏幕上；
    /// 2. 激活搜索状态；
    /// 3. **等下一个 runloop** 再去要键盘，要完把开关装回去。
    ///
    /// ⚠️ 第 3 步必须等一轮：激活还没真正生效就去要键盘会**扑空**，键盘不弹。
    /// 也**不能只写第 2 步** —— 那样只会亮出搜索框，键盘不上来。
    private func revealSearch() {
        navigationItem.hidesSearchBarWhenScrolling = false
        searchController.isActive = true
        DispatchQueue.main.async { [weak self] in
            self?.searchController.searchBar.becomeFirstResponder()
            self?.navigationItem.hidesSearchBarWhenScrolling = true
        }
    }

    // MARK: - 数据

    private func bind() {
        viewModel.snapshot
            .subscribe(onNext: { [weak self] snapshot in
                self?.apply(snapshot)
            })
            .disposed(by: disposeBag)

        // 播放态变了 → 重配可见行的蓝字 / 竖杠，并刷新定位钮「能不能露」。
        viewModel.playbackChrome
            .subscribe(onNext: { [weak self] _ in
                self?.listController.refreshVisiblePlaybackState()
                self?.locatorController.syncPlayingLocatorAvailability()
            })
            .disposed(by: disposeBag)

        bindSortMenuRebuild()
        bindShowPlayCountMenuRebuild()
        bindSearchFeedback()
        bindLibraryErrors()

        // 选择模式：**进 / 出**换导航栏和工具条；**选中变了**只更新工具条上那两个动作键。
        //
        // ⚠️ 两条流**分开订** —— 合成一条的话，每勾一行都会重跑一遍「换导航栏」那一套。
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

    /// 曲库读不出来 —— **弹一次提示，别装没事**。
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
                self?.moreItem.menu = self?.makeMoreMenu()
            })
            .disposed(by: disposeBag)
    }

    /// 播放次数显示开关一变就**重建「更多」菜单** —— 勾是建菜单那一刻定死的。
    private func bindShowPlayCountMenuRebuild() {
        viewModel.showPlayCountChanges
            .skip(1)
            .subscribe(onNext: { [weak self] _ in
                self?.moreItem.menu = self?.makeMoreMenu()
            })
            .disposed(by: disposeBag)
    }

    /// 「未找到相关歌曲」—— **只在从"有结果"变成"没结果"那一刻弹一次**。
    ///
    /// ⚠️ 不能每敲一个字都弹：搜「abcd」会连弹四次，而用户只是还没敲完。
    /// `distinctUntilChanged` 把重复的挡掉、只放行 `true`，拿到的就是"翻上去"那一下。
    private func bindSearchFeedback() {
        viewModel.snapshot
            .map(\.foundNothing)
            .distinctUntilChanged()
            .filter { $0 }
            .subscribe(onNext: { _ in
                HUD.showMessage("未找到相关歌曲")
            })
            .disposed(by: disposeBag)
    }

    /// 列表内容换了 —— 分段落表归列表协作者；选中集合、底部统计、空状态跟在后面。
    private func apply(_ snapshot: SongsViewModel.Snapshot) {
        let visibleIDs = listController.apply(snapshot)

        // 列表内容换了之后收拾一遍选中集合。
        selectionController.pruneSelection(to: visibleIDs)

        // 底部那行统计、空状态 —— 两者看的都是"这次列表里有什么"，跟快照一起更新。
        //
        // ⚠️ 空的时候**把这行清掉**（只留一块空白）：页面正中已经摆着一句
        //「您的音乐库中没有歌曲」了，页脚再报一次「0首歌」是重复。
        // 什么时候该清是**这一页**的决定 —— 组件那边只管填字（见 `ListFooterView`）。
        if snapshot.rows.isEmpty {
            footerView.clear()
        } else {
            footerView.show(count: snapshot.rows.count, totalDurationMs: snapshot.totalDurationMs)
        }
        emptyStateController.updateEmptyState(snapshot)

        // 顶上那条横幅 —— 「该不该出」是快照里算好的结论，页面不比阈值。
        updateMissingBanner(count: snapshot.missingCount, shows: snapshot.showsMissingBanner)
    }

    // MARK: - 「文件不在本机」横幅

    /// 快照说该不该出横幅、上面写几首。
    private func updateMissingBanner(count: Int, shows: Bool) {
        missingBannerState = (count, shows)
        layoutMissingBannerIfNeeded()
    }

    /// 把横幅按当前宽度量一遍、挂到表格顶上；不该显示时就摘掉。
    ///
    /// 🔴 **`tableHeaderView` 的高度表格自己不会算** —— 它只读"挂上去那一刻"的 frame 高度。
    /// 所以顺序是：**自己量** → 改 frame → **再挂一次**（跟 `ListFooterView` 那条坑同源）。
    ///
    /// ⚠️ 宽度还是 0 就直接返回（第一趟快照，页面还没布局）—— 那时候量出来是错的。
    /// 布局完 `viewDidLayoutSubviews` 会再来一次。
    ///
    /// ⚠️ 宽度和条数都没变、而且它本来就挂在那儿 ⇒ 什么都不做：这条会在每次布局时被调到，
    /// 不拦一下就是**每一帧重挂一次表头**（表格会跟着抖）。
    private func layoutMissingBannerIfNeeded() {
        let (count, shows) = missingBannerState
        guard shows else {
            if tableView.tableHeaderView != nil { tableView.tableHeaderView = nil }
            lastBannerWidth = 0
            lastBannerCount = -1
            return
        }

        let width = tableView.bounds.width
        guard width > 0 else { return }
        guard width != lastBannerWidth
            || count != lastBannerCount
            || tableView.tableHeaderView !== missingBanner
        else { return }

        missingBanner.show(count: count)
        missingBanner.frame = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: missingBanner.heightThatFits(width: width)
        )
        // 🔴 **改完 frame 必须再挂一次** —— 表格只在"挂"这一刻读高度。
        tableView.tableHeaderView = missingBanner
        lastBannerWidth = width
        lastBannerCount = count
    }
}

// MARK: - 封面预取

extension SongsViewController: UITableViewDataSourcePrefetching {

    /// 提前把封面读进内存缓存 —— 滚到那一行时，行里就只是查一下缓存，不读盘。
    ///
    /// ⚠️ 这里只做一件事：把"预取哪几张"和两个界面量（尺寸 / 屏幕倍数）**交给 VM** ——
    /// 读盘那一步在 `SongsViewModel.prefetchArtwork`（页面不碰数据层，见本文件顶上那段）。
    ///
    /// ⚠️ **尺寸和屏幕倍数在主线程先取好**再交出去，两条原因：
    /// ① 尺寸必须和行里画的那一格一致（`SongTableCell.artworkSide`）——
    ///    不然预取出来的是另一张图，行里照样要重读一遍；
    /// ② 倍数只有界面上下文里才有 —— 后台线程取到的是默认值，@3x 的机器上会出一张偏小的图。
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        let artworkPaths = listController.artworkPaths(at: indexPaths)

        viewModel.prefetchArtwork(
            artworkPaths,
            pointSize: CGSize(
                width: SongTableCell.artworkSide,
                height: SongTableCell.artworkSide
            ),
            displayScale: traitCollection.displayScale
        )
    }
}

// MARK: - 搜索转发

// 🔴 `UISearchResultsUpdating` 是 @objc 协议 —— 页面不遵循它，把转发交给
// `searchForwarder`（装配见 `searchController`）；转发逻辑全工程一份（`SearchTextForwarder`）。

// MARK: - 「文件不在本机」横幅

/// 曲库页顶上那条**「音乐文件不在本机」**的横幅。
///
/// 只在**整份曲库都像是丢了**（`LibraryReconcile.looksLikeWholeLibraryMissing`）时才出 ——
/// 那个判据在 ViewModel 里算好，这一枚只负责**画**、并把两个键转出去。
///
/// ⚠️ 只有曲库页用它 ⇒ 就躺在这一页的文件里（跟 `FormatTag` 躺在 `SongTableCell` 里同一个理由），
/// 不往 `Components/` 提 —— 那一层是放"多个页面都用"的零件的。
///
/// ⚠️ 它的**高度不固定**（文案会换行）⇒ 量高度那一步由页面调 `heightThatFits(width:)`，
/// 挂法与坑都在 `SongsViewController.layoutMissingBannerIfNeeded()` 上写着。
private final class MissingFilesBanner: UIView {

    /// 这一条自己的尺寸。
    ///
    /// ⚠️ 只有这一个地方用 ⇒ 不进 `AppMetrics`（那儿是按页面积累的间距档，没有这一档）。
    private enum Metrics {

        /// 内容离边缘多远。
        static let insetX = AppMetrics.s15
        static let insetY = AppMetrics.s12

        /// 标题 / 正文 / 键那一行之间那几条缝。
        static let lineGap = AppMetrics.s10

        /// 两个键之间那条缝。
        static let buttonGap = AppMetrics.s8

        /// 键的高度 —— **系统给的最小点击区**。
        ///
        /// ⚠️ 不能让它按字高去算（那样只有 20 上下，点不准）。
        static let buttonHeight: CGFloat = 44
    }

    /// 两个键的去处 —— 页面装配时接上（见 `SongsViewController.layout()`）。
    var onReimport: (() -> Void)?
    var onRemoveMissing: (() -> Void)?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let reimportButton = UIButton(type: .system)
    private let removeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 对外

    /// 写上"有几首找不到"，右边那个键的字也跟着它。
    func show(count: Int) {
        messageLabel.text = "曲库里有 \(count) 首歌曲找不到文件。"
        removeButton.setTitle("移除这 \(count) 首", for: .normal)
    }

    /// 给定宽度下这一条要多高。
    ///
    /// 🔴 **`tableHeaderView` 的高度表格自己不会算**（它只读挂上去那一刻的 frame 高度）——
    /// 只能自己量：套一个宽度、让它按内容压出高度。
    func heightThatFits(width: CGFloat) -> CGFloat {
        systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    // MARK: - 装配

    private func buildSubviews() {
        // 🔴 **用实色、不用 `overlay*` 那一族**：这一条的底会跟着系统外观翻
        //（它压在列表页背景上），实色才跟着翻（见 `AppColor` 顶上那条规矩）。
        backgroundColor = AppColor.surface

        titleLabel.text = "音乐文件不在本机"
        titleLabel.font = AppFont.songTitle
        titleLabel.textColor = AppColor.title
        titleLabel.numberOfLines = 0

        messageLabel.font = AppFont.songSubtitle
        messageLabel.textColor = AppColor.subtitle
        messageLabel.numberOfLines = 0

        reimportButton.setTitle("重新导入", for: .normal)
        reimportButton.titleLabel?.font = AppFont.songSubtitle
        reimportButton.tintColor = AppColor.accent
        reimportButton.addTarget(self, action: #selector(reimportTapped), for: .touchUpInside)

        removeButton.titleLabel?.font = AppFont.songSubtitle
        removeButton.tintColor = AppColor.destructive
        removeButton.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)

        // 两个键各自撑到最小点击区高度（见 `Metrics.buttonHeight`）。
        for button in [reimportButton, removeButton] {
            button.snp.makeConstraints { $0.height.equalTo(Metrics.buttonHeight) }
        }

        let buttonRow = UIStackView(arrangedSubviews: [reimportButton, removeButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = Metrics.buttonGap
        // ⚠️ 键那一行**不能拉满**：横排里多出来的宽度会被塞进某一个键里，两个键就离得很远。
        // 摆一个"吸收剩余宽度"的空视图，把两个键按在左边。
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(spacer)

        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, buttonRow])
        stack.axis = .vertical
        stack.spacing = Metrics.lineGap
        // 🔴 **`.fill`、不是 `.leading`**：`.leading` 下每一行只占自己内容那么宽，
        // 长句子**不换行、直接溢出**（同 `SongTableCell` 副标题那一行那条坑）。
        // 拉满宽度，让两条文字自己换行。
        stack.alignment = .fill

        addSubview(stack)
        stack.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(
                UIEdgeInsets(
                    top: Metrics.insetY,
                    left: Metrics.insetX,
                    bottom: Metrics.insetY,
                    right: Metrics.insetX
                )
            )
        }
    }

    @objc private func reimportTapped() { onReimport?() }

    @objc private func removeTapped() { onRemoveMissing?() }
}

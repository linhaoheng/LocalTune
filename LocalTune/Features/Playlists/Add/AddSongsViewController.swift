import RxSwift
import SnapKit
import UIKit

/// 「添加歌曲到歌单」页 —— 从歌单详情页右上那个「加号」进来，从**整个曲库**里挑歌加进去。
///
/// 这里只做三件事：订阅快照 → 渲染 → 把用户动作转给 VM。
/// 不查库、不排序、不拼字符串、不做跳转决定（关掉自己是 `dismiss`，不是页面之间的跳转）。
///
/// ⚠️ **列表和动作分给两个页面私有协作者**（这个文件只留"这一页本身"：装配、订阅、布局骨架、导航栏）：
/// - `AddSongsListController` —— 列表的**结构**（数据源、点一行、快照落表）；
/// - `AddSongsActionsController` —— 用户动作（左上「取消」、右上「完成」、下拉关闭的拦截，
///   这个文件里只留转发壳 —— 转发是页面的三职责之一）。
///
/// ## 这一页的样子（`PlaylistAddSongController`）
///
/// 标题「添加到播放列表」＋ 常显的搜索框；左上「取消」、右上「完成」（都走系统的项）；
/// 列表 = **整个曲库**（含已经在这个歌单里的那些），行尾那一格画勾选标记；
/// **点整行**才是勾 / 取消勾，点了不播歌、也不写库。
///
/// ## 🔴 跟参考实现（`AddSongsToPlaylistViewController`）不一样的两处，都是它有毛病
///
/// 1. **它手一点就把歌写进库了** ⇒ 点「取消」退不回来（用户的本意是"算了别加"）。
///    我们攒着、点「完成」才写一次（见 `AddSongsViewModel`）。
/// 2. **它自己抄了一个行**（`AddSongRowCell`，还带一个永远隐藏的 `checkView`）——
///    我们**复用曲库页那一行**（`SongTableCell` 的勾选模式），换的就是
///    `SongNormalCell` 那颗按钮的图）。各写一份的话，"一首歌长什么样"迟早走散。
///
/// ⚠️ **这一页没有页脚统计**：挑歌的时候也不需要知道总时长。
final class AddSongsViewController: BaseViewController {

    // MARK: - 依赖

    /// 页面状态 —— 只在这个文件里订阅（`bind()`）与转发搜索词。
    private let viewModel: AddSongsViewModel

    /// 取图的动作 —— 装配层（`App/AppArtwork.image`）给，init 时递给列表协作者。
    private let artworkProvider: ArtworkProvider

    // MARK: - 零件

    private let tableView = BaseTableView(frame: .zero, style: .plain)

    // MARK: - 协作者

    /// 列表协作者 —— 持有列表状态，快照落表、配行、点一行都归它（见 `AddSongsListController`）。
    private lazy var listController = AddSongsListController(
        viewModel: viewModel,
        tableView: tableView,
        artworkProvider: artworkProvider
    )

    /// 动作协作者 —— 左上「取消」、右上「完成」、下拉关闭的拦截（见 `AddSongsActionsController`）。
    private lazy var actionsController = AddSongsActionsController(viewModel: viewModel, page: self)

    /// 下拉关闭的决策者 —— 路由呈现这一页时**显式**挂给 `presentationController`。
    /// 决策实现全在 `AddSongsActionsController`，这里只递引用（页面不转发调用）。
    var presentationDelegate: UIAdaptivePresentationControllerDelegate { actionsController }

    // MARK: - 导航栏

    /// 左上「取消」—— 走系统的 `.cancel` 档（标题由系统按语言给，不用自己写字符串）。
    ///
    /// ⚠️ 它**不需要做什么"撤销"**：这一页从头到尾没写过库（见 `AddSongsViewModel`），
    /// 关掉就是取消。**往下拖走也是同一个结果**（见 `AppRouter.presentAddSongs`）。
    private lazy var cancelItem = UIBarButtonItem(
        barButtonSystemItem: .cancel,
        target: actionsController,
        action: #selector(AddSongsActionsController.cancelTapped)
    )

    /// 右上「完成」—— **在它这儿才写库**，写成了才关页。
    ///
    /// ⚠️ 用系统的 `.done` 档 —— 跟「取消」是同一对系统项。
    private lazy var doneItem = UIBarButtonItem(
        barButtonSystemItem: .done,
        target: actionsController,
        action: #selector(AddSongsActionsController.doneTapped)
    )

    /// 搜索框 —— 挂**导航栏**上，它不是页面里的一块。
    ///
    /// ⚠️ `obscuresBackgroundDuringPresentation = false`：不设的话，一进搜索状态
    /// 底下的列表会被压暗 —— 我们搜的是**同一张表**（结果就在原地换），不需要那层遮罩。
    ///
    /// 🔴 **参考实现还多一句 `searchBar.setValue("取消", forKey: "cancelButtonText")`，不抄**：
    /// 那是拿 KVC 去戳 `UISearchBar` 的**私有属性**（系统从没公开过这个口子），
    /// 系统版本一变就可能崩，审核也容易出事。取消键的字走系统默认 —— 中文环境下本来就叫「取消」。
    /// 搜索转发器 —— **页面必须持有它**（`searchResultsUpdater` 只持 `weak`，没人抱住就静默失灵）。
    private lazy var searchForwarder = SearchTextForwarder(target: viewModel)

    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchResultsUpdater = searchForwarder
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchBar.placeholder = "歌曲"
        return controller
    }()

    // MARK: - 建立

    init(
        playlistID: Playlist.ID,
        library: LibraryStore,
        settings: AppSettings,
        artworkProvider: @escaping ArtworkProvider
    ) {
        self.artworkProvider = artworkProvider
        viewModel = AddSongsViewModel(
            playlistID: playlistID,
            library: library,
            settings: settings
        )
        super.init(nibName: nil, bundle: nil)
        title = "添加到播放列表"
        // 大标题常显 —— 这是**弹出来的**一页，没有"从上一页推进来"那种收缩过程。
        // ⚠️ 只设 `largeTitleDisplayMode`，**不碰 `prefersLargeTitles`**：那是整条导航栈
        // 共用的总闸，由基类在 `viewWillAppear` 里写（见 `BaseViewController`）。
        largeTitleDisplayMode = .always
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        layout()
        bind()
    }

    // MARK: - 布局

    private func layout() {
        // 表格的数据源 / 代理由列表协作者在 init 里认领（见 `AddSongsListController`）。
        // 挑歌页用系统分组表面；不能沿用曲库页的 pageBackground，也不能用纯黑的 systemBackground。
        view.backgroundColor = .systemGroupedBackground
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorColor = AppColor.separator
        // 行高交给系统按内容算（下限在行自己身上）—— 固定行高会把放大后的字裁掉。
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = SongTableCell.minimumHeight
        tableView.register(SongTableCell.self, forCellReuseIdentifier: SongTableCell.reuseIdentifier)

        view.addSubview(tableView)
        tableView.snp.makeConstraints { $0.edges.equalToSuperview() }

        layoutNavigationItems()
    }

    /// 导航栏上那几样：左右两颗键 + 搜索框。
    private func layoutNavigationItems() {
        navigationItem.leftBarButtonItem = cancelItem
        navigationItem.rightBarButtonItem = doneItem

        // 搜索框挂**导航栏**上，而且**常显**（`hidesSearchBarWhenScrolling = false`）——
        // 用户进这一页就是为了找歌，滚下去时把搜索框收掉没有好处。
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        // 🔴 **弹出来的页面得设它**：搜索激活时 UIKit 要找一个"呈现上下文"，
        // 不设的话那层搜索状态会盖在**下面那一页**（歌单详情页）上。
        // ⚠️ 只在「歌单详情」和这一页设它 —— 这两页都是自己带搜索的。
        definesPresentationContext = true
    }

    // MARK: - 数据

    private func bind() {
        viewModel.snapshot
            .subscribe(onNext: { [weak self] snapshot in
                self?.listController.apply(snapshot)
            })
            .disposed(by: disposeBag)

        // 「未找到相关歌曲」—— **只在从"有结果"变成"没结果"那一刻弹一次**。
        //
        // ⚠️ 不能每敲一个字都弹：搜「abcd」会连弹四次，而用户只是还没敲完。
        // `distinctUntilChanged` 把重复的挡掉、只放行 `true`，拿到的就是"翻上去"那一下
        //（跟曲库页同一条）。
        viewModel.snapshot
            .map(\.foundNothing)
            .distinctUntilChanged()
            .filter { $0 }
            .subscribe(onNext: { _ in
                HUD.showMessage("未找到相关歌曲")
            })
            .disposed(by: disposeBag)

        // 库读不出来 —— **弹一次提示，别装没事**（文案与取舍在 `LibraryErrorNotice` 一处）。
        LibraryErrorNotice.bind(viewModel.errors, disposedBy: disposeBag)
    }

}

// MARK: - 搜索转发

// 🔴 `UISearchResultsUpdating` 是 @objc 协议 —— 页面不遵循它，把转发交给
// `searchForwarder`（装配见 `searchController`）；转发逻辑全工程一份（`SearchTextForwarder`）。

import RxSwift
import SnapKit
import UIKit

/// 「获取歌词」页 —— 从编辑歌词页右上那颗键**推进来**，用用户导入的源挑一条歌词。
///
/// ## 形态
///
/// **push 进编辑页所在那条导航栈**（不再弹一层）：编辑页本身就是模态整页，取材是它内部的一步，
/// 挑完就回到它 —— 自己再弹一层，只会多出一条"退回去算取消还是算改"的糊账。
/// 顶上挂常显的搜索框，下面一整张候选表。
///
/// ## 页面上只有三块
///
/// 1. **搜索框**（导航栏里，常显）；
/// 2. **候选表**（主行歌名 / 副行「艺人 · 专辑 · 时长」）；
/// 3. **正中那块状态**（转圈 ＋ 一句话）—— 只在"正在搜 / 没找到 / 连不上"时露。
///
/// ## 🔴 它不认识的东西
///
/// - **不认识编辑页的草稿**：取回来的正文由 `viewModel` 从 `onFetched` 交出去，
///   灌工作层、保存都不在这儿；**也不自己退**（怎么退由装配层那条口子决定）。
/// - **不拼错误文案**：两句话在 `LyricsFetchError.message` 里，页面只负责摆。
/// - **不查库、不排序**（排序在 `LyricsCandidateRankingPolicy`）。
///
/// ⚠️ **两行字也不在这儿拼**：主行取 `LyricsSourceCandidate.title`、副行取它自己的
/// `subtitle`（`艺人 · 专辑 · 时长`）—— 页面只负责摆。
final class LyricsFetchViewController: BaseViewController {

    // MARK: - 依赖

    /// 状态与动作 —— 页面只订阅它、把用户动作交给它。
    private let viewModel: LyricsFetchViewModel

    // MARK: - 零件

    private let tableView = UITableView(frame: .zero, style: .plain)

    /// 正中那块：转圈 ＋ 一句话。
    private let stateStack = UIStackView()
    private let stateSpinner = UIActivityIndicatorView(style: .medium)
    private let stateLabel = UILabel()

    /// 搜索框 —— 挂导航栏上，常显。
    ///
    /// 🔴 **不设 `searchResultsUpdater`**：我们搜的是**网络**，不是当场过滤这张表 ——
    /// 每敲一个字就发一次请求是不行的。真正触发搜索的是"按下键盘上那颗搜索键"
    /// （`searchBarSearchButtonClicked`，delegate 就是这一页）。
    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchBar.delegate = self
        // 结果就在原地换（同一张表），不需要压暗底下的东西。
        controller.obscuresBackgroundDuringPresentation = false
        // 歌词里常有连字符、真引号，别让输入法自作聪明。
        controller.searchBar.autocapitalizationType = .none
        controller.searchBar.autocorrectionType = .no
        controller.searchBar.placeholder = "歌名"
        return controller
    }()

    /// 上一次推给界面的那一份 —— 判"这回哪一块真变了"用（不整表乱刷）。
    private var applied: LyricsFetchViewModel.Snapshot?

    /// 用户的源（文件存储）。
    private let sourceStore = LyricsSourceFileStore()

    /// 跳转只走它 —— 「歌词源」页由它推。
    private let router: AppRouter

    /// 「上次用的是哪个源」的**唯一真相**（`lyrics.sourceID`）。
    ///
    /// 🔴 **别再在页面里存一份内存变量**：以前 `selectedSourceID` 只活在这个页面实例里，
    /// 页面一重建就没了 ⇒ 选第二个源只生效一次，下次又回落到第一条。
    private let settings: AppSettings

    /// 现在真正在用的那一份 —— 用来判「回到前台后源有没有变」（变了才重搜）。
    private var currentConfig: LyricsSourceConfig?

    private static let rowReuseID = "lyricsCandidate"

    // MARK: - 建立

    init(viewModel: LyricsFetchViewModel, router: AppRouter, settings: AppSettings) {
        self.viewModel = viewModel
        self.router = router
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = "获取歌词"
        // 推进来的页面，跟编辑页保持同一套栏：**不要大标题**。
        // ⚠️ `prefersLargeTitles` 是**整条栈**共用的总闸，得显式关 —— 不关的话推上来会给
        // 这条模态栈套上大标题，退回编辑页又要塌一次。
        prefersLargeTitles = false
        largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpSearch()
        setUpTable()
        setUpState()
        setUpSourceButton()
        bindViewModel()
        refreshSourceIfNeeded()
    }

    // MARK: - 搜索框

    private func setUpSearch() {
        navigationItem.searchController = searchController
        // 常显：进这一页就是为了找词，滚下去时把搜索框收掉没有好处。
        navigationItem.hidesSearchBarWhenScrolling = false
        // 和同类页面（`AddSongsViewController`）保持一致：自己带搜索的页面，
        // 明确认领搜索状态的呈现上下文。
        definesPresentationContext = true
    }

    // MARK: - 表格

    private func setUpTable() {
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.rowReuseID)
        tableView.dataSource = self
        tableView.delegate = self
        // 行高交给系统按内容算（副行可能折成两行）；估算值只给滚动条用。
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = AppMetrics.lyricsFetchEstimatedRowHeight
        tableView.backgroundColor = AppColor.pageBackground
        tableView.separatorColor = AppColor.separator
        // 一拖列表就把键盘收掉：候选多的时候，键盘正好挡着大半屏。
        tableView.keyboardDismissMode = .onDrag

        view.addSubview(tableView)
        tableView.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    // MARK: - 正中那块状态

    private func setUpState() {
        stateStack.axis = .vertical
        stateStack.alignment = .fill
        stateStack.spacing = AppMetrics.lyricsFetchStateSpacing
        stateSpinner.color = AppColor.subtitle
        // 一整页就这一句话 —— 它自己是主角，不跟"说明文字"那一档。
        stateLabel.font = AppFont.emptyStateMessage
        stateLabel.textColor = AppColor.subtitle
        stateLabel.textAlignment = .center
        stateLabel.numberOfLines = 0
        stateStack.addArrangedSubview(stateSpinner)
        stateStack.addArrangedSubview(stateLabel)

        view.addSubview(stateStack)
        stateStack.snp.makeConstraints { make in
            make.centerY.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalToSuperview().inset(AppMetrics.lyricsFetchStateSideInset)
        }
    }

    // MARK: - 订阅

    private func bindViewModel() {
        viewModel.snapshot
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] snapshot in self?.apply(snapshot) })
            .disposed(by: disposeBag)

        // 下载那一步的收尾（下不动 / 没得下）**只报一句就走** —— 列表原样留着，
        // 用户可以直接换一条再试。（那颗圈由上面那条状态流自己收掉。）
        viewModel.notice
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { notice in
                HUD.showMessage(notice.text, style: notice.style)
            })
            .disposed(by: disposeBag)
    }

    // MARK: - 画

    /// 把新的一份摆上去。
    ///
    /// 🔴 **按"哪一块真变了"分别刷**：只有候选变了才整表重来；只多一颗"正在下"的圈，
    /// 不该把整张表重建（搜索框里正打着的字都会跟着抖）。
    private func apply(_ snapshot: LyricsFetchViewModel.Snapshot) {
        applyKeyword(snapshot.keyword)
        if applied?.phase != snapshot.phase {
            applyState(snapshot.phase)
            tableView.reloadData()
        }
        if applied?.downloadingIndex != snapshot.downloadingIndex {
            applyDownloadingIndicator(snapshot.downloadingIndex)
        }
        applied = snapshot
    }

    /// 把「现在搜的是哪个词」回填到搜索框。
    ///
    /// 🔴 **用户正在搜索框里打字时不动它**（`isActive`）：回落搜出来的那个词，
    /// 只在他没打字时回填 —— 否则会当场把他敲到一半的字换掉。
    private func applyKeyword(_ keyword: String) {
        guard searchController.searchBar.text != keyword, !searchController.isActive else { return }
        searchController.searchBar.text = keyword
    }

    /// 正中那块：正在搜 ⇒ 转圈 ＋ 一句话；没搜到 / 连不上 ⇒ 只有那句话；有结果 ⇒ 收起来。
    private func applyState(_ phase: LyricsFetchViewModel.Phase) {
        switch phase {
        case .searching:
            stateSpinner.isHidden = false
            stateSpinner.startAnimating()
            stateLabel.text = "正在搜索…"
        case .results:
            stateSpinner.stopAnimating()
            stateSpinner.isHidden = true
            stateLabel.text = nil
        case .noSource:
            stateSpinner.stopAnimating()
            stateSpinner.isHidden = true
            stateLabel.text = "还没有歌词源，点右上「歌词源」导入"
        case let .failed(error):
            stateSpinner.stopAnimating()
            stateSpinner.isHidden = true
            // 🔴 这句由 `LyricsFetchError` 给 ——「没找到」与「连不上」是**两句不同的话**，
            // 页面不自己拼、更不许把两种合成一句。
            stateLabel.text = error.message
        }
        stateStack.isHidden = stateLabel.text == nil
    }

    /// 把"正在下这一条"那颗圈摆上（并摘掉上一次那颗）。
    ///
    /// ⚠️ 每次先**把可见格全清一遍**再摆：不用记"上一次是哪一行"，反复调结果也还是同一个
    /// （一行最多挂一颗圈）。
    private func applyDownloadingIndicator(_ index: Int?) {
        for cell in tableView.visibleCells { cell.accessoryView = nil }
        guard let index,
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0))
        else { return }
        cell.accessoryView = makeDownloadingSpinner()
    }

    /// 那一颗转圈。
    ///
    /// ⚠️ **每次现建一个**（不共用同一个 view）：共用的话，"这一格换到别的行去了"就得跟
    /// 谁先把它摘下来对账 —— 现建一个就不用记这件事。
    private func makeDownloadingSpinner() -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        return spinner
    }

    // MARK: - 歌词源

    private func setUpSourceButton() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "歌词源",
            style: .plain,
            target: self,
            action: #selector(sourceTapped)
        )
    }

    @objc private func sourceTapped() {
        let stored = settings.lyricsSourceID
        router.presentLyricsSources(
            from: self,
            selectedID: stored.isEmpty ? nil : stored,
            onSelect: { [weak self] config in
                // 点中一行就换源 —— 不用等页面关掉。
                self?.apply(config)
            },
            onFinish: { [weak self] in
                // 关掉再刷一次：用户可能在里面删了正在用的那个。
                self?.refreshSourceIfNeeded()
            }
        )
    }

    /// 从存储里读一份「该用哪个源」，**变了才换**（不无谓地重搜）。
    ///
    /// 选中的 id 不在列表里（删了 / 还没选过）⇒ 回落到第一条，再由 `apply` 把它写回偏好
    /// —— 所以"打勾的"和"实际在用的"始终是同一个。
    private func refreshSourceIfNeeded() {
        let configs = sourceStore.loadAll()
        let config = configs.first { $0.id == settings.lyricsSourceID } ?? configs.first
        guard config != currentConfig else { return }
        apply(config)
    }

    /// 🔴 **写盘就在这儿**：`apply` 是"现在用哪个源"的唯一落点，选择记忆跟着它走。
    ///
    /// 不另开一条"用户点了列表 ⇒ 记一下"的路 —— 两条路迟早分叉，然后打勾的和实际用的不是一个。
    private func apply(_ config: LyricsSourceConfig?) {
        currentConfig = config
        settings.lyricsSourceID = config?.id ?? ""
        viewModel.setSource(config.map { LyricsSourceClient(config: $0) })
    }
}

// MARK: - UITableViewDataSource / Delegate

extension LyricsFetchViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.now.results.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.rowReuseID, for: indexPath)
        let rows = viewModel.now.results
        guard rows.indices.contains(indexPath.row) else { return cell }

        cell.contentConfiguration = content(for: rows[indexPath.row])
        // 正下着的那一行挂个圈 —— 这一行滚出去再滚回来也得还在。
        cell.accessoryView = indexPath.row == viewModel.now.downloadingIndex
            ? makeDownloadingSpinner()
            : nil
        return cell
    }

    /// 一行怎么摆：只有主行（歌名）＋ 副行（艺人 · 专辑 · 时长）两串字。
    ///
    /// 副行是「艺人 · 专辑 · 时长」—— 同名不同版本（live / 翻唱）靠它让用户自己认。
    private func content(for candidate: LyricsSourceCandidate) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = candidate.title
        content.textProperties.font = AppFont.songTitle
        content.textProperties.color = AppColor.title
        content.secondaryText = candidate.subtitle
        content.secondaryTextProperties.font = AppFont.songSubtitle
        content.secondaryTextProperties.color = AppColor.subtitle
        content.secondaryTextProperties.numberOfLines = 2
        return content
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // 正下着的时候不再接第二次点击（一次只下一份）。
        guard !viewModel.now.isDownloading else { return }
        viewModel.pick(at: indexPath.row)
    }
}

// MARK: - UISearchBarDelegate

extension LyricsFetchViewController: UISearchBarDelegate {

    /// 键盘上那颗**搜索键** —— 网络搜索只在这一下发生（敲字不发请求）。
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        viewModel.search(searchBar.text ?? "")
    }
}

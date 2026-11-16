import RxSwift
import SnapKit
import UIKit

/// 「获取封面」页 —— 从编辑页右上那颗键**推进来**，挑一张封面。
///
/// ## 形态（`获取封面设计.md` §五）
///
/// **push 进编辑页所在那条导航栈**（不再弹一层）：编辑页本身就是模态整页，
/// 取材是它内部的一步，挑完就回到它 —— 自己再弹一层，只会多出一条
/// "退回去算取消还是算改"的糊账。
///
/// ## 页面上只有三块
///
/// 1. **搜索框**（导航栏里，常显）；
/// 2. **候选表**（缩略图 ＋ 主行歌名 ＋ 副行「艺人 · 专辑 · 年份」＋ 右边**源角标**）；
/// 3. **正中那块状态**（转圈 ＋ 一句话）—— 只在"正在搜 / 没搜到 / 连不上"时露。
///
/// ## 🔴 它不认识的东西
///
/// - **不认识编辑页的草稿**：挑中的图由 `viewModel` 从 `onPicked` 交出去，
///   进草稿、落盘都不在这儿；**也不自己退**（怎么退由装配层那条口子决定）。
/// - **不拼错误文案**：两句话在 `CoverSearchError.message` 里，页面只负责摆。
/// - **不认识网络**：图从 `viewModel` 要，请求在 `Data` 层发。
///
/// ⚠️ **两行字也不在这儿拼**：主行取 `CoverCandidate.title`、副行取它自己的
/// `subtitle`（`艺人 · 专辑 · 年份`）—— 页面只负责摆（宪法 §一 Features 行「不拼字符串」）。
final class CoverFetchViewController: BaseViewController {

    // MARK: - 依赖

    /// 状态与动作 —— 页面只订阅它、把用户动作交给它。
    private let viewModel: CoverFetchViewModel

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
        // 歌名里有连字符、真引号，别让输入法自作聪明。
        controller.searchBar.autocapitalizationType = .none
        controller.searchBar.autocorrectionType = .no
        controller.searchBar.placeholder = "歌名 艺人"
        return controller
    }()

    /// 上一次推给界面的那一份 —— 判"这回哪一块真变了"用（不整表乱刷）。
    private var applied: CoverFetchViewModel.Snapshot?

    // MARK: - 建立

    init(viewModel: CoverFetchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "获取封面"
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
        bindViewModel()
        // 进页面就自动搜一次（§五）—— 用户多半一个字都不用改。
        viewModel.autoSearch()
    }

    // MARK: - 搜索框

    private func setUpSearch() {
        navigationItem.searchController = searchController
        // 常显：进这一页就是为了找图，滚下去时把搜索框收掉没有好处。
        navigationItem.hidesSearchBarWhenScrolling = false
        // 和同类页面保持一致：自己带搜索的页面，明确认领搜索状态的呈现上下文。
        definesPresentationContext = true
    }

    // MARK: - 表格

    private func setUpTable() {
        tableView.register(CoverCandidateCell.self, forCellReuseIdentifier: CoverCandidateCell.reuseID)
        tableView.dataSource = self
        tableView.delegate = self
        // 行高交给系统按内容算（副行可能折成两行）；估算值只给滚动条用。
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = AppMetrics.coverFetchEstimatedRowHeight
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
        stateStack.spacing = AppMetrics.coverFetchStateSpacing
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
            make.leading.trailing.equalToSuperview().inset(AppMetrics.coverFetchStateSideInset)
        }
    }

    // MARK: - 订阅

    private func bindViewModel() {
        viewModel.snapshot
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] snapshot in self?.apply(snapshot) })
            .disposed(by: disposeBag)

        // 取大图那一步的收尾（下不动）**只报一句就走** —— 列表原样留着，
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
    /// 🔴 **按"哪一块真变了"分别刷**：只有候选变了才整表重来；只多一颗"正在取"的圈，
    /// 不该把整张表重建（搜索框里正打着的字都会跟着抖）。
    private func apply(_ snapshot: CoverFetchViewModel.Snapshot) {
        applyKeyword(snapshot.keyword)
        if applied?.phase != snapshot.phase {
            applyState(snapshot.phase)
            tableView.reloadData()
        }
        if applied?.pickingIndex != snapshot.pickingIndex {
            applyPickingIndicator(snapshot.pickingIndex)
        }
        if applied?.unavailableSources != snapshot.unavailableSources {
            applyUnavailableSources(snapshot.unavailableSources)
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
    private func applyState(_ phase: CoverFetchViewModel.Phase) {
        switch phase {
        case .searching:
            stateSpinner.isHidden = false
            stateSpinner.startAnimating()
            stateLabel.text = "正在搜索…"
        case .results:
            stateSpinner.stopAnimating()
            stateSpinner.isHidden = true
            stateLabel.text = nil
        case let .failed(error):
            stateSpinner.stopAnimating()
            stateSpinner.isHidden = true
            // 🔴 这句由 `CoverSearchError` 给 ——「没搜到」与「连不上」是**两句不同的话**，
            // 页面不自己拼、更不许把两种合成一句（§六）。
            stateLabel.text = error.message
        }
        stateStack.isHidden = stateLabel.text == nil
    }

    /// 把"正在取这一条"那颗圈摆上（并给别的行把源标摆回去）。
    ///
    /// 🔴 **不是"圈顶掉源标"**：行尾是「圈 ＋ 源标」并排，取图时圈淡入、源标变暗，
    /// 两件都在、宽度不变。见 `CoverCandidateCell.showPicking(_:)`。
    private func applyPickingIndicator(_ index: Int?) {
        for cell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell),
                  let row = cell as? CoverCandidateCell,
                  viewModel.now.results.indices.contains(indexPath.row)
            else { continue }
            row.showPicking(indexPath.row == index)
        }
    }

    /// 列表末尾那句「某某没连上」。
    ///
    /// 🔴 一个源挂了、另一个搜到了 ⇒ **照常摆结果**，只在末尾标一句（§六）——
    /// 不因为一个源出问题就把整页说成"没搜到"。
    private func applyUnavailableSources(_ kinds: [CoverSourceKind]) {
        guard !kinds.isEmpty else {
            tableView.tableFooterView = nil
            return
        }
        let label = UILabel()
        label.text = "\(kinds.map(\.displayName).joined(separator: "、")) 没连上"
        label.font = AppFont.songSubtitle
        label.textColor = AppColor.subtitle
        label.textAlignment = .center
        label.frame = CGRect(
            x: 0, y: 0,
            width: tableView.bounds.width,
            height: AppMetrics.coverFetchUnavailableFooterHeight
        )
        tableView.tableFooterView = label
    }
}

// MARK: - 候选行

/// 候选行：缩略图 ＋ 歌名 / 副行 ＋ 行尾那块。
///
/// 🔴 **整行自己搭，不走 `accessoryView`、也不用 `UIListContentConfiguration`。**
/// 那两条路都试过，徽章在这个位置就是不显示 —— `accessoryView` 对自定义视图的尺寸
/// 求解不可靠，而 `contentConfiguration` 管不到行尾那枚。
/// 现在四件都是 `contentView` 的普通子视图，位置全靠约束 —— 没有系统魔法，就一定会显示。
///
/// 🔴 **行尾那块（圈 ＋ 源标）在 cell 里建一次、反复用**：它是**有状态**的
/// （正在转 / 没转），每次重建等于把状态丢掉，淡入也无从谈起。
private final class CoverCandidateCell: UITableViewCell {

    static let reuseID = "coverCandidate"

    /// 文字左边到行左缘的距离：**左边距 ＋ 缩略图边长 ＋ 文字间距**。
    ///
    /// 🔴 这个和**只算这一处** —— 分隔线读它就行，不必再把三个令牌相加抄一遍。
    private static let textLeading = AppMetrics.coverFetchRowSideInset
        + AppMetrics.coverFetchThumbnailSide
        + AppMetrics.coverFetchRowTextSpacing

    private let thumbnailView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let badge = CoverSourceBadgeLabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    /// 歌名 ＋ 副行（两行整体在行里居中）。
    private let textStack = UIStackView()

    /// 行尾那一整块（圈 ＋ 源标）。
    private let accessoryRow = UIStackView()

    /// 「这一行正在取大图吗」—— **只此一处**。
    private var isPicking = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        // 分隔线从文字左边起 —— 跟歌名对齐，不切到缩略图底下。
        separatorInset = UIEdgeInsets(top: 0, left: Self.textLeading, bottom: 0, right: 0)
        setUpSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 摆

    /// 整行摆一遍。
    func show(_ candidate: CoverCandidate, thumbnail: UIImage?, isPicking: Bool) {
        titleLabel.text = candidate.title
        subtitleLabel.text = candidate.subtitle
        showThumbnail(thumbnail)
        let colors = candidate.source.badgeColors
        badge.configure(candidate.source.displayName, textColor: colors.text, fillColor: colors.fill)
        showPicking(isPicking)
    }

    /// 缩略图（`nil` ＝ 还没下到，摆占位底）。
    ///
    /// ⚠️ 占位底是 SF Symbol，得上色；真图不是 template 渲染，tint 对它无效 ——
    /// 所以真图那一路要显式把 tint 清掉，否则会残留上一次的灰色。
    func showThumbnail(_ image: UIImage?) {
        thumbnailView.image = image ?? UIImage(systemName: "music.note")
        thumbnailView.tintColor = image == nil ? AppColor.subtitle : nil
    }

    /// 这一行是不是正在取大图。
    ///
    /// 🔴 **宽度一点不动**：圈一直占着那 20 点，只是透明度变了 ——
    /// 行尾不跟着跳，是这条的整个目的。
    func showPicking(_ isPicking: Bool) {
        guard isPicking != self.isPicking else { return }
        self.isPicking = isPicking

        if isPicking {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        // 两个选项都不是装饰：`beginFromCurrentState` 防连点时从上一次没走完的位置跳回去，
        // `allowUserInteraction` 让这 0.15 秒里整行还点得动。
        // ⚠️ `delay` 不能省 —— UIKit 没有「只有时长 ＋ 选项」这个重载，带 options 就必须写 delay。
        UIView.animate(
            withDuration: 0.15,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.spinner.alpha = isPicking ? 1 : 0
            self.badge.alpha = isPicking ? 0.35 : 1
        }
    }

    // MARK: - 搭

    private func setUpSubviews() {
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = AppMetrics.coverFetchThumbnailCornerRadius
        thumbnailView.backgroundColor = AppColor.artworkPlaceholder

        titleLabel.font = AppFont.songTitle
        titleLabel.textColor = AppColor.title
        titleLabel.numberOfLines = 1

        subtitleLabel.font = AppFont.songSubtitle
        subtitleLabel.textColor = AppColor.subtitle
        subtitleLabel.numberOfLines = 2

        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = AppMetrics.coverFetchRowLineSpacing
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        // 圈平时不转、也看不见 —— 但**占着位置**，所以宽度不会因为"在不在取图"而变。
        spinner.hidesWhenStopped = false
        spinner.alpha = 0

        accessoryRow.axis = .horizontal
        accessoryRow.alignment = .center
        accessoryRow.spacing = AppMetrics.coverFetchAccessorySpacing
        accessoryRow.addArrangedSubview(spinner)
        accessoryRow.addArrangedSubview(badge)

        contentView.addSubview(thumbnailView)
        contentView.addSubview(textStack)
        contentView.addSubview(accessoryRow)

        thumbnailView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(AppMetrics.coverFetchRowSideInset)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(AppMetrics.coverFetchThumbnailSide)
            // 缩略图是这一行最矮的成员 ⇒ 它上下各留 16，就是行高的下限。
            make.top.greaterThanOrEqualToSuperview().offset(AppMetrics.coverFetchRowVerticalInset)
            make.bottom.lessThanOrEqualToSuperview().offset(-AppMetrics.coverFetchRowVerticalInset)
        }

        accessoryRow.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-AppMetrics.coverFetchRowSideInset)
            make.centerY.equalToSuperview()
            make.leading.greaterThanOrEqualTo(thumbnailView.snp.trailing)
        }

        textStack.snp.makeConstraints { make in
            make.leading.equalTo(thumbnailView.snp.trailing)
                .offset(AppMetrics.coverFetchRowTextSpacing)
            make.trailing.equalTo(accessoryRow.snp.leading)
                .offset(-AppMetrics.coverFetchRowTextSpacing)
            make.centerY.equalToSuperview()
            // 副行折两行时把它撑高，但不许压到上下边。
            make.top.greaterThanOrEqualToSuperview().offset(AppMetrics.coverFetchRowVerticalInset)
            make.bottom.lessThanOrEqualToSuperview().offset(-AppMetrics.coverFetchRowVerticalInset)
        }
    }
}

// MARK: - 源标

/// 获取封面页行尾那枚源标：**圆角胶囊 ＋ 一行字**。
///
/// 长得跟歌词源页那枚「逐字」一样（同一档字号、同一套内边距、同样的胶囊圆角），
/// 但**是这一页自己的** —— 两页各管各的，改这页不牵动那页（2026-11-16 统帅定）。
///
/// 🔴 **它是 `UILabel` 子类，不是「圆角底 ＋ 一个 label」的两件套。**
/// 不是为了省一个 view —— 是内边距和圆角必须跟**字本身**同生共死：
/// `drawText` 往里缩、`intrinsicContentSize` 往外补、圆角按自身高度算，
/// 三件事读同一个 `insets`，换字号也不会散架。
private final class CoverSourceBadgeLabel: UILabel {

    /// 内边距：横 6 / 竖 2。
    ///
    /// ⚠️ 只有这一份。`drawText` 和 `intrinsicContentSize` 都从它算 ——
    /// 分开写两套数字的话，字会偏、或者底比字大一圈。
    private static let insets = UIEdgeInsets(
        top: AppMetrics.coverSourceBadgeVerticalPadding,
        left: AppMetrics.coverSourceBadgeHorizontalPadding,
        bottom: AppMetrics.coverSourceBadgeVerticalPadding,
        right: AppMetrics.coverSourceBadgeHorizontalPadding
    )

    /// 🔴 **字一变，尺寸自己重算** —— 不靠调用方记得调。
    ///
    /// ⚠️ 这条不能省：`text` 是 `UILabel` 的公开属性，谁都能直接改；
    /// 只在 `configure` 里手动 `invalidate` 的话，绕过它改字的人就把宽度留在旧值上了。
    override var text: String? {
        didSet { invalidateIntrinsicContentSize() }
    }

    init() {
        super.init(frame: .zero)

        font = AppFont.coverSourceBadge
        textAlignment = .center
        layer.masksToBounds = true
        // 固有尺寸是它全部的宽度来源 —— 谁也别想压扁它。
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    /// 摆上这一枚的字与配色。
    ///
    /// 🔴 **三个参数一次给齐**：拆成三个属性的话，会出现「设了字忘了设色」——
    /// 那时它顶着一支别人的颜色摆在那儿，而没人看得出来是漏了一步。
    func configure(_ text: String, textColor: UIColor, fillColor: UIColor) {
        // 宽度由 `text` 的 `didSet` 自己管，这里不用再管。
        self.text = text
        self.textColor = textColor
        backgroundColor = fillColor
    }

    /// 字往里缩，让出内边距。
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: Self.insets))
    }

    /// 尺寸 = 字 ＋ 内边距。
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + Self.insets.left + Self.insets.right,
            height: size.height + Self.insets.top + Self.insets.bottom
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 胶囊：圆角 = 自身高度的一半 —— 写死数字的话，换个字号就不再是胶囊了。
        layer.cornerRadius = bounds.height / 2
    }
}

// MARK: - 源标配色

private extension CoverSourceKind {

    /// 这一枚源标用哪两色。
    ///
    /// 🔴 **映射只在这一处** —— 加第三个源时编译器会在这个 `switch` 上报"不穷尽"，
    /// 漏不掉。颜色本身在 `AppColor.CoverSourceBadge`（`Core` 不认识 `Data`，所以
    /// 品牌色按名字摆在那儿、由这里挑）。
    var badgeColors: (text: UIColor, fill: UIColor) {
        switch self {
        case .kugou: return AppColor.CoverSourceBadge.kugou
        case .qqMusic: return AppColor.CoverSourceBadge.qqMusic
        }
    }
}

// MARK: - UITableViewDataSource / Delegate

extension CoverFetchViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.now.results.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let dequeued = tableView.dequeueReusableCell(
            withIdentifier: CoverCandidateCell.reuseID,
            for: indexPath
        )
        guard let cell = dequeued as? CoverCandidateCell else {
            assertionFailure("这一页的格只能是 CoverCandidateCell")
            return dequeued
        }

        let rows = viewModel.now.results
        guard rows.indices.contains(indexPath.row) else { return cell }

        let candidate = rows[indexPath.row]
        // 下过就直接摆（滚回来也是它）；没下过先摆占位底，再去要。
        let thumbnail = CoverImageLoader.cached(for: candidate.thumbnailURL)
        cell.show(
            candidate,
            thumbnail: thumbnail,
            isPicking: indexPath.row == viewModel.now.pickingIndex
        )

        if thumbnail == nil {
            loadThumbnail(candidate, at: indexPath)
        }
        return cell
    }

    /// 去要这一行的缩略图。
    ///
    /// 🔴 **回来先认一下"这一行现在还是不是它"**：表格会复用格，
    /// 一趟下载回来时那一格可能已经滚走、或者换了别的候选 —— 对不上就丢掉，
    /// 否则会把 A 的图摆到 B 那行上。
    private func loadThumbnail(_ candidate: CoverCandidate, at indexPath: IndexPath) {
        Task { [weak self] in
            guard let self, let image = await self.viewModel.thumbnail(for: candidate) else { return }
            guard self.viewModel.now.results.indices.contains(indexPath.row),
                  self.viewModel.now.results[indexPath.row].id == candidate.id,
                  let cell = self.tableView.cellForRow(at: indexPath) as? CoverCandidateCell
            else { return }
            cell.showThumbnail(image)
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // 正取着大图的时候不再接第二次点击（一次只取一张）。
        guard !viewModel.now.isPicking else { return }
        viewModel.pick(at: indexPath.row)
    }
}

// MARK: - UISearchBarDelegate

extension CoverFetchViewController: UISearchBarDelegate {

    /// 键盘上那颗**搜索键** —— 网络搜索只在这一下发生（敲字不发请求）。
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        viewModel.search(searchBar.text ?? "")
    }
}

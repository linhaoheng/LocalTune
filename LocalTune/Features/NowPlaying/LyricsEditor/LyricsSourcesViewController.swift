import SnapKit
import UIKit

/// 「歌词源」页 —— 从「获取歌词」页右上那颗「歌词源」**弹**出来。
///
/// 只做四件事：看有哪些源、**点一行选中（立刻生效）**、导入、左滑编辑 / 删除。
///
/// ## 形态：模态（`AppRouter.presentLyricsSources` 给一条 `.grouped` 栈）
///
/// 它是**选择页**，跟选歌页 / 添加到播放列表同一类；而且它是分组表，
/// 推进取词页那条白底栈里栏和列表会差一档 —— 详见 `AppRouter.presentLyricsSources` 的注释。
///
/// ## 选择与关闭（2026-11-14 改）
///
/// 🔴 **点一行 ＝ 立刻生效**（`onSelect`），只是**不关页面**（统帅定）—— 勾就是当前在用的那个，
/// 不是"等确认"。所以左上键仍是**「取消」**：它只负责关掉这一页，不撤销已经点过的选择。
///
/// 🔴 **关掉的出口只有一个 `finish()`**：「取消」/ 导入完 / 手势拖走，三路都汇到它，
/// 由它调一次 `onFinish` —— 调用方拿它来刷一次（用户可能在里面删了正在用的那个）。
/// ⚠️ 手势拖走那一路系统**不会**走页面代码 —— 所以本页还是那张 sheet 的
/// `UIAdaptivePresentationControllerDelegate`，在 `presentationControllerDidDismiss` 里补报。
///
/// ⚠️ 删掉当前选中的源**不在这里改取词页的选择** —— 关掉之后取词页自己会发现
/// 选中的 id 不在了、回落到第一条（见 `LyricsFetchViewController.refreshSourceIfNeeded`）。
final class LyricsSourcesViewController: BaseViewController {

    // MARK: - 依赖

    private let store: LyricsSourceFileStore
    private let router: AppRouter

    /// 点中一行就调 —— **选中即生效**，调用方立刻换上这个源。
    private let onSelect: (LyricsSourceConfig) -> Void

    /// 关掉时调一次 —— 只报"关掉了"，选中已经由 `onSelect` 报过。
    private let onFinish: () -> Void

    // MARK: - 状态

    private var sources: [LyricsSourceConfig]
    private var selectedID: String?

    // MARK: - 零件

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private enum Section: Int, CaseIterable {
        case sources
        case importSource
    }

    /// 空的时候**整段不显示** —— 不是留一行「还没有歌词源」。
    ///
    /// 段头「歌词源」下面一行都没有，本身就是一个空框；段头也返回 `nil`，
    /// 页面上只剩「自定义源 → 导入歌词源」，空状态自己就说清了该干什么。
    ///
    /// ⚠️ 段数**恒为 2**，空的时候是「0 行 ＋ 无段头段脚」—— 不去动态改段数：
    /// 段数一变，表格缓存里的 `indexPath.section` 就可能越界。
    private var hasSources: Bool { !sources.isEmpty }

    // MARK: - 建立

    init(
        store: LyricsSourceFileStore,
        router: AppRouter,
        selectedID: String?,
        onSelect: @escaping (LyricsSourceConfig) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.store = store
        self.router = router
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onFinish = onFinish
        sources = store.loadAll()
        super.init(nibName: nil, bundle: nil)
        title = "歌词源"
        largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 它是模态的根页，没有系统返回键 —— 关掉靠这个键（外加手势下拉）。
        // ⚠️ 它**只管关**：点行那一刻选择就已经生效了，这个键不撤销任何东西。
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )
        tableView.backgroundColor = AppColor.groupedPageBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.register(
            LyricsSourceTitleCell.self,
            forCellReuseIdentifier: LyricsSourceTitleCell.reuseID
        )
        view.addSubview(tableView)
        tableView.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    // MARK: - 动作

    /// 🔴 **唯一的关闭出口** —— 「取消」/ 导入完 / 手势拖走，三路都汇到这儿，`onFinish` 只调一次。
    ///
    /// ⚠️ **先关、再回调**：手势拖走那一路是**关完之后**系统才回调的，
    /// 三条路要对齐同一个时序（回调时这一页已经不在屏幕上了），否则调用方拿到回调时
    /// 还挡着一层 sheet，它想弹什么都弹不出来。
    private func finish() {
        dismiss(animated: true) {
            self.onFinish()
        }
    }

    @objc private func cancelTapped() {
        finish()
    }

    private func reload() {
        sources = store.loadAll()
        if let selectedID, !sources.contains(where: { $0.id == selectedID }) {
            self.selectedID = sources.first?.id
            // 正在用的那个被删了 ⇒ 勾已经落到第一条，取词页也得立刻跟上 ——
            // 「勾着的」和「在用的」不许有一个先一个后。
            if let first = sources.first { onSelect(first) }
        }
        tableView.reloadData()
    }

    private func importSource() {
        router.presentLyricsSourceImport(from: self) { [weak self] config in
            // 导入完立刻用上、并关掉这一页 —— 用户加源就是为了用它。
            self?.onSelect(config)
            self?.finish()
        }
    }

    /// 编辑＝**同一个 id 再存一次**（`save` 按 id 覆盖）—— 数据层不用为它单开一条路。
    ///
    /// ⚠️ 编辑完**不关整个列表页**（跟导入不同）：用户可能还要接着改别的源。
    /// 取词页那边的配置在退出本页时会自己刷新 —— `refreshSourceIfNeeded` 按
    /// `config != currentConfig` 比，内容变了就换，不只认 id。
    private func editSource(_ config: LyricsSourceConfig) {
        router.presentLyricsSourceImport(from: self, editingID: config.id) { [weak self] _ in
            self?.reload()
        }
    }

    private func remove(_ config: LyricsSourceConfig) {
        do {
            try store.delete(id: config.id)
        } catch {
            HUD.showMessage("删除失败，稍后再试", style: .error)
            return
        }
        reload()
    }
}

// MARK: - 表格

extension LyricsSourcesViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .sources: return sources.count
        case .importSource: return 1
        case nil: return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        // 🔴 段头**恒显示**（空的时候也显示）—— 去掉的只是下面那个占位框。
        case .sources: return "歌词源"
        case .importSource: return "自定义源"
        case nil: return nil
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .sources:
            return hasSources ? "点一行即可选中。左滑编辑或删除。" : nil
        case .importSource:
            // 照 primuse 的口径：导入的是"用户自己的源"，合法性由用户负责。
            return "通过 JSON 配置或 URL 导入自定义歌词源。请确保所导入的数据源合法合规，本应用不对第三方源的内容承担责任。"
        case nil:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .sources:
            let config = sources[indexPath.row]
            let dequeued = tableView.dequeueReusableCell(
                withIdentifier: LyricsSourceTitleCell.reuseID,
                for: indexPath
            )
            guard let cell = dequeued as? LyricsSourceTitleCell else {
                assertionFailure("这一行必须是 LyricsSourceTitleCell")
                return UITableViewCell()
            }
            cell.show(title: config.name, isWordLevel: config.supportsWordLevel)
            cell.accessoryType = config.id == selectedID ? .checkmark : .none
            return cell

        case .importSource:
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            cell.accessoryType = .none
            cell.selectionStyle = .default
            cell.tintColor = AppColor.accent
            var content = UIListContentConfiguration.cell()
            content.text = "导入歌词源"
            content.image = UIImage(systemName: "plus.circle")
            content.textProperties.color = AppColor.accent
            content.imageProperties.tintColor = AppColor.accent
            cell.contentConfiguration = content
            return cell

        case nil:
            return UITableViewCell()
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .sources:
            // 🔴 **点中就生效**，只是不关页面 —— 勾＝当前在用的那个。
            let config = sources[indexPath.row]
            guard config.id != selectedID else { return }
            selectedID = config.id
            tableView.reloadData()
            onSelect(config)
        case .importSource:
            importSource()
        case nil:
            break
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .sources, hasSources else { return nil }
        let config = sources[indexPath.row]
        let remove = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            guard let self else { return done(false) }
            self.remove(config)
            done(true)
        }
        remove.backgroundColor = AppColor.destructive

        let edit = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, done in
            guard let self else { return done(false) }
            self.editSource(config)
            done(true)
        }
        edit.backgroundColor = AppColor.accent

        // 数组第一项离屏幕边缘最近 —— 「删除」留在最右，跟系统习惯一致。
        return UISwipeActionsConfiguration(actions: [remove, edit])
    }
}

// MARK: - 手势拖走关闭

extension LyricsSourcesViewController: UIAdaptivePresentationControllerDelegate {

    /// ⚠️ 只有**手势拖走**会走到这儿 —— 「取消」和「导入完」都是程序化 `dismiss`，系统不回调。
    /// 三路不重不漏，`onFinish` 因此只调一次。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onFinish()
    }
}

// MARK: - 源行

/// 源行：名称 ＋（逐字源才有的）「逐字」徽章。
///
/// 🔴 **没有副标题** —— 照 primuse：一行只有名称，能力靠标题后面那枚徽章表达
/// （有徽章 ＝ 逐字源，没有 ＝ 行级源）。勾仍走系统 `accessoryType`，不自绘。
///
/// ⚠️ 徽章是「一块圆角底 ＋ 里面一行字」，**不是**带内边距的 `UILabel`
/// （`LyricsSourceTagLabel` 那种要重写 `drawText` / `intrinsicContentSize`）——
/// 这儿只有一个固定小块，包一层容器更直白，也不用去动导入页那个文件。
private final class LyricsSourceTitleCell: UITableViewCell {

    static let reuseID = "lyricsSourceTitle"

    private let row = UIStackView()
    private let titleLabel = UILabel()
    private let badgeBackground = UIView()
    private let badgeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        tintColor = AppColor.accent

        titleLabel.font = AppFont.lyricsSourceName
        titleLabel.textColor = AppColor.title
        titleLabel.lineBreakMode = .byTruncatingTail

        badgeLabel.text = "逐字"
        badgeLabel.font = AppFont.lyricsSourceBadge
        badgeLabel.textColor = AppColor.accent

        badgeBackground.backgroundColor = AppColor.lyricsSourceBadgeFill
        badgeBackground.layer.masksToBounds = true

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = AppMetrics.lyricsSourceBadgeSpacing
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(badgeBackground)

        contentView.addSubview(row)
        badgeBackground.addSubview(badgeLabel)

        // ⚠️ 行宽**只到内容为止**（`lessThanOrEqualTo`，不是等号）：
        //    钉等号的话 stack 会把多出来的宽度分给某个子视图，徽章就被推到行尾去了。
        row.snp.makeConstraints { make in
            make.leading.equalTo(contentView.layoutMarginsGuide)
            make.trailing.lessThanOrEqualTo(contentView.layoutMarginsGuide)
            make.top.equalTo(contentView).offset(AppMetrics.lyricsSourceRowVerticalInset)
            make.bottom.equalTo(contentView).offset(-AppMetrics.lyricsSourceRowVerticalInset)
        }
        badgeLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(AppMetrics.lyricsSourceBadgeVerticalPadding)
            make.bottom.equalToSuperview().offset(-AppMetrics.lyricsSourceBadgeVerticalPadding)
            make.leading.equalToSuperview().offset(AppMetrics.lyricsSourceBadgeHorizontalPadding)
            make.trailing.equalToSuperview().offset(-AppMetrics.lyricsSourceBadgeHorizontalPadding)
        }
    }

    required init?(coder: NSCoder) {
        // 本行只由代码构造 —— 从 nib / storyboard 解档是写错了：调试期当场停下，正式版返回 nil。
        assertionFailure("LyricsSourceTitleCell 只由代码构造，不该走 init(coder:)")
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 胶囊：圆角 = 自身高度的一半 —— 写死数字的话，换个字号就不再是胶囊了。
        badgeBackground.layer.cornerRadius = badgeBackground.bounds.height / 2
    }

    func show(title: String, isWordLevel: Bool) {
        titleLabel.text = title
        // 隐藏的 arranged subview 会被 `UIStackView` **整个排掉**（连那 12 的间距一起）——
        // 于是行级源那一行就是"只有一个名字"，跟 primuse 一样。
        badgeBackground.isHidden = !isWordLevel
    }
}

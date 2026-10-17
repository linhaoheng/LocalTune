import PanModal
import RxSwift
import SnapKit
import UIKit

/// 队列页 —— 盖在播放页上的**半屏**（屏高 70%），列出现在的播放顺序。
///
/// ```
/// 当前播放(N)          表头（拖它往下能关）
/// ─────────────
/// ▮▮ 正在播的那首  ×
///    下一首        ×   列表（滚到顶再往下拉也能关）
///    …
/// ─────────────
///       关闭
/// ```
///
/// 效果照 `PlayingListViewController` 那一套；
/// **弹出 / 拖走 / 点外面关 交给 `PanModal`**（文件末尾那段）—— 手写那 80 行
/// 拖动与列表滚动联动，库本来就做了。
///
/// 页面只做三件事：订 `content` → 画 → 把点击和 × 交给 VM。
final class QueueViewController: BaseViewController, UITableViewDataSource, UITableViewDelegate {

    private let viewModel: QueueViewModel

    /// 表格正在画的那一份 —— `UITableView` 的数据源必须和它画出来的行**同步**一致，
    /// 所以要留一份；它只是 `viewModel.content` 最近一次推来的值，不是另一份真相。
    private var shown = QueueViewModel.Content.empty

    private let headerView = UIView()
    private let titleLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let closeButton = UIButton(type: .system)

    init(viewModel: QueueViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        layout()
        bind()
    }

    /// 打开时把当前那首滚到中间（弹出动画走完再滚、`.middle`）。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let row = shown.currentRow else { return }
        tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: true)
    }

    // MARK: - 布局

    private func layout() {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        view.addSubview(blur)
        blur.snp.makeConstraints { $0.edges.equalToSuperview() }

        titleLabel.font = AppFont.queueHeaderTitle
        titleLabel.textColor = AppColor.nowPlayingSolid
        headerView.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(AppMetrics.s15)
            make.top.bottom.equalToSuperview()
        }

        tableView.backgroundColor = .clear
        tableView.separatorColor = AppColor.overlaySeparator
        tableView.separatorInset = .zero
        tableView.rowHeight = AppMetrics.queueRowHeight
        tableView.tableFooterView = UIView()
        tableView.register(QueueCell.self, forCellReuseIdentifier: QueueCell.reuseID)
        tableView.dataSource = self
        tableView.delegate = self

        var close = UIButton.Configuration.plain()
        close.attributedTitle = AttributedString(
            "关闭",
            attributes: AttributeContainer([
                .font: AppFont.queueCloseTitle,
                .foregroundColor: AppColor.overlayTextTertiary
            ])
        )
        close.contentInsets = NSDirectionalEdgeInsets(
            top: AppMetrics.s15, leading: AppMetrics.s15,
            bottom: AppMetrics.s15, trailing: AppMetrics.s15
        )
        closeButton.configuration = close
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let headerLine = makeHairline()
        let tableLine = makeHairline()
        for part in [headerView, headerLine, tableView, tableLine, closeButton] {
            view.addSubview(part)
        }
        headerView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(AppMetrics.queueHeaderHeight)
        }
        headerLine.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(headerView)
        }
        closeButton.snp.makeConstraints { make in
            make.bottom.equalTo(view.safeAreaLayoutGuide)
            make.centerX.equalToSuperview()
        }
        tableView.snp.makeConstraints { make in
            make.top.equalTo(headerView.snp.bottom)
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(closeButton.snp.top)
        }
        tableLine.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(tableView)
        }
    }

    /// 表头底边、列表底边那两条线（`qmui_borderPosition = .bottom` / `frd_setBorderAtEdges`）。
    private func makeHairline() -> UIView {
        let line = UIView()
        line.backgroundColor = AppColor.overlaySeparator
        line.isUserInteractionEnabled = false
        line.snp.makeConstraints { $0.height.equalTo(1 / traitCollection.displayScale) }
        return line
    }

    // MARK: - 订阅

    private func bind() {
        viewModel.content
            .subscribe(onNext: { [weak self] content in self?.show(content) })
            .disposed(by: disposeBag)
    }

    /// 换上新的一份；能带动画删的就删（`rowsChange`），别的整表重来。
    private func show(_ content: QueueViewModel.Content) {
        let change = QueueViewModel.rowsChange(
            from: shown.rows.map(\.trackID), to: content.rows.map(\.trackID)
        )
        shown = content
        titleLabel.text = content.headerTitle

        switch change {
        case .reload:
            tableView.reloadData()
        case .deleteRow(let row):
            tableView.deleteRows(at: [IndexPath(row: row, section: 0)], with: .automatic)
            restyleVisibleRows()
        case .restyle:
            restyleVisibleRows()
        }
    }

    private func restyleVisibleRows() {
        tableView.reconfigureRows(at: tableView.indexPathsForVisibleRows ?? [])
    }

    // MARK: - 动作

    /// 收起这一页 —— 跟往下拖走、点外面是同一件事，所以不走 `AppRouter`（同播放页的关闭键）。
    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        shown.rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: QueueCell.reuseID, for: indexPath)
        guard let queueCell = cell as? QueueCell else {
            assertionFailure("注册的就是 QueueCell")
            return cell
        }
        queueCell.show(shown.rows[indexPath.row])
        queueCell.onDelete = { [weak self, weak queueCell] in
            guard let self, let queueCell, let indexPath = self.tableView.indexPath(for: queueCell) else { return }
            self.viewModel.remove(row: indexPath.row)
        }
        return queueCell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        viewModel.play(row: indexPath.row)
    }
}

// MARK: - 弹出形态

/// 半屏、贴底、能拖走 —— 只写跟库默认值不一样的那几条。
extension QueueViewController: PanModalPresentable {

    /// 列表就是那块能滚的：滚到顶再往下拉，拉的就是整个半屏（那段联动）。
    var panScrollable: UIScrollView? { tableView }

    /// 屏高 70% —— **连底部安全区一起算**（整块就是屏高 × 0.7，「关闭」再贴安全区底边）。
    ///
    /// ⚠️ 必须自己写：库默认按 `panScrollable` 的内容高算，歌少时半屏会缩成几行高。
    var longFormHeight: PanModalHeight {
        let screenHeight = presentingViewController?.view.bounds.height ?? view.bounds.height
        return .contentHeightIgnoringSafeArea(screenHeight * AppMetrics.queueSheetHeightRatio)
    }

    /// 顶部圆角 —— 值在 `AppMetrics.queueSheetCornerRadius`（那里写了为什么不做成直角）。
    var shouldRoundTopCorners: Bool { true }

    var cornerRadius: CGFloat { AppMetrics.queueSheetCornerRadius }

    /// 不要顶部那条小横条 —— 库默认开了圆角就画它。
    var showDragIndicator: Bool { false }

    /// 外面不压暗（半屏外是透明的，播放页照常看得见）。
    var panModalBackgroundColor: UIColor { .clear }

    /// 不回弹（升起 / 收起 / 拖一半弹回都是 0.3 秒、不过冲）—— 库默认 0.8 会晃。
    /// 关闭、吸附两档库默认跟这一档走，所以只写这一处。
    var presentationSpring: PanModalSpring { PanModalSpring(response: 0.3, damping: 1) }

    /// 不震 —— 同播放页（`NowPlayingViewController` 那条写了理由）。
    var isHapticFeedbackEnabled: Bool { false }

    /// 库默认给列表底部垫一个安全区高的内边距 —— 这一页列表底下是「关闭」，不贴屏幕底边，不要垫。
    var shouldAdjustToBottomSafeArea: Bool { false }
}

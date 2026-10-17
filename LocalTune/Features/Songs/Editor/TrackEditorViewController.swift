import RxSwift
import SnapKit
import UIKit

/// 歌曲信息编辑页 —— 只做三件事：订阅快照 → 画 → 把动作转给 VM。
///
/// ⚠️ 表格与动作分给两个页面私有协作者（这个文件只留"这一页本身"：装配、订阅、表头、导航栏）：
/// - `TrackEditorListController` —— 表的数据源 / 代理、字段输入（十几个输入框就是表格的内容，跟行走）；
/// - `TrackEditorActionsController` —— 取消 / 保存、换封面（带系统裁剪）、键盘、保存失败提示。
///
/// 呈现走 `AppRouter.presentTrackEditor`（系统页表样式）。**不要「歌词文件」那一行**。
/// 导航栏：**左取消 · 右保存**（关页才写盘，不是失焦就存）。
final class TrackEditorViewController: BaseViewController {

    private let viewModel: TrackEditorViewModel

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    // MARK: - 协作者

    /// 表格协作者 —— 字段就是表格的内容，快照回填 / 打字推 VM / 输入代理都归它。
    private lazy var listController = TrackEditorListController(
        viewModel: viewModel,
        tableView: tableView
    )

    /// 动作协作者 —— 取消 / 保存 / 换封面 / 下拉关闭；弹选择器、弹警告经由这个页面出口。
    private lazy var actionsController = TrackEditorActionsController(
        viewModel: viewModel,
        page: self,
        coverButton: coverButton,
        listController: listController
    )

    /// 下拉关闭的决策者 —— 路由呈现这一页时**显式**挂给 `presentationController`。
    /// 决策实现全在 `TrackEditorActionsController`，这里只递引用（页面不转发调用）。
    var presentationDelegate: UIAdaptivePresentationControllerDelegate { actionsController }

    private let coverShadowView = UIView()
    private let coverImageView = UIImageView()
    /// 点封面换图 —— 动作协作者要当弹出选择器的浮层锚点，init 时递给它。
    private let coverButton = UIButton(type: .custom)
    private let headerContainer = UIView()

    /// 取图的动作 —— 装配层（`App/AppArtwork.image`）给。
    ///
    /// ⚠️ 这一页只认「给个名字 + 尺寸 + 倍数，出一张图」这个形状，不认识封面文件存在哪。
    private let artworkProvider: ArtworkProvider

    init(viewModel: TrackEditorViewModel, artworkProvider: @escaping ArtworkProvider) {
        self.viewModel = viewModel
        self.artworkProvider = artworkProvider
        super.init(nibName: nil, bundle: nil)
        prefersLargeTitles = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "歌曲元数据"
        view.backgroundColor = AppColor.secondaryPageBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: actionsController,
            action: #selector(TrackEditorActionsController.cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "保存",
            style: .done,
            target: actionsController,
            action: #selector(TrackEditorActionsController.saveTapped)
        )
        navigationItem.rightBarButtonItem?.isEnabled = false
        setupTable()
        setupHeader()
        bind()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        coverShadowView.layer.shadowPath = UIBezierPath(
            roundedRect: coverShadowView.bounds,
            cornerRadius: AppMetrics.trackEditorCoverCornerRadius
        ).cgPath
        layoutHeader()
    }

    // ⚠️ 这里原来还有一个 `traitCollectionDidChange`，重设 `view` / `tableView` 的底色和分隔线。
    // **删掉** —— 那三个是**动态色**（`RadixPalette.slateN.uiColor` =
    // `UIColor { trait in … }`，自带浅 / 深两份），系统换外观时**自己会重新解析**；
    // 手写回调重设＝手工补一件系统已经做好的事，还让同一件事多了第二个写者。**别加回来。**

    // MARK: - 装配

    private func bind() {
        viewModel.snapshot
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] snapshot in
                self?.apply(snapshot)
            })
            .disposed(by: disposeBag)

        viewModel.saveErrors
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] error in
                self?.actionsController.presentSaveError(error)
            })
            .disposed(by: disposeBag)

        viewModel.didSaveAndShouldDismiss
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] in
                self?.dismiss(animated: true)
            })
            .disposed(by: disposeBag)
    }

    /// 快照落表：导航栏按钮和封面归页面，字段回填 / 文件信息段重载归表格协作者。
    private func apply(_ snapshot: TrackEditorViewModel.Snapshot) {
        navigationItem.rightBarButtonItem?.title = snapshot.isSaving ? "保存中…" : "保存"
        navigationItem.rightBarButtonItem?.isEnabled = snapshot.hasChanges && !snapshot.isSaving

        fillCover(snapshot)
        listController.apply(snapshot)
    }

    private func fillCover(_ snapshot: TrackEditorViewModel.Snapshot) {
        if let pending = viewModel.pendingCoverImage {
            coverImageView.image = pending
            coverImageView.contentMode = .scaleAspectFill
            coverImageView.tintColor = nil
            return
        }
        let scale = traitCollection.displayScale
        let side = AppMetrics.trackEditorCoverSide
        if let image = artworkProvider(
            snapshot.artworkPath,
            CGSize(width: side, height: side),
            scale
        ) {
            coverImageView.image = image
            coverImageView.contentMode = .scaleAspectFill
            coverImageView.tintColor = nil
        } else {
            coverImageView.image = UIImage(systemName: "music.note")
            coverImageView.contentMode = .center
            coverImageView.tintColor = AppColor.subtitle
        }
    }

    private func setupTable() {
        tableView.backgroundColor = AppColor.secondaryPageBackground
        tableView.separatorColor = AppColor.separator
        tableView.separatorInset = UIEdgeInsets(
            top: 0,
            left: AppMetrics.trackEditorSeparatorLeading,
            bottom: 0,
            right: 0
        )
        tableView.keyboardDismissMode = .onDrag
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = AppMetrics.trackEditorEstimatedRowHeight
        tableView.sectionHeaderTopPadding = 0
        // 表格的数据源 / 代理由列表协作者在 init 里认领（见 `TrackEditorListController`）。
        tableView.register(TrackEditorCell.Info.self, forCellReuseIdentifier: TrackEditorCell.Info.reuseID)
        tableView.register(TrackEditorCell.Field.self, forCellReuseIdentifier: TrackEditorCell.Field.reuseID)
        tableView.register(TrackEditorCell.Lyrics.self, forCellReuseIdentifier: TrackEditorCell.Lyrics.reuseID)
        tableView.cellLayoutMarginsFollowReadableWidth = false
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }

        let tap = UITapGestureRecognizer(target: actionsController, action: #selector(TrackEditorActionsController.endEditingNow))
        tap.cancelsTouchesInView = false
        tableView.addGestureRecognizer(tap)
    }

    private func setupHeader() {
        coverShadowView.backgroundColor = .clear
        coverShadowView.layer.shadowColor = AppColor.shadow.cgColor
        coverShadowView.layer.shadowOpacity = AppMetrics.trackEditorCoverShadowOpacity
        coverShadowView.layer.shadowRadius = AppMetrics.trackEditorCoverShadowRadius
        coverShadowView.layer.shadowOffset = CGSize(width: 0, height: AppMetrics.trackEditorCoverShadowOffsetY)

        coverImageView.clipsToBounds = true
        coverImageView.layer.cornerRadius = AppMetrics.trackEditorCoverCornerRadius
        coverImageView.layer.cornerCurve = .continuous
        coverImageView.backgroundColor = AppColor.artworkPlaceholder
        coverImageView.contentMode = .scaleAspectFill
        coverImageView.isUserInteractionEnabled = false

        coverButton.addTarget(actionsController, action: #selector(TrackEditorActionsController.presentCoverPicker), for: .touchUpInside)

        headerContainer.addSubview(coverShadowView)
        coverShadowView.addSubview(coverImageView)
        headerContainer.addSubview(coverButton)
        coverShadowView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(AppMetrics.trackEditorCoverTopInset)
            make.centerX.equalToSuperview()
            make.size.equalTo(AppMetrics.trackEditorCoverSide)
            make.bottom.equalToSuperview().offset(-AppMetrics.trackEditorCoverBottomInset)
        }
        coverImageView.snp.makeConstraints { $0.edges.equalToSuperview() }
        coverButton.snp.makeConstraints { $0.edges.equalTo(coverShadowView) }
        tableView.tableHeaderView = headerContainer
        layoutHeader()
    }

    private func layoutHeader() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        headerContainer.frame = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: AppMetrics.trackEditorCoverHeaderHeight
        )
        tableView.tableHeaderView = headerContainer
    }

}

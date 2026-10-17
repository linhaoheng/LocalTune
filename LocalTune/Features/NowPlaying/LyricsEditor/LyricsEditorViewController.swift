import RxSwift
import SnapKit
import UIKit

/// 「编辑歌词」页 —— 模态整页，**左关闭 / 右上「获取歌词」＋「保存」**。
///
/// ## 形态
///
/// 模态弹出的一个 `BaseViewController`，自带导航栏；`isModalInPresentation = true`（不能往下拖走 ——
/// 这一页有未存草稿，拖走等于无声丢掉）。**不走 PanModal**：那是播放页的形态，这一页是整页。
///
/// ## 三个模式
///
/// | 模式 | 主区 | 底部工具条 |
/// |---|---|---|
/// | **逐行** | 歌词行表格（改词 ＋ 点时间跳过去听 ＋ 逐字条） | 显示 |
/// | **打轴** | 上一句 / 当前句 / 下句 ＋ 大按钮（内部再分逐行 / 逐字两页） | 显示 |
/// | **原文** | 裸文本框 | **隐藏** |
///
/// ## 🔴 四处有意不同（都不是加功能）
///
/// 1. **不定高**：不给表格 520 / 打轴 360 / 原文 520 三个死数。这里**主区钉满剩余视口**——
///    顶在模式分段下、底贴工具条（原文模式贴键盘），三块主区靠 `UIStackView` 的 `isHidden` 互斥，
///    **各自滚自己**（表 / 原文框），外层不再套一层 `UIScrollView`（否则主区高度塌成估计行高、手势打架）。
/// 2. **播放进度刷歌曲条 ＋ 让逐行页的当前行高亮跟着走**：`position` 那一条流喂两处。
///    🔴 **只换高亮，列表不自动滚**。
///    打轴中间格**仍是行时间**（跟草稿走），**不跟播放头**；**不整表 `reloadData`**。
/// 3. **键盘让位走 `view.keyboardLayoutGuide`**：基类顶上写了这一页直接用系统的那个就行
///    （`BaseViewController` 顶上第 5 条），不收键盘通知自己算高度。
/// 4. **跟随闸 = 键盘态**：正文框拿着键盘时**不跟随**，收起键盘自动恢复 ——
///    不另做开关按钮。
///
/// ## 它不认识的东西
///
/// 播放器（进度订 `position`、打点经 VM 读一次）、曲库（保存走 VM）。
///
/// ⚠️ **跳转只走 `AppRouter`**：右上那颗「获取歌词」是**推一页**，
/// 页面自己不认识取材页、也不自己 push —— 只跟路由说"要取材"。
final class LyricsEditorViewController: BaseViewController {

    // MARK: - 依赖

    /// 草稿与动作。页面**不持有草稿**（页面一关就没了，而"还没存"这件事要跨整个会话活着）。
    let viewModel: LyricsEditorViewModel

    /// 播放进度 —— 只喂歌曲条；打轴中间格不读它。
    private let playManager: PlayManager

    /// 取封面的动作 —— 装配层给（页面不认识封面存在哪）。
    private let artworkProvider: ArtworkProvider?

    /// 跳转的唯一出口 —— 本页只用它一件事：推「获取歌词」那一页。
    private let router: AppRouter

    // MARK: - 零件

    /// 顶栏：歌曲条 ＋ 模式分段（**不滚**）。
    private let headerStack = UIStackView()

    /// 主区：三块互斥，**钉满剩余高度**，各自负责自己的滚动。
    private let mainStack = UIStackView()

    private let songStripView = LyricsEditorSongStripView()
    private let modeControl = UISegmentedControl(
        items: LyricsEditorViewModel.Mode.allCases.map(\.title)
    )
    private let tableView = UITableView(frame: .zero, style: .plain)

    /// 「打轴」那一格 = **二级分段 ＋ 打轴面板**——
    /// 逐行打轴 / 逐字打轴两页共用同一块面板，只有多的那两条不一样。
    private let timingPane = UIStackView()
    private let timingPageControl = UISegmentedControl(
        items: LyricsEditorViewModel.TimingPage.allCases.map(\.title)
    )
    private let timingView = LyricsEditorTimingView()
    private let sourceTextView = UITextView()
    private let toolbar = LyricsEditorToolbar()

    // MARK: - 约束（主区底：贴工具条 / 贴键盘）

    /// 原文模式没有工具条 ⇒ 主区底贴键盘；其余模式贴工具条顶。
    private var mainAboveToolbar: Constraint?
    private var mainToKeyboard: Constraint?

    /// 封面按屏幕倍数取，同一个屏幕下只取一次。
    private var appliedArtworkScale: CGFloat = 0
    private var appliedArtworkPath: String?

    /// 已经**处理过**的光标位 —— 只在光标真变了才处理，改词时每敲一字都 `scrollToRow` 会抖。
    /// ⚠️ "处理"有两档：**滚过去**（用户点行 / 上下一句 / 首次进场），或**故意不滚**
    /// （播放跟随 —— `followPlayback` 会先写这一格再挪光标）。
    private var lastScrolledCursor: Int?

    /// 逐行页里**用户点中的那个字**（哪一个行 ＋ 第几个字）。
    ///
    /// 🔴 逐字高亮**只认用户点选**，**不跟播放头**—— 跟播放的是**行**（`followPlayback`），
    /// 不是字。primuse 文本模式同样只看 `selectedTextSyllable`（`LyricsEditorView.swift:1869`）。
    ///
    /// ⚠️ 它是**页面自己的界面态**（点一下就有，别处不用知道），所以既不进 `Snapshot`，
    /// 也不去动打轴页那个「正在打第几个字」的游标 —— 两页"第几个字"的含义不同，
    /// 共用一份就会出现"在这页点一下、那页的游标跟着跑"。
    private var selectedSyllable: (row: Int, index: Int)?

    // MARK: - 建立

    init(
        viewModel: LyricsEditorViewModel,
        playManager: PlayManager,
        artworkProvider: ArtworkProvider?,
        router: AppRouter
    ) {
        self.viewModel = viewModel
        self.playManager = playManager
        self.artworkProvider = artworkProvider
        self.router = router
        super.init(nibName: nil, bundle: nil)
        title = "编辑歌词"
        // 弹出的页面没有大标题过渡 —— 总闸就在这儿关（`BaseViewController` 顶上那条）。
        prefersLargeTitles = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        isModalInPresentation = true
        view.backgroundColor = AppColor.pageBackground
        setUpNavigationBar()
        setUpSongStrip()
        setUpTable()
        setUpTiming()
        setUpToolbar()
        setUpSourceTextView()
        layoutChrome()
        bindViewModel()
        applyMode(viewModel.now.mode)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadArtworkIfNeeded()
    }

    // MARK: - 导航栏

    /// 右上「保存」—— 一打开就没什么可存的 ⇒ 先灰着（见 `apply`）。
    private lazy var saveItem = UIBarButtonItem(
        barButtonSystemItem: .save,
        target: self,
        action: #selector(saveTapped)
    )

    /// 右上「获取歌词」（**在保存键左边**）—— 去酷狗取一份逐字歌词回来。
    ///
    /// 🔴 **落点只有这一处**：三个模式里**只有导航栏是都看得见的常驻区** ——
    /// 底部工具条是打轴专用语义、且「原文」模式整条隐藏；模式分段只是切视图、不是动作；
    /// 歌曲条右侧已被「时间 ＋ 播放键」占满。而这是**整首**级动作，跟「关闭 / 保存」同级。
    private lazy var fetchItem = UIBarButtonItem(
        title: "获取歌词",
        style: .plain,
        target: self,
        action: #selector(fetchTapped)
    )

    private func setUpNavigationBar() {
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )
        // ⚠️ `rightBarButtonItems` 里**第一个在最右** —— 所以「保存」写前面、「获取歌词」写后面。
        navigationItem.rightBarButtonItems = [saveItem, fetchItem]
        saveItem.isEnabled = viewModel.now.isEdited
    }

    // MARK: - 歌曲条

    private func setUpSongStrip() {
        let track = viewModel.trackForDisplay
        songStripView.setSong(title: track.title, artist: track.artist)
        songStripView.onTogglePlayback = { [weak self] in
            self?.viewModel.togglePlayback()
        }
    }

    /// 按屏幕倍数取一次封面。
    ///
    /// 🔴 **在 `viewDidLayoutSubviews` 里取、且倍数变了才重取** —— 屏幕倍数在第一次布局前读不准
    /// （`ArtworkProvider` 那份注释写了这条），而取错一次图会糊。
    private func loadArtworkIfNeeded() {
        let scale = traitCollection.displayScale
        guard scale > 0, scale != appliedArtworkScale else { return }
        let path = viewModel.trackForDisplay.artworkPath
        guard path != appliedArtworkPath || scale != appliedArtworkScale else { return }
        appliedArtworkScale = scale
        appliedArtworkPath = path
        songStripView.setCover(
            artworkProvider?(
                path,
                CGSize(
                    width: AppMetrics.lyricsEditorCoverSide,
                    height: AppMetrics.lyricsEditorCoverSide
                ),
                scale
            )
        )
    }

    // MARK: - 逐行 · 表格

    private func setUpTable() {
        tableView.register(LyricsEditorLineCell.self, forCellReuseIdentifier: LyricsEditorLineCell.reuseID)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = AppMetrics.lyricsEditorEstimatedRowHeight
        // 行间分隔线：工作台整理文本有 `Divider`（左缩 82）；副本 82 也有。
        // §N.9 曾误判「工作台没线」整表关掉 —— 那是看错了，不是版式升级。
        tableView.separatorStyle = .singleLine
        tableView.separatorColor = AppColor.separator
        tableView.separatorInset = UIEdgeInsets(
            top: 0,
            left: AppMetrics.lyricsEditorRowSeparatorLeading,
            bottom: 0,
            right: 0
        )
        tableView.keyboardDismissMode = .onDrag
        tableView.backgroundColor = AppColor.pageBackground
        tableView.layer.cornerRadius = AppMetrics.lyricsEditorTableCornerRadius
        tableView.layer.borderWidth = AppMetrics.lyricsEditorTableBorderWidth
        tableView.layer.borderColor = AppColor.badge.cgColor
        tableView.clipsToBounds = true
        tableView.contentInsetAdjustmentBehavior = .never
    }

    // MARK: - 打轴 · 工具条

    private func setUpTiming() {
        // 那颗主键：逐行打轴 = 「打时间点并下一行」，逐字打轴 = 「打这一字并下一字」。
        timingView.onStampAndAdvance = { [weak self] in
            guard let self else { return }
            switch self.viewModel.now.timingPage {
            case .line:
                let row = self.viewModel.now.cursorIndex
                self.viewModel.stampNow(at: row)
                self.viewModel.moveCursor(to: row + 1)
            case .syllable:
                self.viewModel.stampSyllableAndAdvance()
            }
        }
        // ⚠️ 逐字条上的块在这页是"**选中**它等着打点"，不是逐行页那种"跳过去听"。
        timingView.onSelectSyllable = { [weak self] index in
            self?.viewModel.selectSyllable(at: index)
        }
        timingView.onNudgeSyllable = { [weak self] delta in
            self?.viewModel.nudgeCurrentSyllable(by: delta)
        }
        timingPageControl.addTarget(self, action: #selector(timingPageChanged), for: .valueChanged)
    }

    private func setUpToolbar() {
        // 🔴 工具条**始终管行**（上一句 / 打点整行 / 下一句 / ±0.5s）——
        // 不随「逐字打轴」换脸或换义；字级动作走打轴面板主键和细条。
        toolbar.connect(
            LyricsEditorToolbar.Actions(
                previousLine: { [weak self] in self?.moveCursor(by: -1) },
                stamp: { [weak self] in
                    guard let self else { return }
                    self.viewModel.stampNow(at: self.viewModel.now.cursorIndex)
                },
                nextLine: { [weak self] in self?.moveCursor(by: 1) },
                decreaseTime: { [weak self] in
                    self?.viewModel.nudgeCurrent(by: -AppMetrics.lyricsEditorNudgeStep)
                },
                increaseTime: { [weak self] in
                    self?.viewModel.nudgeCurrent(by: AppMetrics.lyricsEditorNudgeStep)
                },
                globalShift: { [weak self] in self?.handleGlobalShift() }
            )
        )
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
    }

    // MARK: - 原文 · 文本框

    private func setUpSourceTextView() {
        sourceTextView.textColor = AppColor.title
        sourceTextView.backgroundColor = AppColor.surface
        sourceTextView.layer.cornerRadius = AppMetrics.lyricsEditorSourceCornerRadius
        sourceTextView.font = AppFont.lyricsEditorSource
        sourceTextView.textContainerInset = UIEdgeInsets(
            top: AppMetrics.lyricsEditorSourceVerticalInset,
            left: AppMetrics.lyricsEditorSourceSideInset,
            bottom: AppMetrics.lyricsEditorSourceVerticalInset,
            right: AppMetrics.lyricsEditorSourceSideInset
        )
        // 关掉输入法的自作聪明：歌词里常有连字符、真引号，它们会被悄悄替换掉。
        sourceTextView.autocorrectionType = .no
        sourceTextView.autocapitalizationType = .none
        sourceTextView.smartDashesType = .no
        sourceTextView.smartQuotesType = .no
        sourceTextView.smartInsertDeleteType = .no
        sourceTextView.keyboardDismissMode = .onDrag
        sourceTextView.delegate = self
    }

    // MARK: - 版面

    private func layoutChrome() {
        let side = AppMetrics.lyricsEditorContentSideInset
        let vertical = AppMetrics.lyricsEditorContentVerticalInset
        let spacing = AppMetrics.lyricsEditorBlockSpacing

        headerStack.axis = .vertical
        headerStack.spacing = spacing
        headerStack.alignment = .fill
        headerStack.addArrangedSubview(songStripView)
        headerStack.addArrangedSubview(modeControl)

        // 🔴 主区用 stack 的 `isHidden` 互斥：藏起来的 arranged 子视图**不占位**，
        // 剩下那一块自动吃满钉死的高度。三块各自滚，外层不套 `UIScrollView`。
        mainStack.axis = .vertical
        mainStack.alignment = .fill
        mainStack.distribution = .fill
        // 🔴 打轴那一格是**二级分段 ＋ 面板**：分段只占一行内容高，其余全给面板。
        timingPane.axis = .vertical
        timingPane.alignment = .fill
        timingPane.spacing = AppMetrics.lyricsEditorBlockSpacing
        timingPane.addArrangedSubview(timingPageControl)
        timingPane.addArrangedSubview(timingView)
        timingPageControl.setContentHuggingPriority(.required, for: .vertical)
        timingPageControl.setContentCompressionResistancePriority(.required, for: .vertical)

        mainStack.addArrangedSubview(tableView)
        mainStack.addArrangedSubview(timingPane)
        mainStack.addArrangedSubview(sourceTextView)
        // 🔴 三块主区同等吃满剩余视口；打轴卡片的高在 TimingView 内部，不在这里钉死。
        [tableView, timingPane, sourceTextView].forEach { pane in
            pane.setContentHuggingPriority(.defaultLow, for: .vertical)
            pane.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        view.addSubview(headerStack)
        view.addSubview(mainStack)
        view.addSubview(toolbar)

        toolbar.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            // 🔴 贴 `keyboardLayoutGuide` 顶：键盘上来时工具条自动让位，
            // **不收键盘通知自己算高度**（基类顶上第 5 条写明这一页用系统的那个）。
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }
        headerStack.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(vertical)
            make.leading.trailing.equalToSuperview().inset(side)
        }
        songStripView.snp.makeConstraints { make in
            make.height.equalTo(AppMetrics.lyricsEditorSongStripHeight)
        }
        mainStack.snp.makeConstraints { make in
            make.top.equalTo(headerStack.snp.bottom).offset(spacing)
            make.leading.trailing.equalToSuperview().inset(side)
            mainAboveToolbar = make.bottom.equalTo(toolbar.snp.top).constraint
            mainToKeyboard = make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
                .offset(-vertical).constraint
            // 默认贴工具条；原文模式切过去（见 `applyMode`）。
            mainToKeyboard?.deactivate()
        }
    }

    // MARK: - 订阅

    private func bindViewModel() {
        viewModel.snapshot
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] snapshot in self?.apply(snapshot) })
            .disposed(by: disposeBag)

        viewModel.isPlaying
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] playing in self?.songStripView.setPlaying(playing) })
            .disposed(by: disposeBag)

        viewModel.notice
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] notice in
                HUD.showMessage(notice.text, style: notice.style)
                // 保存成功 ⇒ 关掉这一页（失败要留在页面上让用户看见）。
                if notice.style == .success { self?.dismiss(animated: true) }
            })
            .disposed(by: disposeBag)

        // 🔴 播放进度在这一页有**两件事**：刷歌曲条、以及让「逐行」页跟着走。
        // 打轴中间格仍是**行时间**（跟 snapshot / apply），**不跟播放头** —— 那条口径没动。
        playManager.position
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] position in
                self?.songStripView.setPosition(position)
                self?.followPlayback(position)
            })
            .disposed(by: disposeBag)
    }

    /// 让「逐行」页的**当前行高亮**跟着播放头走 —— **只跟行（句），不跟字**。
    ///
    /// 🔴 **只换高亮，列表不自动滚**：跟到的行不在屏上，
    /// 高亮就跟着在屏外走 —— **要看得自己滚过去**。改这一条之前是"跟着走 ＋ 自动滚到可见"。
    ///
    /// 🔴 **正在打字（键盘拿着）时不跟** —— 治"手指操作期间光标被播放进度抢走"。
    /// 这条闸**不另做开关按钮**：收起键盘就自动恢复（primuse 那边是个显式开关，
    /// 目的是同一件事，我们少一个控件）。
    ///
    /// ⚠️ 光标挪动走 `viewModel.moveCursor`（`Snapshot` 那一条路），**不另开一条状态** ——
    /// 挪完 `apply(snapshot)` 会顺手重画（高亮），跟随要的那件事一件不多。
    /// 光标**没动就什么都不做**：这一页没有"跟着播放头变"的逐字高亮，
    /// 无谓地重画整表只会在播放时白白抖。
    private func followPlayback(_ position: TimeInterval) {
        guard viewModel.now.mode == .lines else { return }
        guard !isEditingText,
              let index = viewModel.followedLineIndex(at: position),
              index != viewModel.now.cursorIndex
        else { return }
        // 🔴 **先把这一格记成"处理过了"，再挪光标** —— 紧接着 `apply` 里的
        //    `scrollToCursorIfNeeded` 就会跳过，列表留在原地。
        //    ⚠️ 用户自己点行 / 上下一句**不走这条**（它们直接调 `moveCursor`），照旧滚。
        lastScrolledCursor = index
        viewModel.moveCursor(to: index)
    }

    /// 有正文框正拿着键盘吗 —— 跟随闸的判据。
    private var isEditingText: Bool {
        tableView.visibleCells.contains {
            ($0 as? LyricsEditorLineCell)?.textView.isFirstResponder == true
        }
    }

    // MARK: - 画

    private func apply(_ snapshot: LyricsEditorViewModel.Snapshot) {
        // ⚠️ 拿**那颗键本身**改，不写 `navigationItem.rightBarButtonItem?` ——
        // 右边现在是两颗（取材 ＋ 保存），靠属性去猜哪一颗只会猜错。
        saveItem.isEnabled = snapshot.isEdited
        applyMode(snapshot.mode)

        // 原文框：用户正打字时别回写（会顶光标）；其余时候跟草稿对齐。
        // 🔴 进原文时 `sourceText` 已由 VM `export(lines)` 填好 —— 这里只负责摆，不再自己 export。
        if sourceTextView.text != snapshot.sourceText, !sourceTextView.isFirstResponder {
            sourceTextView.text = snapshot.sourceText
        }
        applyRows(snapshot)
        // 打轴二级分段选中（工具条不随页换档 —— 始终管行）。
        applyTimingPage(snapshot.timingPage)
        timingView.apply(
            snapshot: snapshot,
            format: LyricsEditorPolicy.format,
            untimedCount: LyricsEditorPolicy.untimedCount(in: snapshot.lines),
            syllables: viewModel.syllablesInCursorLine,
            syllableCursor: snapshot.syllableCursorIndex
        )
        scrollToCursorIfNeeded(snapshot)
    }

    /// 「逐行打轴 / 逐字打轴」二级分段跟草稿对齐。
    private func applyTimingPage(_ page: LyricsEditorViewModel.TimingPage) {
        if timingPageControl.selectedSegmentIndex != page.rawValue {
            timingPageControl.selectedSegmentIndex = page.rawValue
        }
    }

    /// 把表格刷成给定的行。
    ///
    /// 🔴 **只在"行数变了"或"看不见的行"时整表重来，其余只刷可见行**（§B19 那个病：
    /// 每次打点都 `reloadData()`，闪一下、正在打字的那一格还会被重建、键盘跟着抖）。
    ///
    /// 可见行**逐格重画**而不是重走 `cellForRowAt`：那一条缝能保住每个格子自己的
    /// 闭包（行号）与第一响应者。
    ///
    /// ⚠️ 逐字条 / 细条显隐会改行高 —— 刷完必须重量（`remeasureRowHeights`）。
    /// 副本 82 没有逐字条，`apply` 不改高，所以那时不用；现在漏掉就会按旧高裁切，
    /// 进页高亮句只漏半句。
    private func applyRows(_ snapshot: LyricsEditorViewModel.Snapshot) {
        guard !tableView.isHidden else { return }
        if snapshot.lines.count != tableView.numberOfRows(inSection: 0) {
            tableView.reloadData()
            return
        }
        for cell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell),
                  snapshot.lines.indices.contains(indexPath.row),
                  let lineCell = cell as? LyricsEditorLineCell
            else { continue }
            let row = indexPath.row
            lineCell.apply(
                time: snapshot.lines[row].time,
                text: snapshot.lines[row].text,
                issues: snapshot.rowIssues.indices.contains(row) ? snapshot.rowIssues[row] : [],
                highlighted: row == snapshot.cursorIndex,
                syllables: syllables(in: row, of: snapshot),
                selectedSyllableIndex: selectedSyllableIndex(inRow: row)
            )
        }
        remeasureRowHeights()
    }

    /// 第 `row` 行被用户点中的那个字（没点过 / 点的是别的行 ⇒ `nil`）。
    private func selectedSyllableIndex(inRow row: Int) -> Int? {
        guard let selection = selectedSyllable, selection.row == row else { return nil }
        return selection.index
    }

    /// 第 `row` 行的逐字块 —— **当场从正文解析出来**，不缓存。
    ///
    /// ⚠️ 只对**看得见的行**算（`applyRows` / `cellForRowAt` 都只碰可见格）——
    /// 一张两百行的表整表算一遍是白费。
    private func syllables(
        in row: Int, of snapshot: LyricsEditorViewModel.Snapshot
    ) -> [LyricsEditorSyllable] {
        guard snapshot.lines.indices.contains(row) else { return [] }
        return LyricsSyllableTimingPolicy.syllables(inLine: snapshot.lines[row].text)
    }

    /// 切主区。**三处显隐 + 那两条底部约束**都在这里（判据只有"当前是哪个模式"）。
    private func applyMode(_ mode: LyricsEditorViewModel.Mode) {
        tableView.isHidden = mode != .lines
        timingPane.isHidden = mode != .timing
        sourceTextView.isHidden = mode != .source
        toolbar.isHidden = mode == .source

        // 原文模式没有工具条 ⇒ 主区一路顶到键盘。
        if mode == .source {
            mainAboveToolbar?.deactivate()
            mainToKeyboard?.activate()
        } else {
            mainToKeyboard?.deactivate()
            mainAboveToolbar?.activate()
        }

        guard modeControl.selectedSegmentIndex != mode.rawValue else { return }
        modeControl.selectedSegmentIndex = mode.rawValue
    }

    /// 光标变了才滚 —— 改词每敲一字也会推快照，不能次次 `scrollToRow`。
    private func scrollToCursorIfNeeded(_ snapshot: LyricsEditorViewModel.Snapshot) {
        guard snapshot.mode == .lines else {
            lastScrolledCursor = nil
            return
        }
        guard snapshot.cursorIndex != lastScrolledCursor else { return }
        lastScrolledCursor = snapshot.cursorIndex
        scrollToCursor(snapshot.cursorIndex)
    }

    private func scrollToCursor(_ index: Int) {
        guard viewModel.now.lines.indices.contains(index) else { return }
        // 刚从打轴 / 原文切回来时表刚显、行高刚重量 —— 先落完布局再滚，
        // 否则 `scrollToRow` 还按旧高 / 估高算，高亮句会顶在上沿只漏半句。
        tableView.layoutIfNeeded()
        tableView.scrollToRow(
            at: IndexPath(row: index, section: 0),
            at: index == 0 ? .top : .middle,
            animated: false
        )
    }

    /// 上一句 / 下一句 —— 夹在 VM 那一处（`commit`），页面不自己判越界。
    private func moveCursor(by offset: Int) {
        viewModel.moveCursor(to: viewModel.now.cursorIndex + offset)
    }

    // MARK: - 事件

    @objc private func closeTapped() {
        // 有改动才问；没改动直接关。
        guard viewModel.now.isEdited else {
            dismiss(animated: true)
            return
        }
        // ⚠️ 文案装在**说明行**、键序「不保存 → 保存」是这一处自己的产品决定 —— 不并进
        // `SaveChangesAlert`（那边相反），骨架照走 `AppAlert`。
        AppAlert.present(
            from: self,
            title: nil,
            message: "更改尚未保存",
            actions: [
                AppAlert.Action("不保存", style: .destructive) { [weak self] in
                    self?.dismiss(animated: true)
                },
                AppAlert.Action("保存") { [weak self] in
                    self?.confirmSaveThenDismiss()
                },
            ],
            cancel: nil
        )
    }

    @objc private func saveTapped() {
        confirmSaveThenDismiss()
    }

    /// 保存前的**问题清单** —— 有问题先问一遍（文案照抄）。
    private func confirmSaveThenDismiss() {
        let issues = viewModel.saveIssueMessages()
        guard issues.isEmpty else {
            // ⚠️ 键序照抄原状：「取消」摆在前面。
            AppAlert.present(
                from: self,
                title: "保存歌词时遇到问题",
                message: issues.joined(separator: "\n"),
                actions: [
                    AppAlert.Action.cancel(),
                    AppAlert.Action("保存") { [weak self] in
                        self?.viewModel.save()
                    },
                ],
                cancel: nil
            )
            return
        }
        viewModel.save()
    }

    @objc private func modeChanged() {
        guard let mode = LyricsEditorViewModel.Mode(rawValue: modeControl.selectedSegmentIndex) else { return }
        viewModel.setMode(mode)
    }

    // MARK: - 事件 · 取材

    /// 「获取歌词」—— 取回来的是**整首**，所以已经改过内容时先问一句。
    ///
    /// 没改过就直接进：这时候"替换"跟"不替换"对用户是一回事，多问一句只是碍事。
    @objc private func fetchTapped() {
        guard viewModel.now.isEdited else {
            openLyricsFetch()
            return
        }
        AppAlert.present(
            from: self,
            title: "获取歌词",
            message: "取回来的会替换当前内容，继续？",
            actions: [
                AppAlert.Action("继续") { [weak self] in
                    self?.openLyricsFetch()
                },
            ]
        )
    }

    /// 推「获取歌词」页 —— 取回来的正文**只灌工作层**，落库仍然要用户点「保存」。
    ///
    /// 🔴 **页面不自己 push**：它只说"要去取材"，推哪儿去、
    /// 取回来之后怎么退，都是路由的事。
    private func openLyricsFetch() {
        router.pushLyricsFetch(from: self, track: viewModel.trackForDisplay) { [weak self] text in
            self?.viewModel.applyFetchedLyrics(text)
        }
    }

    @objc private func timingPageChanged() {
        guard let page = LyricsEditorViewModel.TimingPage(
            rawValue: timingPageControl.selectedSegmentIndex
        ) else { return }
        viewModel.setTimingPage(page)
    }

    // MARK: - 工具条 · 原文模式

    func handleGlobalShift() {
        AppAlert.prompt(
            from: self,
            title: "全局偏移",
            message: "所有已打轴的时间（行 ＋ 逐字）加上该秒数",
            placeholder: "秒，例如 0.5 或 -0.5",
            keyboardType: .numbersAndPunctuation,
            confirmTitle: "应用",
            onConfirm: { [weak self] text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, let value = Double(trimmed) else {
                    HUD.showMessage("无效的时间", style: .error)
                    return
                }
                self.viewModel.applyGlobalShift(seconds: value)
            }
        )
    }
}

// MARK: - UITableViewDataSource / Delegate

extension LyricsEditorViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.now.lines.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // 🔴 **零 `as!`**：复用失败就现建一个同类型的。
        let cell = tableView.dequeueReusableCell(
            withIdentifier: LyricsEditorLineCell.reuseID, for: indexPath
        ) as? LyricsEditorLineCell ?? LyricsEditorLineCell(style: .default, reuseIdentifier: nil)

        let snapshot = viewModel.now
        guard snapshot.lines.indices.contains(indexPath.row) else { return cell }
        let row = indexPath.row
        cell.apply(
            time: snapshot.lines[row].time,
            text: snapshot.lines[row].text,
            issues: snapshot.rowIssues.indices.contains(row) ? snapshot.rowIssues[row] : [],
            highlighted: row == snapshot.cursorIndex,
            syllables: syllables(in: row, of: snapshot),
            selectedSyllableIndex: selectedSyllableIndex(inRow: row)
        )
        // 🔴 闭包**只带行号 + 正文**，不抓 cell —— 抓 cell 会跟 `onText` 互相强引用成环。
        cell.onTimeButton = { [weak self] in self?.handleLineTimeButton(at: row) }
        cell.onTapSyllable = { [weak self] index in
            self?.selectSyllable(at: row, index: index)
        }
        cell.onNudgeSyllable = { [weak self] delta in
            self?.nudgeSelectedSyllable(inRow: row, by: delta)
        }
        cell.onText = { [weak self] text in
            self?.handleTextChanged(at: row, text: text)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        viewModel.moveCursor(to: indexPath.row)
    }

    /// 改完一行正文：行高会变（内容多了要长高），所以要**重新量一次这一行**。
    ///
    /// 🔴 **不 `reloadData`**—— 那会把整张表重画一遍、
    /// 正在打的字的那一格也会被重建（键盘跟着抖）。`beginUpdates / endUpdates` 只量高度。
    ///
    /// ⚠️ 这一格接下来还会被 `applyRows` 重画一遍（角标 / 高亮可能要变）——
    /// 但正文是**同一份字**，`LyricsEditorLineCell.apply` 里有「值相同就不写」那道闸，
    /// 所以光标不会被顶到末尾。
    private func handleTextChanged(at row: Int, text: String) {
        // 🔴 正文框里不出现逐字标记（既有的标记在 `apply` 里已经被去掉）—— 这里收一次口：
        // 万一用户在框里手打了 `<00:12>`，也不让它进模型（模型那份是"带标记的正文"，
        // 手打的标记会被播放侧当逐字读走，播起来莫名其妙）。
        viewModel.setText(LyricsSyllableTimingPolicy.plainText(inLine: text), at: row)
        // 改过字 ⇒ 这一行原来的逐字标记作废（正文是唯一真相），刚才点选的那个字也就不存在了。
        if selectedSyllable?.row == row { selectedSyllable = nil }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }

    /// 点某一行的**时间键** —— 按行模型分支（工作台 `timestampChip` 同构）：
    /// **有轴** → 跳到该时间（**不自动播放**）；**无轴** → 用当前播放进度给这一行打点。
    ///
    /// 🔴 **先收键盘**：这一行的正文框正拿着键盘时，重画那一格会把输入会话打断
    /// （用户正在改词、顺手点时间键，键盘一收等于半句话没了）。
    private func handleLineTimeButton(at row: Int) {
        endTextEditing()
        let lines = viewModel.now.lines
        guard lines.indices.contains(row) else { return }
        if let time = lines[row].time {
            playManager.seek(to: time)
            return
        }
        viewModel.stampNow(at: row)
    }

    /// 点逐字条上的某一块 —— **选中它**（高亮只认点选，不跟播放头）并跳到它的起点（**不自动播放**）。
    ///
    /// 🔴 选中态一变，细条就多出一截 / 上一行的细条收掉一截 —— **行高必须重量一次**
    /// 表格自己记录的行高还停在旧值，不重量的话细条会画到下一行的地盘上，
    /// 下一行的字压上来，「点完就看不清整句」。
    ///
    /// 🔴 **重量之后不许再补滚**：
    /// 原先这里还跟着一句 `revealRowFully(row)`（`scrollToRow(at: .none)`）—— 这一行
    /// **没露全就瞬时补滚一下**，而被点的那一行刚长高（细条 26 ＋ 间距 8 ＝ 34pt），
    /// 于是**点一次、原地挪一截**。
    /// primuse 那边细条同样住在行里、行高同样跟着变，但它**从不为选中字滚列表**
    /// （`LyricsEditorView.swift` 里唯一的滚动触发是输入框拿到焦点）。
    /// ⇒ **细条出现时下面那些行跟着挪，留着**（那是"凭空多出一条控件"的自然结果）；
    /// **被点那一行自己不许动**。
    private func selectSyllable(at row: Int, index: Int) {
        endTextEditing()
        selectedSyllable = (row, index)
        applyRows(viewModel.now) // 内含重量行高（细条显隐会改高）
        seekToSyllable(at: row, index: index)
    }

    /// 只量高度不闪：`beginUpdates / endUpdates` 重走一遍自适高度的估算（同 `handleTextChanged`）。
    private func remeasureRowHeights() {
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }

    /// 跳到第 `row` 行第 `index` 个字的起点（**不自动播放**；字不存在就什么都不做）。
    private func seekToSyllable(at row: Int, index: Int) {
        let items = syllables(in: row, of: viewModel.now)
        guard items.indices.contains(index) else { return }
        playManager.seek(to: items[index].start)
    }

    /// 微调第 `row` 行里**用户点中的那个字**（细条上那对 `±`）。
    ///
    /// 微调之后行正文变了 ⇒ `viewModel` 推一份新草稿 ⇒ 表格跟着重画。
    private func nudgeSelectedSyllable(inRow row: Int, by delta: TimeInterval) {
        guard let index = selectedSyllableIndex(inRow: row) else { return }
        viewModel.nudgeSyllable(at: row, syllable: index, by: delta)
    }

    /// 把可见格的正文框都收掉键盘（点时间键 / 逐字块之前叫一遍）。
    private func endTextEditing() {
        tableView.visibleCells
            .compactMap { $0 as? LyricsEditorLineCell }
            .forEach { $0.endEditingIfNeeded() }
    }
}

// MARK: - UITextViewDelegate

extension LyricsEditorViewController: UITextViewDelegate {

    func textViewDidChange(_ textView: UITextView) {
        guard textView === sourceTextView else { return }
        viewModel.setSourceText(textView.text)
    }
}

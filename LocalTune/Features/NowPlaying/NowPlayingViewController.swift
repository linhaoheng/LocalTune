import PanModal
import RxSwift
import SnapKit
import UIKit

/// 「正在播放」页 —— **只做三件事：订阅 → 摆 → 把用户动作转给 ViewModel**
///
/// 所以这个文件里**没有**：播放状态（在 `PlayerState`）、进度换算（在 `NowPlayingViewModel`）、
/// 取封面（装配层给的动作）、跳转（`AppRouter` 弹出它）。
///
/// ## 它由哪几块拼成
///
/// ```
/// 背景          铺满整页、压在最底下（跟着封面取色的渐变，`Background/`）
/// 关闭键        左上角
/// 音质条        FLAC · 16bit/44.1kHz ＋ 一枚档位徽章（`SQ`）
/// 大封面        🔴 唯一的弹性块（上顶音质条、下离信息行一点点）
/// 歌词列表      🔴 跟**封面二选一**（信息行那颗引用键开 / 关）
/// 信息行        歌名 + 艺人/专辑 + 收藏键 + 引用键
/// 进度条        滑杆 + 两头时间
/// 传输行        循环 / 上一首 / 播放 / 下一首 / 队列
/// ```
///
/// 🔴 **竖屏这条链上只有封面是弹性的**，别的都由内容撑 ——
/// （`PlayView.layoutSubviews` 里那句 `fullSize.height = infoView.minY − qualityInfoView.maxY − 4`）
/// 还原出来的关系，**不是**一堆算好的固定高度。
/// ⚠️ **歌词列表不是弹性块**：它上下都钉死（顶在封面那条线上、底在信息行之上 8），
/// 跟着封面的位置走 —— 所以"歌词比封面矮一截"是它自上而下算出来的，不是另写的比例。
///
/// ## 怎么被弹出来的
///
/// 走 `AppRouter.presentNowPlaying()` —— 用 `PanModal`（`Libraries/PanModal`）弹出来：
/// 从底下升起、盖满整屏、往下拖能走。
/// 它盖多满、要不要圆角、能不能拖走，全在文件末尾那段 `PanModalPresentable` 里 ——
/// **呈现参数跟着页面走**，因为只有这一页知道它该长什么样。
final class NowPlayingViewController: BaseViewController {

    // MARK: - 依赖

    /// 页面状态 —— 订阅它两条流（低频的样子 + 高频的进度）、把动作转给它。
    private let viewModel: NowPlayingViewModel

    /// 取封面的动作 —— 由装配层给（`AppRouter` 那边传 `AppArtwork.image`）。
    ///
    /// ⚠️ **页面不认识封面存在哪**：它只把"要多大 + 哪个文件"转给这个动作
    ///（`ArtworkProvider` 那份注释写了为什么给的是动作不是图）。
    private let artworkProvider: ArtworkProvider?

    /// 跳转出口 —— 「添加到播放列表」只从这儿 present（不能自己 `present` 第二套添加页）。
    private let router: AppRouter

    // MARK: - 零件

    private let closeButton = PressScaleButton(icon: nil)

    /// 「更多」键 —— 速度 / 定时关闭 / 添加 / 均衡器 / 音质 / 删除。
    private let moreButton = PressScaleButton(icon: nil)

    /// 「歌词设置」键（`lyricsSettingsButton`，图标 `text.alignleft`）—— 同上，占位。
    ///
    /// ⚠️ 别跟信息行右边那颗**引用键**（`quote.bubble`）搞混：那颗是"开 / 关歌词"，
    /// 这颗是"进歌词设置页" —— 是两颗不同的键。
    private let lyricsSettingsButton = PressScaleButton(icon: nil)
    private let backgroundView = NowPlayingBackgroundView()
    private let qualityView = NowPlayingQualityView()
    private let coverView = NowPlayingCoverView()

    /// 竖屏歌词列表 —— **跟封面二选一**。
    /// 直挂本页 `view`（渐隐遮罩挂列表自己的 layer；理由见 `NowPlayingLyricsView` 顶上）。
    private let lyricsView = NowPlayingLyricsView()

    private let infoView = NowPlayingInfoView()
    private let progressView = NowPlayingProgressView()
    private let transportView = NowPlayingTransportView()
    private let landscapePlayButton = PressScaleButton(icon: nil)
    private let landscapeExitButton = PressScaleButton(icon: nil)

    /// 菜单「横屏」：只改这一页的 mask 和退出键。布局仍只看宽高。关页清掉。
    private var forceLandscape = false
    private var appliedKind: NowPlayingLayoutKind?
    private var appliedLayoutWidth: CGFloat = 0
    /// remake 会再勾 `viewWillLayoutSubviews`，正在换的时候不许再进。
    private var isApplyingLayout = false

    /// 歌词列表已经对齐到哪一首 —— 跟 `Content.trackID` 同步。
    private var boundLyricsTrackID: Track.ID?

    /// 歌词流最新一份 —— 换歌时若已匹配就铺它，否则先铺空（丢掉上一首）。
    private var latestLyricsSnapshot = LyricsManager.Snapshot.empty

    // MARK: - 建立

    init(
        viewModel: NowPlayingViewModel,
        artworkProvider: ArtworkProvider?,
        router: AppRouter
    ) {
        self.viewModel = viewModel
        self.artworkProvider = artworkProvider
        self.router = router
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 🔴 这一页是**固定深色**浮层，底色不能走基类设的那个浅色页面底。
        // 平时被取色渐变（`backgroundView`）整块盖住，理由见 `AppColor.nowPlayingBackground`。
        view.backgroundColor = AppColor.nowPlayingBackground

        // 模态要自己说了算状态栏（不然系统问的是**底下那一页**，深色浮层上会压一排深字）。
        modalPresentationCapturesStatusBarAppearance = true

        coverView.artworkProvider = artworkProvider

        layout()
        applySurface(.portrait)
        wireActions()
        bind()

        lyricsView.appearance = viewModel.lyricsAppearance
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        presentingViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed {
            endForceLandscape(requestPortrait: true)
            presentingViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    /// 尺寸定了再换约束 —— **必须在 layout 之前**。排完再 remake 会让 PanModal 改 `view.frame`，再进 layout，两边对着打，打开就卡死。
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        applyLayout(size: view.bounds.size, notifyPanModal: false)
    }

    /// ≡ 键看宽高。这里**不许**换约束、不许喊 PanModal。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLyricsSettingsButtonVisibility()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        applyLayout(size: size, notifyPanModal: false)
        coordinator.animate(alongsideTransition: { _ in
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.panModalSetNeedsLayoutUpdate()
        })
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return forceLandscape ? .landscape : .allButUpsideDown
    }

    /// 深色浮层 ⇒ 状态栏文字要浅色。
    ///
    /// ⚠️ 光重写这一条不够，还得在 `viewDidLoad` 里打开
    /// `modalPresentationCapturesStatusBarAppearance`（见那儿）。
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - 布局

    /// 竖屏那条链：**上面钉顶部那排键和音质条、下面钉传输行，中间的东西依次往上叠，剩下的全给封面**。
    ///
    /// 🔴 每个块的高度**都不是写死的数** —— **只有一个例外**：
    /// - 顶部那排键 → 点击区 40（`nowPlayingChromeButtonHeight`）；
    /// - **音质条 → 高 24，写死的**（`nowPlayingQualityBarHeight`，位置也是写死的 `安全区 + 44`）
    ///   —— 那边也是 `make.height.equalTo(24)`，**不跟字体行高走、也不因没内容而塌**；
    /// - 信息行 → 歌名 + 行距 + 艺人；
    /// - 进度 → 滑杆 + 行距 + 时间；
    /// - 传输行 → 中间那个 60 的播放键撑出来。
    ///
    /// ⇒ 屏幕高一点矮一点，**只有封面在变**（"封面吃掉剩余空间"的等价写法）。
    ///
    /// ⚠️ 顶部那排键**自己一个方法**（`layoutChromeButtons`）—— 那三颗键的样子和位置都在那儿，
    /// 不用在这条链里翻。
    private func layout() {
        // 背景铺满整页、压在所有东西底下 —— 所以**第一个**加进来。
        view.addSubview(backgroundView)
        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        for part in [qualityView, coverView, lyricsView, infoView, progressView, transportView] {
            view.addSubview(part)
        }

        // 🔴 顶部那排键**最后加**：它们是浮在这一页内容之上的。每一层都
        // `bringSubviewToFront` 一遍，我们靠**加的顺序**把同一件事做完
        //（`bringSubviewToFront` 每次布局都调会跟布局互相触发）。
        layoutChromeButtons()
        layoutLandscapeButtons()
        NowPlayingLayout.apply(.portrait, on: layoutSurface, size: view.bounds.size)
    }

    /// 手机横屏才露：播放（对齐信息行）· 强制横屏的退出（右下）。
    private func layoutLandscapeButtons() {
        landscapePlayButton.icon = Self.chromeSymbol("play.fill")
        landscapePlayButton.iconColor = AppColor.nowPlayingSolid
        landscapePlayButton.accessibilityLabel = "播放"
        landscapePlayButton.isHidden = true

        landscapeExitButton.icon = Self.chromeSymbol("iphone")
        landscapeExitButton.iconColor = AppColor.overlayTextSecondary
        landscapeExitButton.accessibilityLabel = "退出横屏"
        landscapeExitButton.isHidden = true

        view.addSubview(landscapePlayButton)
        view.addSubview(landscapeExitButton)
    }

    /// 顶部那排键 —— 关闭（左上）· 歌词设置 · 更多（右上）。
    ///
    /// 🔴 **这块的样子和位置都在这个方法里**（跟 `SongsViewController.layout()` 一个套路：
    /// 一块一个方法）。要改这三颗键的图标 / 颜色 / 无障碍标签，来这儿找，不用翻上面那条链。
    ///
    /// ⚠️ 三颗键的图标颜色都必须**逐个显式给** —— `PressScaleButton` 默认取的是浅色主题那一档
    /// （`AppColor.title`），这一页是固定深色浮层，不给就是深字压深底。
    private func layoutChromeButtons() {
        closeButton.icon = Self.chromeSymbol("chevron.down", weight: .semibold)
        // 🔴 关闭键**跟更多键同色**（次级 70%），不是主文字色 —— 两颗都走
        // `NowPlayingChrome.styleChrome(...)`，而它里面的 `tint` 就是 `overlayTextSecondary`
        //（`TransportView.swift:103/121`；关闭键那颗在 `:218`）。原来我们给的是 `overlayText`（90%），
        // 比参照亮一档（读数：我们 236 / 参照 157）。
        closeButton.iconColor = AppColor.overlayTextSecondary
        closeButton.accessibilityLabel = "收起"

        moreButton.icon = Self.chromeSymbol("ellipsis", weight: .semibold)
        moreButton.iconColor = AppColor.overlayTextSecondary
        moreButton.accessibilityLabel = "更多"

        lyricsSettingsButton.icon = Self.chromeSymbol("text.alignleft")
        // 🔴 这颗键的色调**比旁边那颗暗一档** —— 就是这样（`NowPlayingViewController.swift:221`：
        // `lyricsSettingsButton.tintColor = AppColor.overlayTextTertiary`）。
        // ⚠️ 我们原来给了 `overlayTextSecondary`（70% 白，跟更多键同色）—— 同一字号下**看着更大更重**，
        // 之前"≡ 偏大"的错觉有一半来自这儿。
        lyricsSettingsButton.iconColor = AppColor.overlayTextTertiary
        lyricsSettingsButton.accessibilityLabel = "歌词设置"

        for button in [closeButton, moreButton, lyricsSettingsButton] {
            view.addSubview(button)
        }

        let safeArea = view.safeAreaLayoutGuide
        let keySide = AppMetrics.nowPlayingChromeButtonSide
        let keyHeight = AppMetrics.nowPlayingChromeButtonHeight

        // 顶部那排键**以更多键为基准**（另两颗都"跟它同轴"）：
        // 更多在右上角（上 12 / 右 16）、关闭在左上角与它同高（左 16）、歌词设置在它左边 8。
        // ⚠️ 这几个数走的是 `AppMetrics.nowPlayingChrome*` 那一套 ——
        // 「左 10 / 上 10 / 右 5 / 键间 10」已按同机截图比对推翻（三颗都差 5~10pt）。
        moreButton.snp.makeConstraints { make in
            make.trailing.equalTo(safeArea.snp.trailing)
                .offset(-AppMetrics.nowPlayingChromeTrailingInset)
            make.top.equalTo(safeArea.snp.top).offset(AppMetrics.nowPlayingChromeTopInset)
            make.size.equalTo(
                CGSize(width: AppMetrics.nowPlayingChromeWideSide, height: keyHeight)
            )
        }
        closeButton.snp.makeConstraints { make in
            make.leading.equalTo(safeArea.snp.leading)
                .offset(AppMetrics.nowPlayingChromeLeadingInset)
            make.centerY.equalTo(moreButton)
            make.size.equalTo(CGSize(width: keySide, height: keyHeight))
        }
        lyricsSettingsButton.snp.makeConstraints { make in
            make.trailing.equalTo(moreButton.snp.leading).offset(-AppMetrics.nowPlayingChromeGap)
            make.centerY.equalTo(moreButton)
            make.size.equalTo(CGSize(width: keySide, height: keyHeight))
        }
    }

    /// 「更多」菜单：速度 → 定时关闭 → 添加 → 均衡器 → 音质 → 删除。
    ///
    /// 🔴 用 `UIDeferredMenuElement.uncached`：展开时现读音质勾，不必订开关重建菜单。
    private func makeMoreMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else {
                    completion([])
                    return
                }
                completion(self.moreMenuActions())
            }
        ])
    }

    private func moreMenuActions() -> [UIMenuElement] {
        var items: [UIMenuElement] = [
            UIAction(
                title: "分享歌词",
                image: UIImage(systemName: "text.below.photo"),
                // 没词就没有海报可做 —— 当场置灰，别让用户点进去看一个空页面。
                // 菜单是展开那一刻现建的（`UIDeferredMenuElement.uncached`），所以这里读到的是新值。
                attributes: viewModel.hasLyrics ? [] : .disabled
            ) { [weak self] _ in
                self?.shareCurrentLyrics()
            },
            UIAction(
                title: "速度",
                image: UIImage(systemName: "speedometer")
            ) { [weak self] _ in
                guard let self else { return }
                self.router.presentPlaybackSpeed(from: self)
            },
            UIAction(
                title: "定时关闭",
                image: UIImage(systemName: "moon.zzz")
            ) { [weak self] _ in
                guard let self else { return }
                self.router.presentSleepTimer(from: self)
            },
            UIAction(
                title: "编辑歌词",
                image: UIImage(systemName: "square.and.pencil")
            ) { [weak self] _ in
                guard let self else { return }
                self.editCurrentLyrics()
            },
            UIAction(
                title: "添加到播放列表",
                image: UIImage(systemName: "text.badge.plus")
            ) { [weak self] _ in
                self?.addCurrentToPlaylist()
            },
            UIAction(
                title: "均衡器设置",
                image: UIImage(systemName: "slider.vertical.3")
            ) { [weak self] _ in
                guard let self else { return }
                self.router.presentEqualizer(from: self)
            },
            UIAction(
                title: "音质显示",
                image: UIImage(systemName: "waveform"),
                state: viewModel.showAudioQuality ? .on : .off
            ) { [weak self] _ in
                self?.viewModel.toggleAudioQualityDisplay()
            }
        ]
        if UIDevice.current.userInterfaceIdiom == .phone {
            items.append(
                UIAction(
                    title: "横屏",
                    image: UIImage(systemName: "iphone.landscape"),
                    state: forceLandscape ? .on : .off
                ) { [weak self] _ in
                    self?.toggleForceLandscape()
                }
            )
        }
        items.append(
            UIAction(
                title: "删除",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.confirmDeleteCurrent()
            }
        )
        return items
    }

    /// 顶部那排键的图标（尺寸统一走 `nowPlayingIconPointSize` = 13）。
    private static func chromeSymbol(
        _ name: String, weight: UIImage.SymbolWeight = .regular
    ) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: AppMetrics.nowPlayingIconPointSize, weight: weight
            )
        )
    }

    // MARK: - 接线

    private func wireActions() {
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        // 「更多」：deferred 展开现算；挂一次即可（音质勾不靠订阅重建）。
        moreButton.menu = makeMoreMenu()
        moreButton.showsMenuAsPrimaryAction = true

        // 「歌词设置」：弹出字号 / 对齐面板（它的显隐由 `updateLyricsSettingsButtonVisibility` 管）。
        lyricsSettingsButton.addTarget(
            self, action: #selector(lyricsSettingsTapped), for: .touchUpInside
        )

        infoView.onToggleFavorite = { [weak self] in self?.viewModel.toggleFavorite() }
        infoView.onToggleLyrics = { [weak self] in self?.toggleLyrics() }

        // 歌词列表点某一行 → 跳到那一行的时间（列表只报"哪一秒"，跳转是 ViewModel 的事）。
        lyricsView.onSelectLine = { [weak self] position in
            self?.viewModel.seek(to: position)
        }

        // 进度条只报"手指干了什么"，**不判事** —— "拖动中听谁的""什么时候跳"都在 VM 那边。
        progressView.onScrubBegan = { [weak self] position in
            self?.viewModel.beginScrub(at: position)
        }
        progressView.onScrubChanged = { [weak self] position in
            self?.viewModel.updateScrub(to: position)
        }
        progressView.onScrubEnded = { [weak self] position in
            guard let self else { return }
            self.viewModel.endScrub(at: position)
            // 用户主动拖了进度条 —— 歌词立刻跟回当前位置，不等那 2.5 秒
            // 不喊这一声的话，手滑过歌词之后拖进度条，
            // 列表会停在用户手指离开的地方，看着像"没跳过去"。
            self.lyricsView.resumeFollowing()
        }

        transportView.onPlaybackMode = { [weak self] in
            guard let self else { return }
            self.viewModel.cyclePlaybackMode()
            let content = self.viewModel.contentNow
            HUD.showMessage(NowPlayingTransportView.label(content.playbackMode), style: .success)
        }
        coverView.onSwipePrevious = { [weak self] in self?.viewModel.playPrevious() }
        coverView.onSwipeNext = { [weak self] in self?.viewModel.playNext() }
        transportView.onPrevious = { [weak self] in self?.viewModel.playPrevious() }
        transportView.onPlayPause = { [weak self] in self?.viewModel.togglePlayPause() }
        transportView.onNext = { [weak self] in self?.viewModel.playNext() }
        transportView.onQueue = { [weak self] in
            guard let self else { return }
            self.router.presentQueue(from: self)
        }
        landscapePlayButton.addTarget(self, action: #selector(landscapePlayTapped), for: .touchUpInside)
        landscapeExitButton.addTarget(self, action: #selector(landscapeExitTapped), for: .touchUpInside)
    }

    // MARK: - 订阅

    /// 两条流，各喂各的块。
    ///
    /// 🔴 **低频那条喂整页、高频那条只喂进度条** —— 这就是"高频流和低频流分开"落到界面上的样子
    /// （硬线第 17 条）。两条都只在主线程推，不用再跳线程。
    private func bind() {
        viewModel.content
            .subscribe(onNext: { [weak self] content in
                guard let self else { return }
                // 无歌进不了页；开着时删空队列 → 只关页，**不**把空态（灰键/无音质/「未在播放」）画上屏。
                guard content.hasTrack else {
                    self.closePage()
                    return
                }
                self.show(content)
            })
            .disposed(by: disposeBag)

        viewModel.progress
            .subscribe(onNext: { [weak self] progress in
                // 关页瞬间 content 已无歌 —— 别再往进度条上画 duration:0。
                guard let self, self.viewModel.contentNow.hasTrack else { return }
                self.progressView.show(elapsed: progress.elapsed, duration: progress.duration)
            })
            .disposed(by: disposeBag)

        viewModel.background
            .subscribe(onNext: { [weak self] gradient in
                self?.backgroundView.show(gradient)
            })
            .disposed(by: disposeBag)

        // 「要跟用户说的一句话」—— 收藏没存上（铁律第 9 条：失败不许沉默）。
        viewModel.notice
            .subscribe(onNext: { notice in
                HUD.showMessage(notice.text, style: notice.style)
            })
            .disposed(by: disposeBag)

        // 「这首歌的歌词 ＋ 现在唱到第几行」—— 只喂歌词列表。
        // ⚠️ 这条流跟着 10Hz 的进度走，但列表那边是**只刷换掉的那两行**（它自己的事），
        // 所以这里不必再做什么节流。
        viewModel.lyrics
            .subscribe(onNext: { [weak self] snapshot in
                guard let self else { return }
                self.latestLyricsSnapshot = snapshot
                self.lyricsView.show(
                    trackID: snapshot.trackID,
                    lines: snapshot.lines,
                    currentIndex: snapshot.currentIndex
                )
            })
            .disposed(by: disposeBag)

        // 「原样的播放时间」—— **只喂歌词列表的逐字扫光**（4d）。
        // ⚠️ 跟上面那条 `lyrics` 是**同一条时间轴的两个消费者**（一条算行号、一条扫字），
        // 都从 `PlayManager.position` 派生 —— 不许再引第三条时间来源。
        viewModel.karaokeTime
            .subscribe(onNext: { [weak self] time in
                self?.lyricsView.syncKaraokeTime(time)
            })
            .disposed(by: disposeBag)
    }

    /// 把一份内容分给四块。
    ///
    /// ⚠️ **每块只收它自己画的东西**（不是整份 `Content`）：封面要"哪个文件"、
    /// 信息行要"三样字"、音质条要"一行字 ＋ 一个档位" —— 各块的 `show` 自己知道"值没变就别重画"。
    private func show(_ content: NowPlayingViewModel.Content) {
        coverView.show(
            artworkPath: content.artworkPath,
            previous: content.previousCover.map {
                NowPlayingCoverView.Neighbor(artworkPath: $0.artworkPath)
            },
            next: content.nextCover.map {
                NowPlayingCoverView.Neighbor(artworkPath: $0.artworkPath)
            }
        )
        // 🔴 播停**单独喊一句** —— 不能塞进上面的 `coverView.show`（它会吞掉"只播停、没换歌"）。
        // 用 `isPlaybackActive`（在播 ＋ 装载都算"在播"）：换歌那一下不会先缩再弹
        coverView.setPlaying(content.isPlaybackActive)
        qualityView.show(content.quality)
        infoView.show(
            title: content.title, artist: content.artist, isFavorite: content.isFavorite
        )
        transportView.show(
            playbackMode: content.playbackMode,
            isPlaybackActive: content.isPlaybackActive
        )
        landscapePlayButton.icon = Self.chromeSymbol(
            content.isPlaybackActive ? "pause.fill" : "play.fill"
        )
        landscapePlayButton.accessibilityLabel = content.isPlaybackActive ? "暂停" : "播放"
        // 逐字扫光的"该不该往前跑"跟播放/暂停键同一档（低频，在装也算在播）。
        // ⚠️ 它**不驱动**扫光（那是 10Hz 的 `karaokeTime`），只管暂停时冻住那一帧。
        lyricsView.isPlaybackActive = content.isPlaybackActive
        alignLyrics(to: content.trackID)
    }

    /// 正在播的歌变了 ⇒ 歌词列表必须跟 `Content.trackID` 对齐。
    ///
    /// 行表流若仍是上一首（只比文本时会漏推），这里按新 id 铺空或铺已匹配的快照，
    /// 不会留下「第五句还亮着、字还是上一首的」。
    private func alignLyrics(to trackID: Track.ID?) {
        guard trackID != boundLyricsTrackID else { return }
        boundLyricsTrackID = trackID
        let snap = latestLyricsSnapshot
        if snap.trackID == trackID {
            lyricsView.show(
                trackID: trackID,
                lines: snap.lines,
                currentIndex: snap.currentIndex
            )
        } else {
            lyricsView.show(trackID: trackID, lines: [], currentIndex: nil)
        }
    }

    // MARK: - 动作

    /// 关掉这一页。
    ///
    /// ⚠️ 这一句**不走 `AppRouter`**：它不是"跳到另一页"，而是"把弹起来的自己收回去"
    /// —— 往下拖走（PanModal 那套）干的是同一件事，两条路口子不同、结果一样。
    @objc private func closeTapped() {
        closePage()
    }

    /// 收起播放页 —— **连同盖在它上面的**（队列页 / 添加到播放列表）一起收。
    ///
    /// 🔴 不能直接 `dismiss(animated:)`：上面还盖着一层时，UIKit 只收**上面那一层**，
    /// 播放页自己留着 —— 队列页里 × 掉最后一首，就会剩下一个没歌的播放页。
    /// 让弹出它的那一页来收，才是"它和它上面的全部"。
    private func closePage() {
        endForceLandscape(requestPortrait: true)
        (presentingViewController ?? self).dismiss(animated: true)
    }

    // MARK: - 歌词显隐

    /// 引用键：开 / 关歌词。
    ///
    /// ⚠️ 开关的**真相在设置里**（`AppSettings.lyricsVisible`，跨次启动要记住），
    /// 这里读反、写回、再把界面摆成那个样子 —— 这一页**不自己留一个 `showingLyrics`**，
    /// 留了就是同一件事两处记着。
    private func toggleLyrics() {
        viewModel.setLyricsVisible(!viewModel.lyricsVisible)
        view.setNeedsLayout()
        UIView.animate(withDuration: AppMetrics.nowPlayingLayoutDuration) {
            self.view.layoutIfNeeded()
        }
        panModalSetNeedsLayoutUpdate()
    }

    /// ≡ 键：手机横屏或未开歌词 → 隐藏。手机横屏两栏有歌词，开关仍可能是关的，所以横屏那支不能省。
    private func updateLyricsSettingsButtonVisibility() {
        let size = view.bounds.size
        let phoneLandscape = UIDevice.current.userInterfaceIdiom == .phone && size.width > size.height
        let hidden = phoneLandscape || !viewModel.lyricsVisible
        guard lyricsSettingsButton.isHidden != hidden else { return }
        lyricsSettingsButton.isHidden = hidden
    }

    @objc private func lyricsSettingsTapped() {
        presentLyricsSettings()
    }

    /// 弹出歌词设置面板 —— 只从 `AppRouter` 出去（同队列页 / 均衡器那些）。
    ///
    /// 🔴 面板**只报"外观变成了什么"**（`onChange`），这里负责两件事：
    /// ① 把新值写进设置（走 VM，页面不直接碰 `AppSettings`）；
    /// ② 立刻把它摆到歌词列表上 —— 也就是"拖滑杆即时生效"那一条
    private func presentLyricsSettings() {
        router.presentLyricsSettings(
            from: self,
            appearance: viewModel.lyricsAppearance
        ) { [weak self] appearance in
            guard let self else { return }
            self.viewModel.setLyricsAppearance(appearance)
            self.lyricsView.appearance = appearance
        }
    }

    /// 「添加到播放列表」—— 从**本页** present，盖在播放页上。
    private func addCurrentToPlaylist() {
        guard let trackID = viewModel.contentNow.trackID else { return }
        router.presentAddTracksToPlaylists(trackIDs: [trackID], from: self)
    }

    /// 「编辑歌词」—— 模态整页，从**本页** present（理由同 `addCurrentToPlaylist`）。
    ///
    /// 🔴 存在只写库的 `customLyrics`、**不碰音频文件**——
    /// 「改元数据 / 内嵌歌词」是曲库那边「编辑歌曲信息」页的职责，两页分工不同。
    /// 存完之后播放页的歌词**当场**跟着变，靠 `AppServices` 盯曲库流回推，
    /// 这一页不必、也不该认识播放器。
    private func editCurrentLyrics() {
        guard let trackID = viewModel.contentNow.trackID else { return }
        router.presentLyricsEditor(from: self, trackID: trackID)
    }

    /// 「分享歌词」—— 模态整页（SwiftUI 面板），从**本页** present（理由同 `addCurrentToPlaylist`）。
    ///
    /// 带上**这一刻的播放时间**：面板据此把"当前正唱的那句"选作默认段。
    /// 取的是 `progressNow`（同步读一次）而不是订 `progress` —— 只是开页那一瞬间要一个数。
    ///
    /// ⚠️ 这一页**不认识曲库、也不认识歌词**：取词、解析、造面板全在 `AppRouter` 里做，
    /// 跟 `presentLyricsEditor` 同一条路数（页面只说"去哪一页"）。
    private func shareCurrentLyrics() {
        guard let trackID = viewModel.contentNow.trackID else { return }
        router.presentLyricPoster(
            from: self,
            trackID: trackID,
            playbackPosition: viewModel.progressNow.elapsed
        )
    }

    /// 「删除」确认 —— 文案/三键与曲库单首同一出处。
    ///
    /// 成功后**不**手写关页：库变 → `removeTracks` 切下一首或 idle → `!hasTrack` dismiss。
    private func confirmDeleteCurrent() {
        let content = viewModel.contentNow
        guard content.trackID != nil else { return }
        let alert = LibraryTrackDeleteConfirmation.makeAlert(
            songTitle: content.title,
            onDeleteLibraryOnly: { [weak self] in
                self?.deleteCurrent(deleteFiles: false)
            },
            onDeleteWithFiles: { [weak self] in
                self?.deleteCurrent(deleteFiles: true)
            }
        )
        present(alert, animated: true)
    }

    private func deleteCurrent(deleteFiles: Bool) {
        do {
            try viewModel.deleteCurrent(deleteFiles: deleteFiles)
            HUD.showMessage("已删除", style: .success)
        } catch {
            HUD.showMessage("删除失败", detail: error.localizedDescription, style: .error)
        }
    }

    // MARK: - 摆法

    private var layoutSurface: NowPlayingLayout.Surface {
        NowPlayingLayout.Surface(
            host: view,
            quality: qualityView,
            cover: coverView,
            lyrics: lyricsView,
            info: infoView,
            progress: progressView,
            transport: transportView,
            landscapePlay: landscapePlayButton,
            landscapeExit: landscapeExitButton
        )
    }

    /// 按目标尺寸换摆法。`notifyPanModal` 只在**布局已经结束**之后喊（歌词开关 / 转屏完成），排版过程中喊会跟 PanModal 改 frame 互撞。
    private func applyLayout(size: CGSize, notifyPanModal: Bool) {
        guard size.width > 1, size.height > 1 else { return }
        guard !isApplyingLayout else { return }
        isApplyingLayout = true
        defer { isApplyingLayout = false }

        let kind = NowPlayingLayout.kind(
            width: size.width,
            height: size.height,
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            lyricsVisible: viewModel.lyricsVisible
        )
        let surfaceChanged = applySurface(kind)
        let widthChanged = abs(size.width - appliedLayoutWidth) > 0.5
        let kindChanged = kind != appliedKind || widthChanged
        if kindChanged {
            appliedKind = kind
            appliedLayoutWidth = size.width
            coverView.applyLayoutKind(kind)
            infoView.applyLayoutKind(kind)
            progressView.applyLayoutKind(kind)
            NowPlayingLayout.apply(kind, on: layoutSurface, size: size)
        }
        if notifyPanModal, kindChanged || surfaceChanged {
            panModalSetNeedsLayoutUpdate()
        }
    }

    @discardableResult
    private func applySurface(_ kind: NowPlayingLayoutKind) -> Bool {
        let lyricsVisible = viewModel.lyricsVisible
        let phoneLand = kind.hidesPortraitChrome
        var changed = false
        let coverChanged = setHidden(coverView, kind.coverHidden(lyricsVisible: lyricsVisible))
        let lyricsChanged = setHidden(lyricsView, kind.lyricsHidden(lyricsVisible: lyricsVisible))
        changed = coverChanged || lyricsChanged || changed
        infoView.setLyricsToggleActive(lyricsVisible)
        if coverChanged || lyricsChanged {
            lyricsView.refreshKaraoke()
        }
        changed = setHidden(closeButton, phoneLand) || changed
        changed = setHidden(moreButton, phoneLand) || changed
        changed = setHidden(transportView, phoneLand) || changed
        changed = setHidden(qualityView, phoneLand) || changed
        changed = setHidden(landscapePlayButton, !kind.showsLandscapePlay) || changed
        changed = setHidden(
            landscapeExitButton,
            !(kind.showsLandscapePlay && forceLandscape)
        ) || changed
        return changed
    }

    @discardableResult
    private func setHidden(_ view: UIView, _ hidden: Bool) -> Bool {
        guard view.isHidden != hidden else { return false }
        view.isHidden = hidden
        return true
    }

    @objc private func landscapePlayTapped() {
        viewModel.togglePlayPause()
    }

    @objc private func landscapeExitTapped() {
        endForceLandscape(requestPortrait: true)
    }

    private func toggleForceLandscape() {
        if forceLandscape {
            endForceLandscape(requestPortrait: true)
        } else {
            forceLandscape = true
            setNeedsUpdateOfSupportedInterfaceOrientations()
            presentingViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            applySurface(appliedKind ?? .portrait)
            requestGeometry(.landscape, reportFailure: true)
        }
    }

    private func endForceLandscape(requestPortrait: Bool) {
        guard forceLandscape else { return }
        forceLandscape = false
        setNeedsUpdateOfSupportedInterfaceOrientations()
        presentingViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        applySurface(appliedKind ?? .portrait)
        if requestPortrait {
            requestGeometry(.portrait, reportFailure: false)
        }
    }

    private func requestGeometry(
        _ mask: UIInterfaceOrientationMask,
        reportFailure: Bool
    ) {
        guard let scene = view.window?.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] _ in
            // 这个闭包只在失败时进来（Error 不是 Optional）。
            DispatchQueue.main.async {
                guard let self, reportFailure else { return }
                self.forceLandscape = false
                self.setNeedsUpdateOfSupportedInterfaceOrientations()
                self.applySurface(self.appliedKind ?? .portrait)
                HUD.showMessage("无法转到横屏", style: .error)
            }
        }
    }
}

extension NowPlayingViewController: ControlsWindowOrientation {}

// MARK: - 弹出形态

/// 播放页是**满屏弹层**：从底下升起来盖满整屏，往下拖能走。
///
/// ⚠️ 这里**只写这一页要花力气说的那几条**，不把库的默认值整份抄一遍 ——
/// 抄一遍的后果是：库那边一改，两边就打架，而你不知道该信谁。
///
/// 只有两条例外（值跟默认一样、但仍然自己写出来）：`longFormHeight` 和
/// `shouldRoundTopCorners` —— 它们表达的是**这一页的定义与外观选择**，
/// 不该是别的条件的副产品。理由各自写在它们那儿。
extension NowPlayingViewController: PanModalPresentable {

    /// 这一页的可滚区 = **竖屏歌词列表**。
    ///
    /// 🔴 这一条**库没给默认实现**（`+Defaults` 里独缺它），必须写。
    ///
    /// **恒 `nil`**：开着歌词时产品要「到顶再拉 = 列表橡皮筋，不关页」。
    /// 一旦把列表交给库，`handleScrollViewTopBounce` 会把那段下拉收成关页。
    /// primuse 播放页也是关页另挂手势、列表不参与 sheet 交接（开着歌词只认顶上 chrome 起手）。
    /// 列表照样能滚：见下面 `shouldBeginPanGesture`——歌词区关页手势不开始，手势归列表。
    var panScrollable: UIScrollView? { nil }

    func shouldBeginPanGesture(_ panModalGestureRecognizer: UIPanGestureRecognizer) -> Bool {
        let location = panModalGestureRecognizer.location(in: view)
        if !coverView.isHidden, coverView.frame.contains(location) {
            let velocity = panModalGestureRecognizer.velocity(in: view)
            if abs(velocity.x) > abs(velocity.y) { return false }
        }
        // 开着歌词：歌词区下滑归列表（滚 / 到顶橡皮筋）；关页只从上面 chrome 起手。
        // 必须认 `isHidden`——关着时列表和封面同一块 frame，不能挡封面下拖关页。
        if !lyricsView.isHidden, lyricsView.frame.contains(location) { return false }
        if forceLandscape, infoView.frame.contains(location) { return false }
        return true
    }

    /// **不要**让库去动歌词列表的滚动指示条。
    ///
    /// 本页 `panScrollable` 恒 `nil`，库本就不 KVO 列表；保留 `false` 防哪天又交出去时
    /// `trackScrolling` 把 `showsVerticalScrollIndicator` 强行设回 `true`。
    var allowModifyShowScrollIndicator: Bool { false }

    /// **不要**让库去改歌词列表的 `contentInset.bottom`。
    ///
    /// 库默认（这一项为真）会在有 `panScrollable` 时把它写成屏幕安全区高。
    /// 本页上下留白自己算（各占容器高 0.3 / 0.5）；虽不交列表，仍关此项防哪天又交出去。
    var shouldAdjustToBottomSafeArea: Bool { false }

    /// 满屏 —— 播放页只有这一档高度，没有"半屏"那回事。
    ///
    /// ⚠️ 看着跟库的默认值一样，但**必须自己写出来**：库的默认是
    /// 「有 `panScrollable` 就按内容高、没有才满屏」。满屏是这一页的**定义**，
    /// 不该挂在 `panScrollable` 上。（`shortFormHeight` 默认就是返回 `longFormHeight`。）
    var longFormHeight: PanModalHeight { .maxHeight }

    /// 顶到屏幕最上边。库默认要在状态栏下面留 `topLayoutOffset + 21pt`，
    /// 「盖满」就是把这个缝去掉。
    var topOffset: CGFloat { 0 }

    /// 上边两角要圆 —— 播放页是满屏弹层，只有顶上那一条边是露在外面的。
    ///
    /// 值在 `AppMetrics.nowPlayingSheetCornerRadius`（手机 **20**，iPad **18**）。
    /// 退出来那一小块露出后面那页 —— 是弹层顶角的样子，不是错位。
    ///
    /// ⚠️ 库的默认值是 `isPanModalPresented`（"当弹层弹的时候才圆"），对播放页恒真 ——
    /// 值跟默认一样，仍然写出来：**"上边要圆"是这一页刻意的外观选择**，
    /// 不该读成"因为它是弹层，所以顺手圆一下"。
    var shouldRoundTopCorners: Bool { true }

    /// 圆角多大 —— 值在 `AppMetrics.nowPlayingSheetCornerRadius`（那里写了怎么定的）。
    var cornerRadius: CGFloat { AppMetrics.nowPlayingSheetCornerRadius }

    /// 不要顶部那条小横条。
    ///
    /// 它是画在页面**上边之外**的（页面顶边再往上 `8pt`），页面顶到 `y = 0` 时
    /// 整条落到屏幕外 —— 与其挂一个永远看不见的视图，不如明说不要。
    var showDragIndicator: Bool { false }

    /// 背景压暗 —— 黑 50%（`AppColor.modalScrim`）。
    ///
    /// ⚠️ 盖满时它平时**看不见**：页面整个压在上面，只在**弹出/关闭动画进行中**
    /// 或**往下拖到一半**时才露出来。（半屏弹层才是一直看得见的，这个值主要是给它们定的。）
    var panModalBackgroundColor: UIColor { AppColor.modalScrim }

    /// 点背景**不关**播放页 —— 关它只有两条路：左上角那个键、或者往下拖走。
    ///
    /// ⚠️ 别看它平时"没作用"就当成死设置。盖满之后背景在**静止时**确实露不出来，
    /// 但**弹出动画进行中**那会儿页面还在屏幕下面往上走，**整屏都是背景** ——
    /// 连点两下条子，第二下就落在背景上，弹出瞬间又被关掉。
    /// ⚠️ 动画期间那一下到底传不传得进来**没实测**（取决于 UIKit 在转场期间放不放行触摸）；
    /// 就算传不进来，这条也只是个不会再触发的兜底，不亏。
    /// 剩下唯一还能触发它的场景是「拖到一半时点背景」—— 那个本来也不该关。
    var allowsTapToDismiss: Bool { false }

    /// 不要触觉反馈。
    ///
    /// 库在**弹出**时默认会打一下 `selectionChanged()`（`isHapticFeedbackEnabled` 默认 `true`）——
    /// 也就是每次点开播放页，手机会"嗒"一下。满屏页面出现不该震。
    /// ⚠️ 而且它**只加在弹出那一半**（`feedbackGenerator` 只在 `.presentation` 分支建），
    /// 关掉时没有 —— 一进一出不对称，本来就是作者随手加的。
    var isHapticFeedbackEnabled: Bool { false }

    /// 三条弹簧 —— **照 primuse 播放页那三套的"速度"**。
    ///
    /// 出处：`primuse-main/Primuse/Views/ContentView.swift`。primuse 播放页是自绘浮层，
    /// 三个时机各用一条：
    ///   - 从屏幕底下升起来（弹出）· `:2398` `.spring(response: 0.45, ...)`
    ///   - 拖到一半松手弹回原位　　· `:2484` `.spring(response: 0.34, ...)`
    ///   - 关掉　　　　　　　　　　· `:2502` `.spring(response: 0.38, ...)`
    ///
    /// 两个词跟我们是同一套说法（`response` 对 `response`、`dampingFraction` 对 `damping`）——
    /// 库的换算本来就是照 SwiftUI 那套写的。
    ///
    /// ⚠️ **只取它的速度、不取它的阻尼**：primuse 那三条的阻尼是 `0.92 / 0.86 / 0.94`（都带弹），
    /// 它敢用小于 `1` 是因为播放页顶部有留白；我们顶格满屏，过冲会被裁。
    ///
    /// 过冲有多大（`e^(−ζπ/√(1−ζ²))`，ζ 就是阻尼）：`0.94` ≈ **0.02%**、`0.86` ≈ **0.5%** ——
    /// 满屏那点行程里，前者不到 1 点（**看不出来**）、后者几点（**刚能看出**）。
    /// ⇒ 想"完全不弹"就写 `1`；想弹得明显往 `0.8` 收（`0.8` ≈ 1.5%，十几点）。
    ///
    /// ⚠️ **看什么**：过冲在这儿的形态是**底边抬起一格、露出底下压暗的背景**（顶上圆角也会出门），
    /// 随后落回。
    ///
    /// ⚠️ 连带（库 `PanModalAnimator.timingParameters`）：**速度自适应只对"带手势速度"的那条生效** ——
    /// 有速度且速度 < `minimumVelocityForBounce`（默认 300）时强制按 `1` 算，否则用我们给的值。
    /// **弹出**不带速度（`PanModalPresentationAnimator:122`）⇒ 我们给多少就用多少，改一眼看得见；
    /// **收回**带手势速度 ⇒ **慢慢拖走**时仍被强制 `1`，只有**点关闭键 / 快甩**时才用得上 `0.86`。
    ///
    /// ⚠️ 这段原先写的是「弹出 / 收回调小到 `0.8`、弹回那条仍 `1`」—— 只把字对齐到值，
    /// **值一个没动**。这三个数**是现值、不是定稿**（`0.94` / `0.86` 跟 primuse 那三条的对应看着
    /// 像串了位），真机上看效果再定。
    var presentationSpring: PanModalSpring { PanModalSpring(response: 0.45, damping: 0.94) }

    var dismissalSpring: PanModalSpring { PanModalSpring(response: 0.38, damping: 0.86) }

    var snapSpring: PanModalSpring { PanModalSpring(response: 0.34, damping: 0.86) }
}

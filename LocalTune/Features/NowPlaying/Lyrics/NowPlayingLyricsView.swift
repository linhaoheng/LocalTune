import SnapKit
import UIKit

/// 播放页竖屏的**歌词列表** —— 它自己就是那个可滚的 `UICollectionView`。
///
/// 直挂播放页 `view`：渐隐遮罩挂在列表**自己的 layer** 上（套不滚的容器会牵布局 / 点击穿透，
/// 见 `播放页歌词.md` §J.2）；空态用 `backgroundView`（背景，不跟着滚）。
/// 播放页**不**把它交给 PanModal 做 `panScrollable`——到顶再拉要列表橡皮筋，不要关页。
///
/// 管：摆行与当前行高亮 · 跟唱滚动 · 手滑后 2.5s 自己接上 · 点行报时间 ·
/// **字号 / 对齐跟着设置走**（`appearance`）· **逐字扫光**（4d）。
/// ⚠️ 它**不认识播放器、也不认识 `LyricsManager`** —— 收的是 `(行表, 行号)` 两个值，
/// 外加**一条播放时间**（`syncKaraokeTime`）和**一个"在不在播"**（`isPlaybackActive`）：
final class NowPlayingLyricsView: UICollectionView {

    /// 点了某一行 —— 报出那一行的时间（秒）。
    var onSelectLine: ((TimeInterval) -> Void)?

    /// 歌词长什么样（字号 ＋ 对齐）—— 设置面板改一下，这儿立刻重排。
    ///
    /// 🔴 **"拖滑杆即时改"**，
    /// 所以这一项一变就整表重算。
    /// 🔴 **重算时要把"用户正在看的那一行"锚住**：行高是**显式算**的（`LyricsLineCell.height`），
    /// 字号一变每一行都变高 —— 不锚的话 `contentOffset` 还停在旧值上，界面会猛跳一截。
    var appearance: LyricsAppearance = .default {
        didSet {
            guard appearance != oldValue else { return }
            applyAppearance()
        }
    }

    /// 列表自己的流式布局（行距 12 就在这儿）。
    private let linesLayout = UICollectionViewFlowLayout()

    /// 上下淡出的遮罩。色阶在 `AppColor.lyricsFadeMaskColors`，分界点在 `AppMetrics`。
    private let fadeMask = CAGradientLayer()

    /// 「暂无歌词」那一块 —— 挂成 `backgroundView`（不滚）。
    private let emptyView = NowPlayingLyricsView.makeEmptyView()

    private var lines: [LyricsLine] = []
    private var currentIndex: Int?
    /// 当前行表属于哪一首 —— 跟 `LyricsManager.Snapshot.trackID` 对齐；换歌即使行表 `==` 也要整表重建。
    private var trackID: Track.ID?

    /// 上一次排过版的尺寸 —— 尺寸没变就别动 `contentInset`（滚动也会走到 `layoutSubviews`）。
    private var lastLayoutSize: CGSize = .zero

    /// 当前句停在容器**高的百分之几**处（跟唱定位、字号变化后的复位都从这一个数推）。
    private var focusFraction: CGFloat { AppMetrics.nowPlayingLyricsFocusFraction }

    /// 用户正在手滑歌词（这期间不自动滚）。
    private var userScrolling = false

    /// 手滑结束后恢复跟唱的一次性定时器。
    private var followTimer: Timer?

    // MARK: - 逐字卡拉OK 的状态

    /// 播放器在不在播 —— **低频**（跟播放 / 暂停键同一档："在装也算在播"）。
    ///
    /// ⚠️ 扫光**不由它驱动**（那是 10 Hz 的 `syncKaraokeTime`），它只管"该不该往前跑"：
    /// 暂停 ⇒ 冻在最后一帧（`KaraokeSweepPolicy.RunState.frozen`）。
    var isPlaybackActive: Bool = false {
        didSet {
            guard isPlaybackActive != oldValue else { return }
            refreshKaraoke()
        }
    }

    /// 逐字扫光的**锚点**：`(那一刻的播放时间, 收到它的墙上时间)`。
    ///
    /// 🔴 时间是 **10 Hz** 来的，而屏幕是 60 Hz —— 中间那些帧靠"锚点 ＋ 墙上时间差"外推
    ///（上限见 `KaraokeSweepPolicy.Tuning.maximumFrameAdvance`）。
    /// 进入 `frozen` 时把已经外推的秒数写回这里；回到 `running` 时只钉墙上时间、秒数不动。
    private var karaokeAnchor: (time: TimeInterval, hostTime: CFTimeInterval)?

    /// 上一次落到的 `RunState`。
    /// `running → frozen`：把外推秒数锁进锚点（只一次）。
    /// `frozen → running`：墙上时间钉到现在（别拿暂停那几秒去外推）。
    private var appliedKaraokeRunState: KaraokeSweepPolicy.RunState = .idle

    /// 🔴 **全列表就这一条** —— 不是每个 cell 一条。
    private var karaokeLink: CADisplayLink?

    /// 表那一头的**弱壳** —— 表强引用它，它弱引用列表（见 `startKaraokeLink`）。
    private var karaokeProxy: DisplayLinkProxy?

    init() {
        super.init(frame: .zero, collectionViewLayout: linesLayout)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    deinit {
        cancelFollowTimer()
        stopKaraokeLink()
    }

    // MARK: - 对外

    /// 换一份歌词。
    ///
    /// 🔴 **同曲且行表没变就只动高亮** —— 这条流跟着 10Hz 的进度走，整表 `reloadData` 会闪、
    /// 也会把用户手滑到的位置弹回去（行号一变就整表刷正是那个毛病）。
    ///
    /// 🔴 **换歌必须整表重建**（看 `trackID`，不看行表是否碰巧 `==`）—— 对齐 primuse：
    /// 换歌先清空再铺新词；只刷行号会留下上一首的字 / 高亮 / 滚动位置。
    func show(trackID newTrackID: Track.ID?, lines newLines: [LyricsLine], currentIndex newIndex: Int?) {
        let songChanged = newTrackID != trackID
        let linesChanged = newLines != lines
        let indexChanged = newIndex != currentIndex
        guard songChanged || linesChanged || indexChanged else { return }

        let previousIndex = currentIndex
        trackID = newTrackID
        lines = newLines
        currentIndex = newIndex

        if songChanged || linesChanged {
            rebuildList(resetScroll: songChanged)
            return
        }

        reloadRows(from: previousIndex, to: newIndex)
        scrollToCurrentLine(animated: true)
        refreshKaraoke()
    }

    /// 整表按当前 `lines` 重铺。换歌时顺带清滚动偏移（上一首停在第 N 句的位置对新歌没意义）。
    private func rebuildList(resetScroll: Bool) {
        userScrolling = false
        cancelFollowTimer()
        emptyView.isHidden = !lines.isEmpty
        isScrollEnabled = !lines.isEmpty
        // 行高随当前行字号变；换词后布局缓存必须丢，否则同一 indexPath 会沿用上一首的尺寸。
        linesLayout.invalidateLayout()
        reloadData()
        if resetScroll {
            contentOffset = CGPoint(x: 0, y: -contentInset.top)
        }
        layoutIfNeeded()
        // 可见格强制按新行表重配 —— 防系统在「行数碰巧相同」时复用出上一首的字。
        for case let cell as LyricsLineCell in visibleCells {
            guard let indexPath = indexPath(for: cell),
                  lines.indices.contains(indexPath.item) else { continue }
            cell.show(
                line: lines[indexPath.item],
                isCurrent: indexPath.item == currentIndex,
                baseFontSize: appearance.fontSize,
                alignment: appearance.alignment
            )
        }
        scrollToCurrentLine(animated: false)
        refreshKaraoke()
    }

    /// 播放器被**主动操作**过（拖进度条、点行跳转）—— 立刻恢复跟唱，不等那 2.5 秒。
    func resumeFollowing() {
        userScrolling = false
        cancelFollowTimer()
        scrollToCurrentLine(animated: true)
    }

    // MARK: - 逐字卡拉OK

    /// 10 Hz 的播放时间到了 —— 记锚点、看看该不该跑。
    ///
    /// ⚠️ **不去重**：逐字要的就是"一直在动的时间"（口径同 `PlayManager.position`，
    /// `播放页歌词.md` §E.3）。同一条时间源，第三条消费路径（前两条：进度条、行号）。
    func syncKaraokeTime(_ time: TimeInterval) {
        // 在播时 10Hz 比锚点更早、且早不超过外推上限 ⇒ 校正还没追上画面，别盖。
        // 暂停时这条是 seek，整份换。
        if appliedKaraokeRunState == .running,
           let anchor = karaokeAnchor {
            let rewind = anchor.time - time
            if rewind > 0, rewind <= KaraokeSweepPolicy.Tuning.maximumFrameAdvance {
                refreshKaraoke()
                return
            }
        }
        karaokeAnchor = (time, CACurrentMediaTime())
        refreshKaraoke()
    }

    /// 页面在**歌词显隐 / 尺寸**变了之后叫一声 —— 起停判据里有一条"在不在屏上"，它看不见。
    func refreshKaraoke() {
        let state = karaokeRunState()
        switch state {
        case .running:
            if appliedKaraokeRunState == .frozen, let anchor = karaokeAnchor {
                karaokeAnchor = (anchor.time, CACurrentMediaTime())
            }
            startKaraokeLink()
            drawKaraokeFrame(advancing: true)
        case .frozen:
            // 停表但**保留这一帧** —— 暂停时直接不画的话，逐字那一层会整份消失。
            // 🔴 锁的是画面上已经外推的秒数，不是最后一条 10Hz 样本；只锁一次。
            if appliedKaraokeRunState == .running, let anchor = karaokeAnchor {
                let now = CACurrentMediaTime()
                karaokeAnchor = (interpolatedKaraokeTime(from: anchor, now: now), now)
            }
            stopKaraokeLink()
            drawKaraokeFrame(advancing: false)
        case .idle:
            stopKaraokeLink()
            currentLyricsCell()?.clearKaraoke()
        }
        appliedKaraokeRunState = state
    }

    /// 实时算一遍"这一帧该不该跑" —— 判据全在纯函数里（`KaraokeSweepPolicy.runState`）。
    private func karaokeRunState() -> KaraokeSweepPolicy.RunState {
        guard let index = currentIndex, lines.indices.contains(index) else { return .idle }
        return KaraokeSweepPolicy.runState(
            isCurrentLine: true,
            hasKaraoke: !(lines[index].syllables ?? []).isEmpty,
            isPlaybackActive: isPlaybackActive,
            isOnScreen: window != nil && !isHidden
        )
    }

    /// 当前那一行的 cell —— ⚠️ **每帧现取、不缓存**：cell 会被复用来复用去，存引用迟早指着别人。
    /// 那一行不在屏上就返回 `nil`（不喂时间就行，不是错误）。
    private func currentLyricsCell() -> LyricsLineCell? {
        guard let index = currentIndex, lines.indices.contains(index) else { return nil }
        return cellForItem(at: IndexPath(item: index, section: 0)) as? LyricsLineCell
    }

    /// 把这一刻该画的样子画上去。
    ///
    /// - Parameter advancing: `true` ＝ 按锚点 ＋ 墙上时间差**外推**（在播）；
    ///   `false` ＝ 就画锚点那一刻（暂停 / 冻住；冻住前已把外推秒数写回锚点）。
    private func drawKaraokeFrame(advancing: Bool) {
        guard let anchor = karaokeAnchor else { return }
        let time = advancing
            ? interpolatedKaraokeTime(from: anchor, now: CACurrentMediaTime())
            : anchor.time
        currentLyricsCell()?.renderKaraoke(at: time)
    }

    /// 在播时这一帧该画的秒数 —— 冻住写回锚点也走这里，不另写一份。
    private func interpolatedKaraokeTime(
        from anchor: (time: TimeInterval, hostTime: CFTimeInterval), now: CFTimeInterval
    ) -> TimeInterval {
        let age = max(now - anchor.hostTime, 0)
        return anchor.time + min(age, KaraokeSweepPolicy.Tuning.maximumFrameAdvance)
    }

    /// 排表 —— 只在还没有的时候建一条。
    ///
    /// 🔴 **`CADisplayLink` 强引用它的 target** —— 直接 `target: self` 就是个保留环：
    /// 列表永远不释放、表也永远不停。所以中间垫一个**弱壳**，表只抓住壳。
    private func startKaraokeLink() {
        guard karaokeLink == nil else { return }
        let proxy = DisplayLinkProxy()
        proxy.target = self
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        // ⚠️ 挂 `.common`：默认那档在列表滚动跟踪期间不触发，滚动时逐字会停。
        link.add(to: .main, forMode: .common)
        karaokeProxy = proxy
        karaokeLink = link
    }

    private func stopKaraokeLink() {
        karaokeLink?.invalidate()
        karaokeLink = nil
        karaokeProxy = nil
    }

    /// 一帧 —— 由弱壳转进来（所以是 `fileprivate`，不是 `private`）。
    fileprivate func karaokeTick() {
        guard let anchor = karaokeAnchor else { return }
        // 🔴 锚点**太久没更新** ⇒ 时间流断了（缓冲 / 卡顿），停在原地等下一帧 —— **不硬推**。
        guard CACurrentMediaTime() - anchor.hostTime <= KaraokeSweepPolicy.Tuning.maximumAnchorAge else {
            stopKaraokeLink()
            return
        }
        drawKaraokeFrame(advancing: true)
    }

    // MARK: - 外观（字号 / 对齐）

    /// 定位线上是哪一行 ＋ 落在它的百分之几。
    ///
    /// ⚠️ 记的是**定位线那一行**，不是"当前高亮行"：用户手滑到别处时，
    /// 定位线上那一行才是他正看着的那一行（`currentIndex` 跟屏上位置没关系）。
    private struct CenterAnchor {
        let index: Int
        let ratio: CGFloat
    }

    /// 字号 / 对齐变了：整表按新的一档重排，**但用户正在看的那一行不许跳走**。
    private func applyAppearance() {
        let anchor = centerAnchor()
        collectionViewLayout.invalidateLayout()
        // ⚠️ `reloadData` 不能省：`invalidateLayout` 只让布局重算尺寸，
        // 已经在屏上的 cell 不会重新拿属性串（字号 / 对齐都写在那上面）。
        reloadData()
        layoutIfNeeded()
        restoreCenter(anchor)
        // 字号变了 ⇒ 每个词的矩形全变了；当前行那一条要按新字号重排一次。
        refreshKaraoke()
    }

    private func centerAnchor() -> CenterAnchor? {
        guard bounds.height > 0, !lines.isEmpty else { return nil }
        let center = CGPoint(x: contentOffset.x, y: contentOffset.y + bounds.height * focusFraction)
        guard let indexPath = indexPathForItem(at: center),
              let attributes = layoutAttributesForItem(at: indexPath),
              attributes.frame.height > 0
        else { return nil }
        return CenterAnchor(
            index: indexPath.item,
            ratio: (center.y - attributes.frame.minY) / attributes.frame.height
        )
    }

    /// 把记下的那一行摆回定位线上（同一个"百分之几"）。
    private func restoreCenter(_ anchor: CenterAnchor?) {
        guard let anchor, lines.indices.contains(anchor.index),
              let attributes = layoutAttributesForItem(
                  at: IndexPath(item: anchor.index, section: 0)
              )
        else { return }
        let frame = attributes.frame
        let target = frame.minY + frame.height * anchor.ratio - bounds.height * focusFraction
        // 两头都夹住 —— 否则字号调小之后 `contentSize` 变短，列表能被拉过头（顶上露白）。
        let minimum = -contentInset.top
        let maximum = max(minimum, contentSize.height - bounds.height + contentInset.bottom)
        contentOffset = CGPoint(x: contentOffset.x, y: min(max(target, minimum), maximum))
    }

    // MARK: - 装配

    private func buildSubviews() {
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = true
        // 🔴 上下留白是这一页**自己算**的（各占容器高的一截）——
        // 让系统再按安全区加一份的话两边会叠起来，第一行就跑到屏幕中间去了。
        contentInsetAdjustmentBehavior = .never
        delegate = self
        dataSource = self
        register(LyricsLineCell.self, forCellWithReuseIdentifier: LyricsLineCell.reuseID)

        linesLayout.scrollDirection = .vertical
        // 行与行之间 **12**（`AppMetrics` 那一项写了为什么不取 4）。
        linesLayout.minimumLineSpacing = AppMetrics.nowPlayingLyricsLineSpacing
        linesLayout.minimumInteritemSpacing = 0
        linesLayout.sectionInset = .zero

        fadeMask.colors = AppColor.lyricsFadeMaskColors
        fadeMask.locations = AppMetrics.nowPlayingLyricsFadeLocations
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = fadeMask

        backgroundView = emptyView
        emptyView.isHidden = true
        isScrollEnabled = false
    }

    /// 把渐隐遮罩贴回**可视区**。
    ///
    /// 🔴 遮罩挂在**会滚的列表自己的 layer** 上 —— 它是这个层的子层，坐标跟着 `bounds.origin`
    /// （= `contentOffset`）走。不重贴的话，它就随内容一起滚走，而它只有 `[0.12, 0.82]` 一段
    /// 不透明 ⇒ 那一段一离开屏幕，**整个歌词框就没字了**，要等下一次布局才把字带回来。
    /// 这个坑本来没有：同一个遮罩挂在**不滚动的 `lyricsContainer`** 上时（容器 `bounds.origin` 恒 0），
    /// 所以整份歌词永远都在 —— 见 `播放页歌词.md` §E.4。
    ///
    /// ⚠️ **必须关掉隐式动画**：`fadeMask` 是手工建的独立 layer，直接改 `frame` 会拿到 Core
    /// Animation 默认那 0.25 秒动画 —— 遮罩就变成"追"着滚动跑，而不是每一帧钉住。
    private func updateFadeMaskFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 尺寸变化 / 转屏 / 首次上屏走这里；滚动中的重贴走 `scrollViewDidScroll`
        //（两处触发条件不同，都要，见 `updateFadeMaskFrame`）。
        updateFadeMaskFrame()

        let size = bounds.size
        guard size.width > 0, size.height > 0, size != lastLayoutSize else { return }
        lastLayoutSize = size

        contentInset = UIEdgeInsets(
            top: size.height * AppMetrics.nowPlayingLyricsInsetTopFraction,
            left: 0,
            bottom: size.height * AppMetrics.nowPlayingLyricsInsetBottomFraction,
            right: 0
        )
        collectionViewLayout.invalidateLayout()
        layoutIfNeeded()
        scrollToCurrentLine(animated: false)
        // 尺寸一变，每个词的矩形也变 —— 当前行那条要重排一次。
        refreshKaraoke()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 页面刚上屏时尺寸才定下来 —— 第一次 `show` 那会儿还没有窗口，滚不了，这里补一次。
        if window != nil { scrollToCurrentLine(animated: false) }
        // 起停判据里有一条"在不在屏上" —— 上屏 / 离屏都要重算（离屏就该停表）。
        refreshKaraoke()
    }

    // MARK: - 跟唱滚动

    /// 把当前行滚到「容器高 36%」处。**手滑中不滚**（用户正在看别处，不该被拽回去）。
    ///
    /// 🔴 原来用 `scrollToItem(at: .centeredVertically)` —— 它内部就是「行中心 − 容器高 × 0.5」
    /// 再夹边界。`UIKit` 只给「50%」这一个现成选项，所以这里自己算一遍，
    /// **只把 0.5 换成 `focusFraction`**，夹边界照旧。
    private func scrollToCurrentLine(animated: Bool) {
        guard !userScrolling, window != nil, bounds.height > 0,
              let index = currentIndex, lines.indices.contains(index),
              let attributes = layoutAttributesForItem(at: IndexPath(item: index, section: 0))
        else { return }
        let y = attributes.frame.midY - bounds.height * focusFraction
        let limit = contentSize.height - bounds.height + contentInset.bottom
        setContentOffset(
            CGPoint(x: contentOffset.x, y: min(max(y, -contentInset.top), limit)),
            animated: animated
        )
    }

    /// 只刷"换掉的那两行"：上一行洗掉高亮、这一行加上。
    ///
    /// ⚠️ 必须走 `reloadItems`（它会重算 `sizeForItemAt`）：**当前行字号比普通行大 ⇒ 行高会变**，
    /// 只改 cell 内部的话那一行会错一截。
    private func reloadRows(from previous: Int?, to current: Int?) {
        var paths: [IndexPath] = []
        if let previous, lines.indices.contains(previous) {
            paths.append(IndexPath(item: previous, section: 0))
        }
        if let current, lines.indices.contains(current), current != previous {
            paths.append(IndexPath(item: current, section: 0))
        }
        guard !paths.isEmpty else { return }
        // ⚠️ 关掉隐式动画：`reloadItems` 默认给这两行做一次淡入，一秒跳好几行时会看到整片字在闪。
        UIView.performWithoutAnimation { reloadItems(at: paths) }
    }

    // MARK: - 手滑 → 暂停跟唱 → 定时接上

    /// 排一次"自己接上跟唱"。⚠️ 要挂 `.common` 运行模式 —— 默认那档在滚动跟踪期间不触发。
    private func scheduleFollowResume() {
        cancelFollowTimer()
        let timer = Timer(
            timeInterval: AppMetrics.nowPlayingLyricsFollowResumeDelay, repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.followTimer = nil
            self.userScrolling = false
            self.scrollToCurrentLine(animated: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func cancelFollowTimer() {
        followTimer?.invalidate()
        followTimer = nil
    }

    // MARK: - 无词占位

    /// 「暂无歌词」那一块。
    ///
    /// ⚠️ 这一块**要留**（`noLyrics` 流只写 `false` 是死代码；标题 + 三键那一套才该有）。
    /// 我们既不上传也不识别，所以只留**一句话 + 一个去处** —— 算「补缺」，不是"凭空加元素"
    private static func makeEmptyView() -> UIView {
        let container = UIView()

        let title = UILabel()
        title.text = "暂无歌词"
        title.font = AppFont.lyricsPlaceholder(baseSize: AppMetrics.nowPlayingLyricsFontSize)
        title.textColor = AppColor.overlayTint
        title.textAlignment = .center

        let hint = UILabel()
        hint.text = "可在「更多 → 编辑歌词」里添加"
        hint.font = AppFont.lyricsCompanion(baseSize: AppMetrics.nowPlayingLyricsFontSize)
        hint.textColor = AppColor.nowPlayingLyricsSecondary
        hint.textAlignment = .center
        hint.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, hint])
        stack.axis = .vertical
        stack.spacing = AppMetrics.nowPlayingLyricsCompanionGap
        stack.alignment = .center
        container.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview()
            make.trailing.lessThanOrEqualToSuperview()
        }
        return container
    }
}

// MARK: - 列表内容

extension NowPlayingLyricsView: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        lines.count
    }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: LyricsLineCell.reuseID, for: indexPath
        ) as? LyricsLineCell else {
            // 注册过就一定解得出来 —— 走到这儿是"有人把注册摘了"，不是运行期可能发生的事。
            assertionFailure("歌词行 cell 必须按 LyricsLineCell 注册")
            return UICollectionViewCell()
        }
        cell.show(
            line: lines[indexPath.item],
            isCurrent: indexPath.item == currentIndex,
            baseFontSize: appearance.fontSize,
            alignment: appearance.alignment
        )
        return cell
    }
}

// MARK: - 行高 / 点击 / 手滑

extension NowPlayingLyricsView: UICollectionViewDelegateFlowLayout {

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = collectionView.bounds.width
        let height = LyricsLineCell.height(
            for: lines[indexPath.item],
            isCurrent: indexPath.item == currentIndex,
            width: width,
            baseFontSize: appearance.fontSize
        )
        return CGSize(width: width, height: height)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard lines.indices.contains(indexPath.item) else { return }
        let line = lines[indexPath.item]
        // 纯文本歌词没有时间 —— 点了没地方跳，也不该跳（`LyricsLine.isSynchronized`）。
        guard line.isSynchronized else { return }
        userScrolling = false
        cancelFollowTimer()
        onSelectLine?(line.timestamp)
    }

    /// 内容偏移一变就重贴遮罩 —— 不能只指望 `layoutSubviews`（滚动时它不保证每帧都来），
    /// 否则字会"滚没了，等一下才回来"。理由是 `updateFadeMaskFrame`。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateFadeMaskFrame()
        // 滚动中当前行那条可能刚被复用出来（`prepareForReuse` 会把逐字那层整个收掉）——
        // 尤其**暂停**时（表已经停了），不补这一下，来回滑一下就没了。
        refreshKaraoke()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userScrolling = true
        cancelFollowTimer()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleFollowResume() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleFollowResume()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        // ⚠️ 这一条**也会被"我们自己滚过去"触发**（跟唱用 `scrollToItem(animated: true)`）——
        // 那种时候 `userScrolling` 是 `false`，所以只有"用户滑完的余韵"才会排恢复。
        if !scrollView.isDecelerating, userScrolling { scheduleFollowResume() }
    }
}

/// `CADisplayLink` 的**弱 target 壳**。
///
/// 🔴 表**强引用** target —— 直接拿列表当 target 就是保留环（列表不释放、表不停）。
/// 垫一层：表抓壳、壳弱引用列表。
private final class DisplayLinkProxy {

    weak var target: NowPlayingLyricsView?

    @objc func tick() {
        target?.karaokeTick()
    }
}

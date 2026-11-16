import SnapKit
import UIKit

/// 播放页竖屏的**歌词列表** —— 它自己就是那个可滚的 `UICollectionView`。
///
/// 直挂播放页 `view`：渐隐遮罩挂在列表**自己的 layer** 上（套不滚的容器会牵布局 / 点击穿透，
/// 见 `播放页歌词.md` §J.2）；空态用 `backgroundView`（背景，不跟着滚）。
/// 播放页**不**把它交给 PanModal 做 `panScrollable`——到顶再拉要列表橡皮筋，不要关页。
///
/// 管：摆行与当前行高亮 · 跟唱滚动 · **换行时逐行错开**（`isStaggeredScrollEnabled`）·
/// 手滑后 2.5s 自己接上 · 点行报时间 · **字号 / 对齐跟着设置走**（`appearance`）· **逐字扫光**（4d）。
/// ⚠️ 它**不认识播放器、也不认识 `LyricsManager`** —— 收的是 `(行表, 行号)` 两个值，
/// 外加**一条播放时间**（`syncKaraokeTime`）和**一个"引擎真在出声吗"**（`isActuallyPlaying`）：
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

    /// 换行时**逐行错开**地滑过去（「交错滚动」）—— 开关在歌词设置面板。
    ///
    /// 关掉就退回原来那条：`setContentOffset(animated: true)`，所有行一起动。
    var isStaggeredScrollEnabled: Bool = false {
        didSet {
            // 只在「开 → 关」那一刻收尾：本来就是关的、或者刚打开，都不用打断。
            guard oldValue, !isStaggeredScrollEnabled else { return }
            cancelCascade()
            // 停表之后这条路**没有新动画跟着**，得自己补一次终态。
            settleVisibleCells(animated: false)
        }
    }

    /// 正在跑的那一趟交错 —— **纯数据，是所有参数的唯一来源**。
    ///
    /// 它算「每格晚多久起步、自己走多久」；真正把位移跑起来的是每格那个
    /// `UIViewPropertyAnimator`（系统驱动，不是自己每帧写值）。
    ///
    /// 🔴 **每行等时长、只错开起点**（`travel` 对每一行都一样，差异全在起步延迟）：
    /// 所以不会出现「第一行慢动作、最后一行窜过去」。
    ///
    /// 🔴 **带着 `startedAt`**：起点基准只有一个。`subviews` 快照之后才出生的格子
    /// （最后一句常常是这一种）靠它算出「这一趟已经过去多久」，只走剩下的那一段。
    private var cascadeRun: CascadeRun?

    private struct CascadeRun {
        let delta: CGFloat
        /// 每一行**自己**走完要多久 —— 所有行相同。
        let travel: TimeInterval
        /// 运动方向相邻两档的起步间隔。
        let forwardStep: TimeInterval
        /// 反方向相邻两档的起步间隔 —— 比正向密（见 `LyricCascadeTiming` 文件头）。
        let backwardStep: TimeInterval
        /// 这一趟的**起点行**（0 档）—— 跳之前停在定位线上的那一行。
        let origin: Int
        /// 这一趟从哪一刻开始 —— `CACurrentMediaTime()`，跟 Core Animation 同一个时基。
        let startedAt: CFTimeInterval

        /// 这一格晚多久起步。
        ///
        /// 🔴 **以起点行为准、往两边数**：正向按 `forwardStep`、反向按 `backwardStep`。
        /// 规则本身在 `LyricCascadeTiming.delay`，这里只负责把「我离起点行多远」问出来。
        ///
        /// ⚠️ **2026-11-15 起没有「延迟表」了**：以前是预先算一张表、还得把档夹进表长
        /// （中途出生的格子会越界）。现在是公式 —— 越界只意味着「它更晚起步」，
        /// 而它本来就在屏幕外。
        func startDelay(of index: Int) -> TimeInterval {
            LyricCascadeTiming.delay(
                forStep: LyricCascadeTiming.signedStep(
                    of: index, from: origin, scrollingDown: delta > 0
                ),
                forward: forwardStep,
                backward: backwardStep
            )
        }

        /// 这一格**从此刻**起跑，该等多久、走多久 —— `nil` ＝ 它这一趟已经走完了。
        ///
        /// ⚠️ 正常情况（`now == startedAt`）拿到的是「完整延迟 ＋ 完整 `travel`」，
        /// 只有快照之后出生的格子才会被扣掉已经过去的那一段。
        func schedule(for index: Int, now: CFTimeInterval)
            -> (delay: TimeInterval, duration: TimeInterval)? {
            LyricCascadeTiming.remainingPlan(
                elapsed: now - startedAt,
                delay: startDelay(of: index),
                travel: travel
            )
        }
    }

    /// 这一趟里正在跑的动画 —— **一趟一批，开下一趟前整批清掉**。
    private var cascadeAnimators: [UIViewPropertyAnimator] = []

    /// 手滑结束后恢复跟唱的一次性定时器。
    private var followTimer: Timer?

    // MARK: - 逐字卡拉OK 的状态

    /// **引擎真的在出声吗** —— 低频，只有 `.playing` 算，**装载中不算**。
    ///
    /// 🔴 **不能用播放键那一档（`isPlaybackActive`）**：那一档把 `.loading` 也算在播，
    /// 但装载中引擎还没出声、进度还是 0。拿它开扫光的话，装载那几百毫秒会被当成"在唱"。
    ///
    /// ⚠️ 这一档管的是**"该不该跑"**，它治不了「点播放先亮一小块、然后重扫」——
    /// 那个病根在 `refreshKaraoke` 里（进 `running` 时没钉锚点的墙上时间），见那儿。
    ///
    /// ⚠️ 扫光**不由它驱动**（那是 10 Hz 的 `syncKaraokeTime`），它只管"该不该往前跑"：
    /// 暂停 / 装载 ⇒ 冻在最后一帧（`KaraokeSweepPolicy.RunState.frozen`）。
    var isActuallyPlaying: Bool = false {
        didSet {
            guard isActuallyPlaying != oldValue else { return }
            refreshKaraoke()
        }
    }

    /// 逐字扫光的**锚点**：`(那一刻的播放时间, 收到它的墙上时间)`。
    ///
    /// 🔴 时间是 **10 Hz** 来的，而屏幕是 60 Hz —— 中间那些帧靠"锚点 ＋ 墙上时间差"外推
    ///（上限见 `KaraokeSweepPolicy.Tuning.maximumFrameAdvance`）。
    /// 进入 `frozen` 时把已经外推的秒数写回这里；**任何状态**回到 `running` 时只钉墙上时间、秒数不动。
    private var karaokeAnchor: (time: TimeInterval, hostTime: CFTimeInterval)?

    /// 上一次落到的 `RunState`。
    /// `running → frozen`：把外推秒数锁进锚点（只一次）。
    /// **任何状态 → `running`**：墙上时间钉到现在 —— 锚点的墙上时间只在"扫光真的在跑"期间有效。
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
        // 交错的动画块捕获着 cell —— 不停掉的话，view 没了它还会跑完那一趟。
        for animator in cascadeAnimators { animator.stopAnimation(true) }
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

        trackID = newTrackID
        lines = newLines
        currentIndex = newIndex

        if songChanged || linesChanged {
            rebuildList()
            return
        }

        // 🔴 **换行不重配 cell**：行高跟当前行无关，而缩放 / 明暗 / 逐字层由
        // `scrollToActiveLine` → `startCascade` 的动画带走（`setCascadeOffset` → `endTransition`）。
        // 重配会重建 cell ⇒ 过渡没有起点，就退化成"直接变"了。
        // 这里只掐掉上一趟：新的马上开始，旧参数不该再被读到。
        cancelCascade()
        scrollToActiveLine(animated: true)
        // 新的当前行**单独装一次**逐字层 —— 不跟缩放/明暗一起动画（mask 没有可插值的量）。
        // ⚠️ 必须在滚动之后：跳远时这一格可能是刚滚进来的，那时才存在（不存在也没关系，
        //    `cellForItemAt` 的 `show(...)` 会装）。
        installKaraokeOnCurrentLine()
        refreshKaraoke()
    }

    /// 整表按当前 `lines` 重铺。
    ///
    /// 🔴 **这里不写 `contentOffset`**：滚动位置只有一个写者（`scrollToActiveLine`）。
    /// 之前"重建时直接写一次 offset、跟行时又 `setContentOffset` 一次"，
    /// 上一首最后一句在飞的动画会把"回顶"覆盖掉 —— 而新歌还没到第一句（`currentIndex == nil`）
    /// 时没有任何一步会再摆一次，于是停在末尾。
    private func rebuildList() {
        userScrolling = false
        cancelFollowTimer()
        // 换歌 / 换行表：上一首那趟交错的位移对新行表没有意义，整批掐掉再重铺。
        cancelCascade()
        emptyView.isHidden = !lines.isEmpty
        isScrollEnabled = !lines.isEmpty
        // 换词后布局缓存必须丢：行数 / 内容都变了，同一 indexPath 会沿用上一首的尺寸。
        linesLayout.invalidateLayout()
        reloadData()
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
        // 布局完成后再摆位置：尺寸都定了，目标才算得准。
        scrollToActiveLine(animated: false)
        refreshKaraoke()
    }

    /// 播放器被**主动操作**过（拖进度条、点行跳转）—— 立刻恢复跟唱，不等那 2.5 秒。
    func resumeFollowing() {
        userScrolling = false
        cancelFollowTimer()
        scrollToActiveLine(animated: true)
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
            // 🔴 锚点的**墙上时间**只在扫光真的在跑的时候有效 ⇒ 凡是**进** `running`，
            //    不管从 `frozen` 还是 `idle`，都得钉到此刻。
            //
            // ⚠️ 只钉 `frozen → running` 是「点播放先亮一小块、然后重扫」的病根：
            //    歌在开头（还没到第一句）时 `currentIndex` 是 nil ⇒ 状态是 `idle` 而不是
            //    `frozen`；引擎装载那几百毫秒里状态一直 `idle`，锚点停在点播放那一刻。
            //    进 `running` 不钉 ⇒ 拿几百毫秒前的锚点外推，封顶 `maximumFrameAdvance`
            //    （0.22 秒）⇒ 先亮出一小块；真实读数一到，扫光跳回行首重扫。
            if appliedKaraokeRunState != .running, let anchor = karaokeAnchor {
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
            // 🔴 **只停表，不碰 cell** —— "看不见"不等于"没有"。
            //
            // 逐字数据：**装**归 `installKaraokeOnCurrentLine()`（换行时给新的当前行装一次）；
            // **拆**归 `LyricsLineCell.show(...)`（这一格要装新内容）和 `prepareForReuse`（复用）。
            // **换行时一律不拆** —— 摘掉 mask 会让顶字整行显示，淡出就成了"整行亮一下"。
            // 这里再去清一次，还会把"切走再切回"的数据也清了 —— 回来时 `renderKaraoke`
            // 拿不到 segments，只能等下一句 `show` 才亮。
            stopKaraokeLink()
        }
        appliedKaraokeRunState = state
    }

    /// 实时算一遍"这一帧该不该跑" —— 判据全在纯函数里（`KaraokeSweepPolicy.runState`）。
    private func karaokeRunState() -> KaraokeSweepPolicy.RunState {
        guard let index = currentIndex, lines.indices.contains(index) else { return .idle }
        return KaraokeSweepPolicy.runState(
            isCurrentLine: true,
            // 🔴 有**字**才算 K 歌：数组末项可能是句尾那一格（`text` 空，`isLineEnd`），
            // 拿 `isEmpty` 判会把"只有句尾"的行也当成有逐字，白起一张每帧的空表。
            hasKaraoke: (lines[index].syllables ?? []).contains { !$0.isLineEnd },
            isActuallyPlaying: isActuallyPlaying,
            isOnScreen: window != nil && !isHidden
        )
    }

    /// 当前那一行的 cell —— ⚠️ **每帧现取、不缓存**：cell 会被复用来复用去，存引用迟早指着别人。
    /// 那一行不在屏上就返回 `nil`（不喂时间就行，不是错误）。
    private func currentLyricsCell() -> LyricsLineCell? {
        guard let index = currentIndex, lines.indices.contains(index) else { return nil }
        return cellForItem(at: IndexPath(item: index, section: 0)) as? LyricsLineCell
    }

    /// 换行时给**新的当前行**装逐字层。
    ///
    /// 🔴 **只装、不拆** —— 变成普通行的那些格子身上那一层要留着。摘掉 mask 会让顶字
    /// 整行显示，淡出时看到的就是「整行纯白再淡掉」，而不是「原来亮到哪儿就从哪儿淡」。
    /// 拆下归 `LyricsLineCell.show(...)`（这一格要装新内容了）和 `prepareForReuse`。
    ///
    /// 之所以不能塞进 `startCascadeAnimation`：那条路只在**交错滚动**里跑，而跳远 / 手滑接上
    /// 走的是 `startCascade` 收尾那段独立过渡，那时新的当前行照样得装上。
    private func installKaraokeOnCurrentLine() {
        currentLyricsCell()?.installKaraokeLayer()
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

        // ⚠️ **只画当前行。** 曾经试过"让旧行在淡出期间继续按时间扫"（MeloX 那样），
        // 结果更糟：手动切行时播放时间已经跳到远处，旧行按新时间算就是"已唱完"
        // ⇒ mask 全开 ⇒ **整行亮一下再淡**。旧行保持切走那一刻的 mask 才对。
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
        // 字号 / 对齐一变，每一行的高都变了 —— 上一趟交错的位移对不上新行，先掐掉。
        cancelCascade()
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
        scrollToActiveLine(animated: false)
        // 尺寸一变，每个词的矩形也变 —— 当前行那条要重排一次。
        refreshKaraoke()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 页面刚上屏时尺寸才定下来 —— 第一次 `show` 那会儿还没有窗口，滚不了，这里补一次。
        if window != nil { scrollToActiveLine(animated: false) }
        // 起停判据里有一条"在不在屏上" —— 上屏 / 离屏都要重算（离屏就该停表）。
        refreshKaraoke()
    }

    // MARK: - 跟唱滚动

    /// 把"该看的那一行"滚到「容器高 36%」处。**手滑中不滚**（用户正在看别处，不该被拽回去）。
    ///
    /// 🔴 **目标是全函数**，这是滚动位置唯一的写者：
    /// - 有当前行 ⇒ 滚它；
    /// - 还没有当前行（前奏 / 刚换歌）⇒ 滚首行；
    /// - 行表为空 ⇒ 顶部。
    ///
    /// ⚠️ "没有当前行就什么都不做"是这条 bug 的另一半：新歌从 `currentIndex == nil` 起，
    /// 上一份文档停在末尾 ⇒ 没人摆位置，就一直停在末尾，直到第一句开唱。
    ///
    /// ⚠️ 原来用 `scrollToItem(at: .centeredVertically)` —— 它内部就是「行中心 − 容器高 × 0.5」
    /// 再夹边界。`UIKit` 只给「50%」这一个现成选项，所以这里自己算一遍，
    /// **只把 0.5 换成 `focusFraction`**，夹边界照旧。
    private func scrollToActiveLine(animated: Bool) {
        guard !lines.isEmpty else {
            // 空表也必须有位置：上一份文档的末尾对新文档没有意义。
            cancelCascade()
            setContentOffset(
                CGPoint(x: contentOffset.x, y: -contentInset.top),
                animated: false
            )
            return
        }
        let index = currentIndex.flatMap { lines.indices.contains($0) ? $0 : nil } ?? 0
        guard let attributes = layoutAttributesForItem(at: IndexPath(item: index, section: 0))
        else { return }
        let y = attributes.frame.midY - bounds.height * focusFraction
        let limit = contentSize.height - bounds.height + contentInset.bottom
        let target = CGPoint(
            x: contentOffset.x, y: min(max(y, -contentInset.top), limit)
        )

        // 🔴 **不跟滚的时候照样要过渡**：用户在手滑 / 页面不可见 / 尺寸还没定 ——
        //    位置不能动（动了就是把用户正看的画面拽走），但"哪一行是当前行"已经变了，
        //    大小和明暗得跟过去。目标传**当前** offset ⇒ `delta == 0` ⇒ 自然落到
        //    `startCascade` 里"没有交错"那一路，不需要再单独补一次过渡。
        let canFollow = !userScrolling && window != nil && bounds.height > 0
        startCascade(
            to: canFollow ? target : contentOffset,
            rowSpan: attributes.frame.height + AppMetrics.nowPlayingLyricsLineSpacing,
            animated: animated
        )
    }

    /// 决定这一趟怎么走 —— **滚动 + 过渡的唯一出口**。
    ///
    /// 三件事在这里分开：
    /// 1. **交错还是直滑**：判据只有 `staggers` 一处；
    /// 2. **跳 / 滑**：交给 `runCascade` 或 `setContentOffset`；
    /// 3. **过渡**：没有交错带的时候，`settleVisibleCells(animated:)` 单独给一段。
    ///
    /// - Parameters:
    ///   - target: 已经夹过边界的目偏移。
    ///   - rowSpan: 一行的跨距（行高 ＋ 行距）—— 用来判断这一趟到底是不是「换一行」。
    ///   - animated: 这一趟该不该有动画。初次布局 / 换歌重铺传 `false`
    ///     （`rebuildList` 已经把每格摆成终态，不该再动一次）。
    private func startCascade(to target: CGPoint, rowSpan: CGFloat, animated: Bool) {
        cancelCascade()
        let delta = target.y - contentOffset.y
        // 🔴 **"这一趟有没有交错"只判一次**：
        //    · 不是换行那一趟（`animated == false`）、交错开关关着；
        //    · 位移小到看不见（不跟滚时 `delta` 就是 0）；
        //    · 位移超过一行半（拖进度条、手滑后自己接上、点远处那一行）—— 那种 delta
        //      是几百点，归零过程会把整屏字推到屏幕外再飞回来 —— 不是交错，是事故。
        let staggers = animated && isStaggeredScrollEnabled
            && abs(delta) > 1 && abs(delta) <= max(rowSpan, 1) * 1.5

        if staggers, runCascade(to: target, delta: delta) { return }

        // 没有交错（或者跳完发现屏上只有一行）⇒ 直滑过去，单独给一段过渡。
        // ⚠️ `runCascade` 返回 `false` 时位置**已经跳好**了，这里不会重复动。
        // 🔴 `delta` 为 0 时**一个字都不碰 offset**：不跟滚的那条路（用户手滑中 /
        //    页面不可见）传进来的就是当前 offset —— 手滑中调 `setContentOffset`
        //    会打断他的拖拽。
        if abs(delta) > 0.5 {
            setContentOffset(target, animated: animated)
        }
        settleVisibleCells(animated: animated)
    }

    /// 定位线上那一行 —— **跳之前**问它，问到的才是「离开的那一句」。
    ///
    /// 🔴 **不用 `indexPathForItem(at:)`**：行与行之间有 12 点间距，定位线正好落在缝里时
    /// 它返回 `nil`（约四分之一的机会）—— 起点行就会时有时无，交错跟着忽有忽无。
    /// 这里取「顶边在定位线**及以上**、且最靠下的那一行」：落在缝里就落到上面那一行。
    ///
    /// ⚠️ 比的是 cell 的 `frame`（内容坐标系），跟 `contentOffset` 同一套。
    private func focusLineIndex() -> Int? {
        guard bounds.height > 0 else { return nil }
        let focusY = contentOffset.y + bounds.height * focusFraction
        var best: (index: Int, minY: CGFloat)?
        for case let cell as LyricsLineCell in subviews {
            guard let index = indexPath(for: cell)?.item else { continue }
            let minY = cell.frame.minY
            guard minY <= focusY, minY >= (best?.minY ?? -CGFloat.greatestFiniteMagnitude)
            else { continue }
            best = (index, minY)
        }
        return best?.index
    }

    /// 起一趟交错：**瞬间跳到新位置，然后每行按各自的时刻表滑回来**。
    ///
    /// 为什么必须跳：`contentOffset` 一变，所有行是一起动的 —— 想让某一行晚到，只能让它
    /// 在一段时间里**多偏一段**，再慢慢归零。跳是"把整块内容先放到终点"，
    /// 归零是"把每行从它原来的位置送回终点"。
    ///
    /// 🔴 **参数全部由 `CascadeRun` 算，格子不自己记时间**：这一趟的 delta / 起点行 /
    /// 每档延迟 / 每行时长都只有一份。参与者就是下面那个 `subviews` 快照 ——
    /// 那一刻之后出生的格子属于下一趟，不归这一趟管。
    ///
    /// 🔴 **起点行要在跳之前取**，这是这一趟唯一"过期不候"的东西，所以它在函数第一行。
    ///
    /// - Returns: `false` ＝ 跳完之后发现**没有错开的余地**（屏上只有一行）。
    ///   位置已经跳好了，调用点只差补一段过渡。
    private func runCascade(to target: CGPoint, delta: CGFloat) -> Bool {
        // ① 起点行 —— **必须在跳之前取**：跳完定位线上就是新那一句了，
        //    「离开的那一句」已经不在原位，取不回来了。
        let departing = focusLineIndex()

        // ② 跳到位（无动画）。
        setContentOffset(target, animated: false)
        // ⚠️ **先标脏、再排**：`setContentOffset` 不保证把布局标脏，光 `layoutIfNeeded()`
        //    可能一次都不排 —— 那样视图树还是跳之前那一批。
        setNeedsLayout()
        layoutIfNeeded()

        // ③ 这一趟覆盖哪一段下标。
        let indices = subviews.compactMap { view -> Int? in
            guard let cell = view as? LyricsLineCell else { return nil }
            return indexPath(for: cell)?.item
        }
        guard let lowest = indices.min(), let highest = indices.max(), indices.count > 1
        else { return false }

        // ④ 起点行夹进这一趟的范围。
        //    🔴 拿不到就退回**运动方向前端**（`lowest` / `highest`）—— 那是老行为。
        //       不退回「当前行」：当前行是跳**之后**才成立的那个，拿它当起点等于整趟没基准。
        let front = delta > 0 ? lowest : highest
        let origin = min(max(departing ?? front, lowest), highest)

        // ⑤ 记下这一趟的参数，然后让每格照着跑。
        // ⚠️ 时基必须是 CA 那一套：`UIViewPropertyAnimator` 的 `delayFactor` 是按
        //    "这一段动画自己的时长"算的，我们只是把"还剩多久"喂给它，所以 `now`
        //    和它同源才不会差一帧。
        // 🔴 **整批共用一个 `now`**：循环里各取一次的话，最后几行的 `elapsed`
        //    会比第一行大几十微秒 —— 一趟就不再是"一个起点基准"，而是"一串基准"了。
        let now = CACurrentMediaTime()
        cascadeRun = CascadeRun(
            delta: delta,
            travel: AppMetrics.nowPlayingLyricsCascadeTravel,
            forwardStep: AppMetrics.nowPlayingLyricsCascadePerLine,
            backwardStep: AppMetrics.nowPlayingLyricsCascadeBackStep,
            origin: origin,
            startedAt: now
        )

        for case let cell as LyricsLineCell in subviews {
            guard let index = indexPath(for: cell)?.item else { continue }
            startCascadeAnimation(for: cell, at: index, now: now)
        }
        return true
    }

    /// 让这一格照着这一趟的参数跑 —— **起动画只有这一处**。
    ///
    /// 起点永远是「跳之前的位置」（`delta`），终点永远是 0；每行都走满 `travel`，
    /// 只是起步时刻按 `delays` 依次错开。快照之后才出生的格子走同一个函数，
    /// 拿到的是**这一趟剩下的那一段**（`CascadeRun.schedule`）。
    ///
    /// 🔴 **缩放和明暗也在这个动画器里**（`endTransition`），不是另起一个 ——
    /// 它们动的是同一个 `scaledContainer.transform`，两个动画器会互相打断。
    /// 放进同一个块之后，位移、缩放、透明度三件事由**一条曲线**推着走。
    ///
    /// - Parameter now: 判定"这一趟已经过去多久"用的时刻。同一批必须传同一个值。
    private func startCascadeAnimation(
        for cell: LyricsLineCell, at index: Int, now: CFTimeInterval = CACurrentMediaTime()
    ) {
        let isCurrent = index == currentIndex
        guard let run = cascadeRun, let plan = run.schedule(for: index, now: now) else {
            // 没有交错在跑、或者这一趟对它已经走完 ⇒ 这一格直接站在终点。
            // ⚠️ 这一句**不是兜底**：复用的 cell 身上可能还带着上一趟的位移，
            //    不归零它就停在那儿；而且换行那两行的缩放/明暗也得有人给。
            cell.endTransition(isCurrent: isCurrent)
            return
        }

        // 起点：把这一格摆回"跳之前"的位置。`setCascadeOffset` **只动位移** ——
        // 缩放 / 明暗 / 逐字层都还是旧值，那些正是下面这个动画要推走的东西。
        UIView.performWithoutAnimation { cell.setCascadeOffset(run.delta) }

        // 🔴 `UIViewPropertyAnimator` 的 `duration` 是**整段**（含延迟），`delayFactor`
        //    是延迟**占整段的比例** —— 所以整段 = 等 ＋ 走，比例 = 等 ÷ 整段。
        //    写成「duration 只给走的部分」就会少走一段，字停在半路。
        let span = plan.delay + plan.duration
        let animator = UIViewPropertyAnimator(duration: span, curve: .easeOut)
        animator.addAnimations(
            { cell.endTransition(isCurrent: isCurrent) },
            delayFactor: CGFloat(plan.delay / span)
        )
        animator.startAnimation()
        cascadeAnimators.append(animator)
    }

    /// 把这一趟交错**整批掐掉**，所有行归位。
    ///
    /// 🔴 `stopAnimation(true)` ＝ 停在当前位置、**不**调完成回调；然后手动把位移清 0。
    /// 用 `stopAnimation(false)` 会走完成回调、动画继续把位移推向终点 —— 手滑时就会看到字
    /// 自己又飘一下。
    ///
    /// ⚠️ **无条件清，不看当前值**：动画跑着的时候 `scaledContainer.transform`（model layer）
    /// 已经是终点 0 了，中间值只在 presentation layer 上 —— 拿它做 `where` 判断会**漏清**，
    /// 字就停在半路。`stopAnimation` 之后 UIKit 把哪一帧写回 model 也不保证，
    /// 所以直接写，不问。
    private func cancelCascade() {
        for animator in cascadeAnimators {
            animator.stopAnimation(true)
        }
        cascadeAnimators.removeAll()
        cascadeRun = nil
        for case let cell as LyricsLineCell in subviews {
            cell.setCascadeOffset(0)
        }
    }

    /// 没有交错可搭时，给可见行一段**独立的短过渡**（缩放 ＋ 明暗）。
    ///
    /// 什么时候没有交错：位移小到看不见、位移超过一行半（拖进度条 / 手滑后自己接上 /
    /// 点远处那一行）、屏上只有一行、开关关着、或者**压根不跟滚**（用户在手滑 /
    /// 页面不可见）。那几种情况下字的大小和明暗照样得换，只是没有"一道波推过去"
    /// 可搭 —— 单独给 0.3 秒，别让它"啪"一下。
    ///
    /// 🔴 **只有 `startCascade` 一个调用点。** 曾经是四个 return 前面各补一次，
    /// 判据散在四处、漏一个就退化成"直接变"。现在"有没有交错"在 `startCascade` 里
    /// 只判一次，这个函数只在它的收尾处调。
    ///
    /// - Parameter animated: `false` ＝ 直接写终态（初次布局 / 换歌重铺，本来就该是瞬间的）。
    ///
    /// ⚠️ `beginFromCurrentState`：这一格可能正停在上一趟的半路上（`cancelCascade` 刚停表），
    /// 从**当前画面**接着走，不从"上一次算出来的起点"跳回去。
    private func settleVisibleCells(animated: Bool) {
        let targets = subviews.compactMap { view -> (cell: LyricsLineCell, isCurrent: Bool)? in
            guard let cell = view as? LyricsLineCell,
                  let index = indexPath(for: cell)?.item else { return nil }
            return (cell, index == currentIndex)
        }
        guard !targets.isEmpty else { return }
        let apply = {
            for target in targets {
                target.cell.endTransition(isCurrent: target.isCurrent)
            }
        }
        guard animated else {
            UIView.performWithoutAnimation(apply)
            return
        }
        UIView.animate(
            withDuration: AppMetrics.nowPlayingLyricsEmphasisDuration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: apply
        )
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
            self.scrollToActiveLine(animated: true)
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
        // 🔴 **快照之后才出生的格子也从这一趟起跑**（最后一句常常是这一种）：
        //    起点仍是「跳之前的位置」，延迟按已过去的时长扣掉 —— 它跟已经在跑的那些行
        //    落在同一个节奏上，不会先站在终点被上面的行压住。
        //    ⚠️ `show(...)` 刚给了终态（它出生时就该是目标大小/明暗），这里再按这一趟的
        //    剩余段补一次位移 —— `startCascadeAnimation` 会先 `setCascadeOffset` 把位移
        //    摆到起点、再动画归零，所以不会跟 `show` 打架。
        startCascadeAnimation(for: cell, at: indexPath.item)
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
        // 🔴 行高**跟"是不是当前行"无关**：大小差别走 cell 里的 `transform`，不动占位。
        // 所以换行不会改变任何一行的高度，列表不用重排。
        let height = LyricsLineCell.height(
            for: lines[indexPath.item],
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
        // 🔴 **手一碰就整批停**：交错中的那几行带着位移，用户一拖就会「跟着手指跑偏」。
        cancelCascade()
        // 🔴 **停表之后必须补一次终态。** `stopAnimation(true)` 会把 model value 同步成
        // **当前的 presentation 值** —— 位移有 `setCascadeOffset(0)` 收，缩放和 `alpha` 没有；
        // 不补的话那一格会**卡在中间亮度**上（淡出被打断就停在半路）。
        // 手滑这条路后面没有新动画（要到松手 `scheduleFollowResume` 才接上），只能在这儿补。
        // ⚠️ 不能用 `animated: true`：手滑时再跑 0.3 秒过渡会跟滚动打架。
        settleVisibleCells(animated: false)
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

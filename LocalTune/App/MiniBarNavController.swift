import RxSwift
import SnapKit
import UIKit

/// 每个 tab 各自的**导航容器** —— 一条导航栈 **＋** 它自己那一条迷你播放条。
///
/// ## 它是一条 `AppNavigationController`
///
/// 导航栏外观**不在这儿设** —— 由基类按「表面档位」给（`宪法.md` §二：导航栏外观的唯一出处
/// 是 `AppNavigationController`）。这一层只**多一条迷你条**，其余跟别的栈一样。
/// 档位**从 `init` 传进来**，不写死在这儿：谁建栈、谁说自己要哪一档。
///
/// ## 为什么要按 tab 拆开（而不是全 App 共用一份）
///
/// 原来底部那一块（材质 + 条子 + 分隔线）是**一份**、挂在标签栏容器上，
/// 位置靠**手算 frame**（每次布局重算、转场中途还强制排一次整棵树）。
/// 那个"手算"必然要在**标签栏正被藏起来/放回来**的那一刻动到整棵树 ——
/// 而那正好是 iOS 26 标签栏**量每个按钮标题宽度**的时机（量错一次就再也不重量，
/// 两个字的标题只剩 `…`，Apple 已记录 `FB24250687`）。
///
/// 现在的做法是：
/// **条子挂在导航容器上、位置全交给约束**，
/// 于是"标签栏显不显示"变成**系统改安全区**这件事，条子跟着约束走 ——
/// 我们在转场里**一行布局都不排**，也就再也踩不到那个时机。
///
/// ## 位置只由**一条约束**决定
///
/// ```
/// view
///  ├─ backdrop（材质层）
///  │    约束：leading/trailing = superview · bottom = superview.bottom
///  │          top = view.safeAreaLayoutGuide.bottom − 条高     ← 唯一一条"位置"约束
///  │    contentView
///  │         ├─ 迷你条（top/leading/trailing 贴 contentView 顶）
///  │         └─ 发丝分隔线（贴条子下沿）
///  └─ 导航栈自己
/// ```
///
/// - 标签栏**在**：导航容器的安全区下沿 = 标签栏上沿 ⇒ 条子坐在标签栏上面。
/// - 标签栏**藏**：安全区下沿退到 home indicator 上沿 ⇒ 条子跟着落下去。
///
/// ⚠️🔴 **绝不能把"让位那 60"写进这个导航容器自己** —— 那会把容器自身的
/// `safeAreaLayoutGuide` 撑高，上面那条约束跟着往上跑，条子整体高出一截。
/// 让位一律写**页面**（见 `applyBottomInset(to:)`）。
///
/// ## 显隐：一处**有意偏离**
///
/// 多选时我们藏**整块**材质（另一种做法是只藏条子、标签栏照旧在）——
/// 因为实测过"只藏条子"时，铺到屏幕底的材质层会把**系统工具条盖住**
/// （见 `MiniBarHosting`）。这一处偏离是**故意保留**的（用户确认）。
///
/// ## 线程
///
/// **全在主线程**：这个容器由装配层在主线程上建；它订阅的那两条流（`PlayManager.state` /
/// `PlayManager.position`）也在主线程上推（见 `PlayManager` 文件头那节「线程」）。
/// ⇒ 这里所有改 UI 的动作**都不用跳线程**，也没有第二个线程碰这些视图。
final class MiniBarNavController: AppNavigationController {

    // MARK: - 底部那一块

    /// 材质层 —— 条子和标签栏共用的那块玻璃。铺「条子顶 → 屏幕底」。
    ///
    /// 🔴 **档位**：浅色 `.light`、深色 `.dark`
    /// （`traitCollectionDidChange` 里跟着外观换）。结构仍是「导航容器一整块、标签栏透明透出来」，
    /// 只是模糊味道要对齐。
    /// ⚠️ 别给它设 `backgroundColor`，一设就把模糊盖住了。
    private let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .light))

    /// 条子和标签栏之间那条发丝线 —— 它是"条子下沿"那条界线。
    private let separator = UIView()

    /// 底部那条迷你播放条。**纯显示** —— 它那几样依赖（取封面 + 四个回调）
    /// 由装配层交到这儿、在 `init` 里**原样转给它**，容器自己不留第二份。
    private let miniBar: MiniPlayerBar

    // MARK: - 依赖

    /// 播放器 —— 条子从它拿状态。**只有它知道播放器**。
    private let playManager: PlayManager

    /// 订阅都往这儿扔。容器活整个 App 生命周期，所以一辈子不退订 —— 集中放着便于看清。
    private let disposeBag = DisposeBag()

    // MARK: - 建立

    /// 装配层把**条子要的东西一次给齐**：
    /// 播放器、取封面的动作、四个动作 —— 容器在下面**原样转给条子**，自己不留一份。
    ///
    /// 🔴 这个类**不认识 `AppRouter`**：它只说"有人点了条子 / 播放键 / 下一首 / 上一首（滑动）"，
    /// 至于点了以后跳去哪，是装配层的事（跳转只能从 Router 出去）。
    ///
    /// ⚠️ `surface` **必须给**（没有默认值）：导航栏外观归基类，这一层不设 —— 不给就编译不过，
    /// 漏不了。至于该给哪一档，是**建栈的人**（`MainTabBarController`）的事。
    init(
        playManager: PlayManager,
        // ⚠️ `@escaping` **必须写**：`ArtworkProvider` 是个 typealias，底下是**函数类型**。
        artworkProvider: @escaping ArtworkProvider,
        rootViewController: UIViewController,
        surface: NavigationSurface,
        onTapMiniBar: @escaping () -> Void,
        onTogglePlayPause: @escaping () -> Void,
        onPlayNext: @escaping () -> Void,
        onPlayPrevious: @escaping () -> Void
    ) {
        self.playManager = playManager
        self.miniBar = MiniPlayerBar(
            artworkProvider: artworkProvider,
            onTap: onTapMiniBar,
            onPlayPause: onTogglePlayPause,
            onNext: onPlayNext,
            onPrevious: onPlayPrevious
        )
        super.init(rootViewController: rootViewController, surface: surface)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installMiniBar()
        bindMiniBar()
        // ⚠️ **根页面不给让位**。
        //
        // 给页面设底边距只有两处：`pushViewController` 里给**被推的那一页**设 60、
        // 条子显隐时给**栈顶那页**设 60 / 0。建根页面那一步（`initWithRootViewController:`）
        // 只建条子、**根页面从头到尾一次都没被设过**。
        //
        // ⇒ 根页滚到最底时，最后一截内容（含底部那行统计）会落在**条子底下** ——
        //    同样如此（表格也是"四边贴满"、底部统计也是 45 高的
        //    `tableFooterView`，结构跟我们一样）。
        //
        // 下面这行是**备用写法**，已按代码标准 4 登记进
        // `架构与目录规范.md` 的「已知备用代码清单」——**现在没人调它**：
        //     applyBottomInset(to: topViewController)
        // 只在实机验出"根页最后一行 / 统计条被压住"时才放开；用或不用，结论一出就删这一行。
    }

    /// 深浅切换时换玻璃档位 —— `traitCollectionDidChange` 里做的事。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        backdrop.effect = UIBlurEffect(style: Self.blurStyle(for: traitCollection))
    }

    /// 深色 `.dark`，其余 `.light`。
    private static func blurStyle(for traits: UITraitCollection) -> UIBlurEffect.Style {
        traits.userInterfaceStyle == .dark ? .dark : .light
    }

    // MARK: - 进 / 退二级页

    /// 推一页进来 —— 只做两件：藏标签栏、给新页让位。
    ///
    /// ⚠️ **这个重写里不排任何布局** —— 那是原来那套手算的根源（见类顶上的说明）。
    /// 条子的位置由约束和系统改安全区自己解决。
    ///
    /// ⚠️ **分隔线也不在这儿动** —— 它归下面的转场代理，由那一次转场带着淡（见文件末尾）。
    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        // ① 藏标签栏：**必须在 `super` 之前设** —— 这个开关是给**转场**用的，
        //    转场一开始系统就把"要不要藏标签栏"决定完了，晚了设不生效（实机验过）。
        //    ⚠️ 根页面不走这儿（它是 `init` 给的），所以标签栏照常显示。
        if !viewControllers.isEmpty {
            viewController.hidesBottomBarWhenPushed = true
        }

        // ② 给**被推的这一页**让位（不是给容器、更不是给导航控制器自己 —— 见类顶上那个坑）。
        //    ⚠️ **条子正藏着就不设**（先看"条子藏没藏"）——
        //    条子根本没露，让位那一格就不该留，留着只会在页面底部多出一块空白。
        if !isMiniBarHidden {
            applyBottomInset(to: viewController)
        }

        super.pushViewController(viewController, animated: animated)
    }

    /// ⚠️ **没有重写 `popViewController`** —— 分隔线的显隐交给下面的代理管，
    /// 那一条能覆盖 push / pop / **边缘滑动手势** / 回根页**全部路径**，
    /// 而重写 `popViewController` 会漏掉手势和 `popToRoot`（原来那套就踩过这个洞）。

    // MARK: - 让位

    /// 条子（连同它底下那层材质）此刻是不是藏着的。
    ///
    /// 🔴 **让位要不要设，就看这一个值** —— 别再另写一套判据。
    /// 判的是"条子自己藏没藏"；我们藏的是**整块材质**（条子在里面），
    /// 所以对的是 `backdrop.isHidden`（同一个开关，见 `setBottomBlockHidden`）。
    private var isMiniBarHidden: Bool { backdrop.isHidden }

    /// 把**条子那么高**的底边距让给**页面**。
    ///
    /// 🔴 **只能写给页面**：写给导航容器自己会把容器自身的安全区撑高，
    /// 条子那条约束就整体偏高一截（类顶上那个坑）。
    ///
    /// 值必须和"条子多高"**同源**（同一个令牌），不然会让多或让少。
    private func applyBottomInset(to page: UIViewController?) {
        guard let page else { return }
        let inset = AppMetrics.miniPlayerBarHeight
        // 先读再写：读回来是对的就不写 —— 免得白让那一页重排一遍。
        guard page.additionalSafeAreaInsets.bottom != inset else { return }
        page.additionalSafeAreaInsets.bottom = inset
    }

    // MARK: - 装配

    /// 把底部那一块拼起来 —— 只在 `viewDidLoad` 里调一次。
    private func installMiniBar() {
        // 进屏时按当前外观定档（属性初值只是 `.light` 占位，深色模式第一次装时要立刻换成 `.dark`）。
        backdrop.effect = UIBlurEffect(style: Self.blurStyle(for: traitCollection))

        // 加在最上层：它只在屏幕底部那一带，不会挡导航栏。
        // ⚠️ 它**压在导航栈的内容之上**（这是"条子浮在列表上方"的前提），
        //    又**压在标签栏之下**（标签栏是标签栏容器的子视图，比这个容器更靠上）。
        view.addSubview(backdrop)

        // 顶部那道阴影加在**整层玻璃**上，不是加在条子上。
        // 🔴 它是"一整块"（条子顶边 → 屏幕底），顶边和条子的顶边是同一条线
        //    ⇒ 影子落在顶边上方，左右和下方都落在屏幕外。
        // ⚠️ `masksToBounds` 必须是 `false`（`UIView` 默认就是，显式写因为它是这个效果的前提）。
        let backdropLayer = backdrop.layer
        backdropLayer.shadowColor = AppColor.shadow.cgColor
        backdropLayer.shadowOpacity = AppMetrics.miniPlayerShadowOpacity
        backdropLayer.shadowOffset = CGSize(width: 0, height: AppMetrics.miniPlayerShadowVerticalOffset)
        backdropLayer.shadowRadius = AppMetrics.miniPlayerShadowRadius
        backdropLayer.masksToBounds = false

        // 条子和分隔线装进**材质层的内容视图** —— 加在 `contentView` 里的子视图不会被模糊。
        // ⚠️ 别加到 `backdrop` 自己身上，那样里面的东西会被一起糊掉。
        backdrop.contentView.addSubview(miniBar)
        backdrop.contentView.addSubview(separator)

        separator.backgroundColor = AppColor.separator
        separator.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(miniBar.snp.bottom)
            make.height.equalTo(AppMetrics.miniPlayerSeparatorHeight)
        }

        // 🔴 **唯一一条"位置"约束** —— 条子的顶边就钉在"自身安全区下沿往上 60"。
        //    标签栏显不显示、转场走到哪，都是系统改安全区，条子跟着走。
        backdrop.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.top.equalTo(view.safeAreaLayoutGuide.snp.bottom)
                .offset(-AppMetrics.miniPlayerBarHeight)
        }

        // 条子贴材质层顶边；高度由条子自己带着（见 `MiniPlayerBar.buildSubviews`），
        // 两处都设会打架。
        miniBar.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
        }

        // ⚠️ 条子那几根线**不在这儿接** —— 它的依赖在 `init` 里就转过去了（见 `init`）。
        //    留一步"事后接线"就等于留一个"漏接也不出声"的口子。

        // 转场里的分隔线显隐要看栈 —— 走代理能覆盖 push / pop / **边缘滑手势** / 回根页**全部路径**。
        delegate = self
    }

    /// 「谁在播」一变，就把条子上的歌名 / 封面 / 播放态 / 两侧预览换成真的。
    /// 进度另订一条 —— 10Hz，不进 Content。
    ///
    /// ⚠️ **"翻译"那一步不在这儿** —— 它归同层的 `MiniPlayerContent`。
    /// 预览的 peek 跟 `playPrevious` / `playNext` 同一口，在翻译里拼进 Content。
    private func bindMiniBar() {
        playManager.state
            .map { [playManager] state in
                MiniPlayerContent.from(
                    state,
                    previous: playManager.peekPreviousTrack(),
                    next: playManager.peekNextTrack()
                )
            }
            .distinctUntilChanged()
            .subscribe(onNext: { [weak self] content in
                self?.miniBar.show(content)
            })
            .disposed(by: disposeBag)

        Observable.combineLatest(playManager.state, playManager.position)
            .map { MiniPlayerContent.progress(from: $0, elapsed: $1) }
            .distinctUntilChanged()
            .subscribe(onNext: { [weak self] progress in
                self?.miniBar.show(progress)
            })
            .disposed(by: disposeBag)
    }

    // MARK: - 分隔线

    /// 分隔线**此刻该露还是该藏** —— 全类只有这一条判据。
    ///
    /// 「该露」只有一个条件：**停的是栈底那一页**。进了二级页标签栏就让开了，
    /// 那条线标的是"条子和标签栏之间的界线"，留着只是悬在半空。
    ///
    /// - Parameter destination: 转场**要去的那一页**；不传就问"现在栈顶是谁"。
    ///   ⚠️ 转场刚开始时必须传 —— 边缘滑手势开始的那一刻栈还没变，问栈顶会判反。
    private func separatorShouldBeVisible(considering destination: UIViewController? = nil) -> Bool {
        (destination ?? topViewController) === viewControllers.first
    }

    /// 把分隔线调到该在的样子。**值已经对了就什么都不做**（转场回调可能落好几次）。
    private func setSeparatorVisible(_ visible: Bool, animated: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard separator.alpha != target else { return }
        guard animated else {
            separator.alpha = target
            return
        }
        UIView.animate(withDuration: AppMetrics.miniPlayerSeparatorFadeDuration) { [weak self] in
            self?.separator.alpha = target
        }
    }
}

// MARK: - 转场里的分隔线

extension MiniBarNavController: UINavigationControllerDelegate {

    /// 转场**开始**时按"要去的那一页"把分隔线调到位 —— 跟着转场一起淡，
    /// 不是转场结束才"啪"一下。
    ///
    /// 🔴 **这是分隔线唯一的触发点**：它覆盖 push / pop / **边缘滑动手势** / 回根页**全部路径**。
    /// 所以**不**在 `pushViewController` 里再调一次（push 进去必然走这儿，同一个事件、
    /// 同一条判据写两遍就是"补丁"：《宪法.md》§三·顺序与根因 2）。
    ///
    /// ⚠️ 判据用**"来的这一页是不是栈底"**，不用 `viewControllers.count` ——
    /// 边缘滑手势开始的那一刻栈还没变，数个数会判反。
    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        setSeparatorVisible(
            separatorShouldBeVisible(considering: viewController),
            animated: animated
        )

        // 滑到一半松手 ⇒ 这次转场被**取消**，上面那次判断就不作数了。
        // 转场协调器的收尾回调是 UIKit 给"取消"留的正式出口（`context.isCancelled`）：
        // 收尾时栈已经定下来，这时问栈顶最准。
        _ = transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] context in
            guard context.isCancelled, let self else { return }
            self.setSeparatorVisible(self.separatorShouldBeVisible(), animated: false)
        }
    }
}

// MARK: - 让路

extension MiniBarNavController: MiniBarHosting {

    /// 藏 / 放底部那一整块 —— 进多选时要给系统工具条腾地方。
    ///
    /// 🔴 收的是**材质层**：条子和分隔线都在它的 `contentView` 里，跟着一起不可见。
    /// ⚠️ **只藏条子不够**：材质铺满"条子顶 → 屏幕底"、又压在导航栈内容之上，
    /// 留着它就会把工具条盖住（表现：进了多选看不见工具条）。
    /// ⇒ 这一处**有意偏离**（另一种做法是只藏条子、标签栏照旧在），**用户已确认不跟**。
    /// ⚠️ 跟**让位无关**：那一格照旧让着，不随这个开关收放 ——
    /// 我们**留着**标签栏（见上），让位那 60 正对着工具条那一格，收掉反而会让工具条压住列表最后一行。
    /// （把栈顶页的底边距跟着清零，是因为**标签栏也藏了**、下面腾空了一大片。）
    func setBottomBlockHidden(_ hidden: Bool) {
        backdrop.isHidden = hidden
    }
}

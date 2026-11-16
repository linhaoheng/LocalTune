import RxSwift
import UIKit

/// 页面基类 —— 每个页面都从这里开始。
///
/// 只收「每一页都要做、散着写就一定会漏」的事：
///
/// 1. **页面底色**统一走 `AppColor` —— 页面里不出现系统色。
/// 2. **大标题**的开关。导航栏是整个导航栈共用一条的，所以只能在
///    `viewWillAppear` 里设：从「不要大标题」的那一页返回时，这一页得把
///    大标题要回来。放在 `viewDidLoad` 里只对第一次进页面生效。
/// 3. 左上角放了自定义按钮时，**返回按钮仍然显示**（默认会被顶掉）。
/// 4. **生命周期状态**统一成一个枚举，子类不用自己判断
///    `isViewLoaded && view.window != nil`。
/// 5. **应用前后台**钩子，子类重写就收到通知，不用自己注册；只在页面可见时转发。
///
/// 它**不**决定跳转（那是 `AppRouter`），**不**替页面搭布局，
/// 也**不**管键盘避让 —— 那只有编辑器页用得上，那一页直接用系统的
/// `view.keyboardLayoutGuide` 即可（iOS 15 起就有，本工程最低 iOS 16）。
class BaseViewController: UIViewController {

    /// 页面里所有订阅都往这里扔 —— 页面销毁时一起退订。
    ///
    /// ⚠️ 放进基类是因为**每一页都要用**（曲库页、歌单页、播放页…），每页各声明一个是重复；
    /// 而且**漏扔的订阅会一直活着**：界面都没了，它还在收数据、还攥着 `self`。
    let disposeBag = DisposeBag()

    // MARK: - 页面是否在屏幕上

    /// 页面当前处在哪个阶段。
    enum Lifecycle: Equatable {
        /// 还没调过 `viewDidLoad`。
        case notLoaded
        /// `viewDidLoad` 调过了，但**当前不在屏幕上**。
        ///
        /// 它同时覆盖「还没出现过」和「出现过又退出了」两种情况 —— 这是**故意**的：
        /// 唯一要用它判断的就是「在不在屏幕上」（看 `isVisible`），
        /// 硬拆成两个值，反而是留一个没人用的状态。
        case loaded
        /// 在 `viewWillAppear` 和 `viewDidAppear` 之间。
        case willAppear
        /// 在 `viewDidAppear` 和 `viewWillDisappear` 之间。
        case appeared
        /// 在 `viewWillDisappear` 和 `viewDidDisappear` 之间。
        case willDisappear

        /// 页面是否在屏幕上可见。
        var isVisible: Bool {
            switch self {
            case .willAppear, .appeared, .willDisappear: true
            case .notLoaded, .loaded: false
            }
        }
    }

    /// 当前生命周期阶段。
    private(set) var lifecycle: Lifecycle = .notLoaded

    // MARK: - 大标题

    /// 本页要不要大标题。
    ///
    /// 🔴 **这是整条导航栈共用的总闸**（它写的是 `navigationBar.prefersLargeTitles`，栏子是全栈一份），
    /// 而且是在 `viewWillAppear`（**转场已经开始之后**）才写进去的 ——
    /// 在这一刻把它关掉，等于把正在做收缩动画的大标题当场塌掉：从上一页进来会看到
    /// "大标题停一下、然后消失"。
    /// ⇒ **要"本页不要大标题"就别动它**，只设 `largeTitleDisplayMode = .never`；
    /// 总闸只在**弹出的页面**（没有大标题过渡那种）上关。
    var prefersLargeTitles = true

    /// 大标题在本页怎么显示。
    var largeTitleDisplayMode: UINavigationItem.LargeTitleDisplayMode = .automatic

    // MARK: - 应用前后台钩子
    //
    // 🔴 这四条是**给子类重写的空钩子**，里面永远不放公共动作 ——
    // 公共动作一律留在下面私有区那四个「收到通知」的方法里。
    //
    // 为什么：原先「刷新状态栏」写在 `appDidBecomeActive()` 里，靠注释要求
    // 「子类重写必须调 super」来保证 —— 那是靠人记着，不是靠代码。
    // 挪进私有区之后，子类**既偷不走也忘不掉**，注释里那句要求也就可以删了。

    /// App 即将进入前台。
    func appWillEnterForeground() {}

    /// App 已经变为活跃。
    func appDidBecomeActive() {}

    /// App 即将失去活跃。
    func appWillResignActive() {}

    /// App 已经进入后台。
    func appDidEnterBackground() {}

    // MARK: - 页面生命周期回调

    override func viewDidLoad() {
        super.viewDidLoad()
        lifecycle = .loaded
        view.backgroundColor = AppColor.pageBackground
        navigationItem.leftItemsSupplementBackButton = true
        // ⚠️ 这里原来还有一句 `extendedLayoutIncludesOpaqueBars = true` —— **删掉了**，
        // 栏改回实色之后**也没有加回来**。
        // 它当初是给「**不透明**栏 + 系统搜索框」修的（搜索框激活时列表上方会多出一块空白，
        // rdar://20942583），但**"实色就得加"是推的、没验**：实色 + 有搜索框
        // + 也没这句 ⇒ 先不加，实机看现象。完整来龙去脉在 `AppNavigationController` 的注释里。
        registerAppStateObservers()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lifecycle = .willAppear
        navigationController?.navigationBar.prefersLargeTitles = prefersLargeTitles
        navigationItem.largeTitleDisplayMode = largeTitleDisplayMode
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lifecycle = .appeared
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        lifecycle = .willDisappear
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        lifecycle = .loaded
    }

    // MARK: - 横竖屏

    /// iPhone：播放页和**歌单详情**自己声明 `ControlsWindowOrientation`；其余竖屏。
    /// iPad：四个方向都能转。
    ///
    /// 播放页 / 歌单详情自己覆写；窗口那一问在 `AppDelegate`（present 出来的页不在 Tab 的 selected 里）。
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    // MARK: - 底部那一块的宿主

    /// 底部那一块的宿主 —— 页面要它让路时从这儿说。
    ///
    /// 页面只写 `bottomBlockHost?.setBottomBlockHidden(true)`：**藏**是页面的事；
    /// 它藏在哪、怎么藏、让位怎么办，都是宿主的事（见 `MiniBarHosting`）。
    /// 页面**一个字都不提**宿主是谁 —— 这就是"每一件事只有一个地方知道"。
    ///
    /// ⚠️ 宿主是**这一页所在的那个导航容器**（`MiniBarNavController`，条子就住在它里面），
    /// 所以顺 `parent` 链往上找**最近的一个** `MiniBarHosting`。
    ///
    /// 🔴 **不写死宿主的类型**：页面只认协议 —— 谁实现了它、住在上面几层，都不关页面的事。
    /// （这里原来写的是 `tabBarController as? MiniBarHosting`，那是"宿主是标签栏容器"那个结构；
    /// 条子搬进每个 tab 的导航容器之后，那一句就再也找不着宿主了。）
    var bottomBlockHost: MiniBarHosting? {
        var candidate = parent
        while let current = candidate {
            if let host = current as? MiniBarHosting { return host }
            candidate = current.parent
        }
        return nil
    }

    // MARK: - 私有 · 应用前后台通知

    /// 注册前后台通知。
    ///
    /// **不用在 `deinit` 里手动注销**：iOS 9 起 `NotificationCenter` 对这种 selector 形式的
    /// 观察者是弱引用，对象销毁后自动摘掉 —— 既不留残留也不成环。
    ///
    /// 只注册一次：它只在 `viewDidLoad` 里调用，而那本身只会被调一次。
    private func registerAppStateObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(onAppWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(onAppDidBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(onAppWillResignActive),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(onAppDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func onAppWillEnterForeground() { forwardToVisiblePage(appWillEnterForeground) }

    /// App 变活跃时的**公共动作**留在这儿 —— 见上面「应用前后台钩子」那段的原因说明。
    @objc private func onAppDidBecomeActive() {
        forwardToVisiblePage {
            // 状态栏样式跟着页面走，回到前台重新问一次。
            setNeedsStatusBarAppearanceUpdate()
            appDidBecomeActive()
        }
    }

    @objc private func onAppWillResignActive() { forwardToVisiblePage(appWillResignActive) }
    @objc private func onAppDidEnterBackground() { forwardToVisiblePage(appDidEnterBackground) }

    /// 只在页面**可见**时把系统通知转成钩子。
    ///
    /// 导航栈里看不见的页面不该在后台干活 —— 否则「在播放页按 home」会连带
    /// 让栈里的曲库页也收到一次。
    private func forwardToVisiblePage(_ hook: () -> Void) {
        guard lifecycle.isVisible else { return }
        hook()
    }
}

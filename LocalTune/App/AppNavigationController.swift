import UIKit

/// 「一条导航栈的表面档位」—— 这条栈穿什么皮。
///
/// 🔴 **这件事的唯一真相**：全 App 只有 `AppNavigationController`
/// 按这一档给导航栏外观 —— 页面和 `AppRouter` 都不许自己写 `UINavigationBarAppearance`。
///
/// 四个档位就是全 App 已知的四种皮，**没有第五种**。要加一档，得先在下面把它的长相说清 ——
/// 而不是让某个页面自己写一份色值。
///
/// 🔴 **档位在「建这条栈的地方」声明，页面自己不声明。**
/// 建栈的只有两处：`AppRouter`（各条模态栈）和 `MainTabBarController`（tab 栈）。
/// 页面连这个类型都拿不到 —— 它住在 `App/`，而 `Features/` 不许反向依赖 `App/`
///
/// | 档位 | 谁在用 | 栏 | 栈底色 | 强制深色 | 藏栏 |
/// |---|---|---|---|---|---|
/// | `page` | tab 两条栈 · 歌词编辑页 | 页面底色（slate1） | — | — | — |
/// | `grouped` | 选歌页 · 「添加到播放列表」页 | 系统分组表面 | — | — | — |
/// | `secondary` | 歌曲信息编辑页 · 速度页 · 定时关闭页 | 次级页面底色（slate2）＋ 发丝线 | slate2 | — | — |
/// | `nowPlaying` | 均衡器页 | 播放页那套黑皮 | 黑 | ✅ | ✅ |
///
/// ⚠️ **不是凭空发明的四个名字** —— 每一条都对着一个**已经存在**的栈，
/// 只是原先那些栈各自把同一件事写了一遍（同一时刻全 App 有 5 处写导航栏外观、写出 3 种颜色）。
enum NavigationSurface {
    case page
    case grouped
    case secondary
    case nowPlaying

    // MARK: - 档位 → 长相

    /// 导航栏底色（三个槽位共用）。
    var barBackground: UIColor {
        switch self {
        case .page: return AppColor.pageBackground
        case .grouped: return .systemGroupedBackground
        case .secondary: return AppColor.secondaryPageBackground
        case .nowPlaying: return AppColor.nowPlayingBackground
        }
    }

    /// 导航栏下方那条发丝线；`nil` = 用系统默认（不显式给色）。
    ///
    /// ⚠️ **`page` / `grouped` 必须留 `nil`**：那两条栈现在压根没设过它，
    /// 显式给一个值就**变样了** —— 收口的口径是「一项都不许变」。
    var barShadow: UIColor? {
        switch self {
        case .secondary: return AppColor.separator
        case .page, .grouped, .nowPlaying: return nil
        }
    }

    /// 栈视图自己的底色；`nil` = 不设（沿用 UIKit 默认）。
    ///
    /// ⚠️ 同 `barShadow`：`page` / `grouped` 留 `nil`。
    var stackBackground: UIColor? {
        switch self {
        case .secondary: return AppColor.secondaryPageBackground
        case .nowPlaying: return AppColor.nowPlayingBackground
        case .page, .grouped: return nil
        }
    }

    /// 这条栈的界面外观。
    ///
    /// ⚠️ `nowPlaying` 的 `.dark` **只覆盖这一条栈**，不改窗口的主题档位
    /// （那是 `AppTheme` / `SceneDelegate` 的事）。
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .nowPlaying: return .dark
        case .page, .grouped, .secondary: return .unspecified
        }
    }

    /// 导航栏要不要藏起来。
    ///
    /// `nowPlaying` 那档**自绘顶栏**，不吃系统栏。
    var hidesBar: Bool {
        switch self {
        case .nowPlaying: return true
        case .page, .grouped, .secondary: return false
        }
    }
}

/// 全 App **唯一**的导航栈基类 —— 「一条导航栈长什么样」只有这一个地方知道。
///
/// ## 它收什么、不收什么
///
/// - ✅ **收**：**导航栏外观** —— 按 `NavigationSurface` 档位给。
/// - ❌ **不收**：**模态形态**（`.pageSheet` / `detents` / 小白条）——
///   那是**装配层**的事，归 `AppRouter`。理由：要收的东西里**有不是栈的**
///   （歌词海报页弹的是一个光杆 `UIViewController`），挂在栈上收不全。
///
/// ## 为什么要有它
///
/// 导航栈在工程里有两种来路：
///
/// - **tab 栈**：`MiniBarNavController`（比普通栈多一条迷你播放条）；
/// - **模态栈**：`AppRouter` 里按档位现建的一条。
///
/// 收口**之前**这两种都得各自把导航栏外观重设一遍（同一时刻全 App 有 5 处写它、写出 3 种色）
/// —— 这一层把它收到一处。
///
/// ## 一条规矩
///
/// **「一条导航栈长什么样」只有一个地方知道**。
/// 页面不许再碰 `navigationBar.standardAppearance` / `navigationItem.standardAppearance`。
///
/// ## 为什么栏是「不透明实色」
///
/// 半透明的导航栏会让**大标题那一截**系统补错：内容的上边缘在「导航栏 + 大标题」下面，
/// 滚动条却只按「导航栏」算，**顶端就比列表内容高一截**；设成不透明之后页面从栏下面开始，
/// 两边自然对齐，**滚动条一行代码都不用写**
/// （别去设 `verticalScrollIndicatorInsets`，那是在跟系统抢这件事）。
///
/// 色值也照这个来：**栏色取它下面那张列表的底色** —— `page` 档就是页面底色
/// （`AppColor.pageBackground`，页面自己在 `BaseViewController.viewDidLoad` 里也设同一个色）
/// ⇒ 栏和页面、列表**同一个色，看不出分界**。
///
/// ⚠️ 试过一版**毛玻璃**（`configureWithDefaultBackground()`，已实机验过），
/// 后来**改回实色**。
///
/// ⚠️ `extendedLayoutIncludesOpaqueBars` —— **现在没有加**：
/// `BaseViewController.viewDidLoad` 里曾经有一句 `extendedLayoutIncludesOpaqueBars = true`，
/// 说是给「**不透明**栏 + 系统 `UISearchController`」修的：那种组合下点搜索框，系统会把
/// **大标题那一截**也算进去，于是搜索框和第一行之间露出一块空白（`rdar://20942583`）。
/// 改毛玻璃时删掉了。
///
/// ⚠️ **「实色就必须加回来」是当初推的、没验过** —— 手上没有任何一处证明
/// 「实色 + 有搜索框」非它不可。⇒ 改回实色**先不加**，实机看有没有那块空白；
/// 真出来了再加（就一行）。
///
/// ## 线程
///
/// **全在主线程**：建栈、改导航栏全是 UIKit 的事，
/// 调用方（`AppRouter` / `MainTabBarController`）也都在主线程上建它。
/// 这里没有任何后台线程会碰的成员，也就没有需要保护的共享状态。
class AppNavigationController: UINavigationController {

    /// 这条栈穿哪一档皮。**建完不再变** —— 换皮得换一条栈。
    private let surface: NavigationSurface

    // MARK: - 建立

    /// 建一条**穿指定皮**的栈。
    ///
    /// 🔴 **这是唯一的指定构造器**：`UINavigationController.init(rootViewController:)` 故意
    /// **不重写** —— 于是每一条栈都得说清自己穿哪一档皮，没有「忘了说」这条默认路。
    init(rootViewController: UIViewController, surface: NavigationSurface) {
        self.surface = surface
        super.init(rootViewController: rootViewController)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 穿皮

    /// 🔴 **穿皮放在 `viewDidLoad`，不放在 `init`** —— 这不是随手挑的时机。
    ///
    /// `init` 里只要碰一下 `view` 或 `navigationBar`，UIKit 就会**当场把视图装起来**；
    /// 而视图提前装好，子类 `viewDidLoad` 里那些「按当前外观定档」的初始化
    /// （例：`MiniBarNavController` 按 trait 挑毛玻璃档位）就会拿到一个
    /// **还没进窗口**的 trait 集合 —— 那个永远是浅色。
    /// 放在这儿，装视图的时机跟「不加这一层」**一模一样**，谁也不受影响。
    ///
    /// ⚠️ 子类重写 `viewDidLoad` 必须**先调 `super`**（这一层要在它们自己那套之前把皮穿好）。
    override func viewDidLoad() {
        super.viewDidLoad()
        apply(surface)
    }

    /// 把档位落到这条栈上 —— **全 App 唯一一处**改导航栏外观的地方。
    private func apply(_ surface: NavigationSurface) {
        // ① 强制外观：黑皮那一档**不跟系统外观翻** —— 它底是纯黑、字是白，翻了整页看不见。
        //    `.unspecified` 就是 UIKit 的默认值，其余三档显式写回来，读起来才知道「这里表过态」。
        overrideUserInterfaceStyle = surface.interfaceStyle

        // ② 栈视图自己的底色：模态栈在推栈 / 转场时**露出来的那一块**。
        //    `nil` = 不设（沿用 UIKit 默认）—— 页面底色本来就盖满的地方不用设，
        //    设了等于替 UIKit 决定一件它本来就做对的事。
        if let stackBackground = surface.stackBackground {
            view.backgroundColor = stackBackground
        }

        // ③ 导航栏外观。
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = surface.barBackground
        // ⚠️ 只有「栏和它下面那张列表之间要看得见一条线」的档位才显式给发丝线；
        //    其余留 `configureWithOpaqueBackground()` 自带的那条，不自己发明一个色。
        if let shadow = surface.barShadow { appearance.shadowColor = shadow }

        // ⚠️ **三个槽位都要给**：常态 / 滚到顶 / 横屏紧凑。
        //    少给一个，那一种状态下就会退回系统默认（半透明）—— 上面那些白设。
        let bar = navigationBar
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        // 强调色全 App 一个（返回键、栏上的键文字），不随档位变 —— 所以它是常量，不是档位的一维。
        bar.tintColor = AppColor.accent

        // ④ 藏栏：黑皮那档**自绘顶栏**，不吃系统栏。
        if surface.hidesBar { setNavigationBarHidden(true, animated: false) }
    }
}

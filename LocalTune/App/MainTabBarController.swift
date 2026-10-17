import UIKit

/// 底部两个 Tab 的容器：**歌曲** / **歌单** —— **只管标签栏本体**。
///
/// 效果出处见映射文档 §1（底部容器那一节）：
///
/// - 两个 tab，选中和未选中**用同一个图标**
/// - 标签栏**自己不画背景** —— 它的底由底下那层材质铺（这是"两段连成一整块"的前提）
/// - 选中色 `accent`、未选中 `subtitle`
/// - 转屏权限**跟着当前选中的那一页**，容器自己不拍
/// - 迷你条**一直显示**（没歌在播时写着「未在播放」），只有进多选模式才藏
/// - 点迷你条 → `AppRouter.presentNowPlaying`；**无当前曲时门闩直接 return**（不弹空壳页）
///
/// ## 底部那条迷你条**不在这儿**
///
/// 这里原来塞着"一整块底部"（材质 + 条子 + 分隔线），位置靠**手算 frame**、
/// 每次布局重算、转场中途还强制排一次整棵树 —— 那一套必然要在**标签栏正被藏起来的那一瞬**
/// 动到整棵树，正好踩中 iOS 26 标签栏"标题只量一次宽"的 bug（`FB24250687`），
/// 表现就是"从二级页退回后，选中那个 tab 的两个字被挤成 `…`"。
///
/// 现在拆成**每个 tab 一条**：条子住在各自的导航容器 `MiniBarNavController` 里，
/// 位置**全由约束**跟着安全区走，转场里**一行布局都不排**。
/// 于是"标签栏显不显示"变成系统改安全区这件事，谁也踩不到那个时机。
///
/// **代价（认了）**：切 tab 时是**换了一条条子实例**（长得一样，不再是同一条）；
/// 高频订阅也从一份变两份。
final class MainTabBarController: UITabBarController {

    /// 服务容器 —— 页面要用的服务**从这里往下发**（页面自己不摸全局，见 `AppServices` 的说明）。
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
        super.init(nibName: nil, bundle: nil)
        setupTabs()
        setupTabBarAppearance()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 转屏

    /// 转屏权限**由当前选中的页决定** —— 容器自己不定规矩。
    ///
    /// 例：以后播放页要支持横屏，它自己在那一页重写就行，不用回来改这里。
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        selectedViewController?.supportedInterfaceOrientations ?? .portrait
    }

    // ⚠️ 这里**没有**覆写 `shouldAutorotate`（那意思也是"跟着当前页"）——
    // 它在 iOS 16 就被废弃、被系统忽略了（编译会给一条黄警告），而我们最低正好是 iOS 16。
    // iOS 16 起「转不转」只看 `supportedInterfaceOrientations` 这一个。
    //
    // 留给以后的：哪个页的转屏权限要是跟别的页**不一样**（比如播放页横屏、其余竖屏），
    // 切到它的时候要主动调一次 `setNeedsUpdateOfSupportedInterfaceOrientations()`——
    // iOS 16 起系统不保证每次都重新问一遍。现在两个 tab 都是竖屏，没有这个需求。

    // MARK: - 私有

    private func setupTabs() {
        // ⚠️ **每个 tab 各有一个 Router** —— Router 绑的是"一条导航栈"，
        // 而两个 tab 是两条互不相干的栈。
        //
        // 顺序上有个绕不开的环：栈要等根页面造好才能造，而根页面要拿到 Router ——
        // 所以先建 Router、由它造出根页面和栈，最后再把栈绑回 Router。
        let songsRouter = AppRouter(services: services)
        let songs = makeTab(
            router: songsRouter,
            root: songsRouter.makeSongsViewController(),
            title: "歌曲",
            symbol: "music.quarternote.3"
        )
        songsRouter.attach(to: songs)

        let playlistsRouter = AppRouter(services: services)
        let playlists = makeTab(
            router: playlistsRouter,
            root: playlistsRouter.makePlaylistsViewController(),
            title: "歌单",
            symbol: "music.note.list"
        )
        playlistsRouter.attach(to: playlists)

        viewControllers = [songs, playlists]
    }

    /// 造一个 tab —— **导航容器自带它那一条迷你条**。
    ///
    /// 🔴 **条子要的东西全在这一处给齐**：
    /// - **播放器** —— 从服务容器取，走 `init` 传进去；
    /// - **取封面的动作** —— 装配层给 `AppArtwork.image`（跟播放页大封面同一个实现）；
    /// - **三个动作** —— 导航容器不认识 `AppRouter`，它只说"有人点了条子 / 播放键 / 下一首键"，
    ///   跳去哪由这儿替它接（跳转**只能从 Router 出去**）。
    ///
    /// ⚠️ 上面这几样**全从 `init` 给**：少给一个就编译不过。反例是留成"事后赋值的可选属性"——
    /// 那样漏接一个不会出声，表现是**点了没反应**。
    private func makeTab(
        router: AppRouter,
        root: UIViewController,
        title: String,
        symbol: String
    ) -> MiniBarNavController {
        // ⚠️ 闭包里用 **`weak`** 抓（`router` / `playManager` 都是类）：这几个闭包住在条子的实例里、
        //    条子住在导航容器里 —— 强引用会转成一条环，容器永远不释放。
        let playManager = services.playManager

        let nav = MiniBarNavController(
            playManager: playManager,
            artworkProvider: AppArtwork.image,
            rootViewController: root,
            // 🔴 **这条栈穿哪一档皮，在这儿说**（`宪法.md` §二：导航栏外观的唯一出处是
            // `AppNavigationController`，档位由**建栈的人**声明）。两个 tab 都是普通页面栈 ⇒ `.page`。
            // ⚠️ 别挪进 `MiniBarNavController` 里写死 —— 那就成了"同一个概念两个口径"。
            surface: .page,
            // 点整条 = 弹播放页。
            onTapMiniBar: { [weak router] in router?.presentNowPlaying() },
            // 播放 / 暂停 —— 接到播放器。
            onTogglePlayPause: { [weak playManager] in playManager?.togglePlayPause() },
            // 下一首 —— 接到队列。走到最后一首它什么都不做（队列里确实没有下一首）。
            onPlayNext: { [weak playManager] in playManager?.playNext() },
            // 上一首 —— 迷你条左右滑触发；队首顺序播放时它什么都不做。
            onPlayPrevious: { [weak playManager] in playManager?.playPrevious() }
        )

        // 选中和未选中**用同一个图标**（见文件顶上那份效果出处）。
        nav.tabBarItem = UITabBarItem(
            title: title,
            image: UIImage(systemName: symbol),
            selectedImage: UIImage(systemName: symbol)
        )
        return nav
    }

    private func setupTabBarAppearance() {
        let appearance = UITabBarAppearance()
        // 🔴 **标签栏自己不画底** —— 它的底由**底下那层材质**铺
        // （每个 tab 的导航容器 `MiniBarNavController` 各自铺一份，铺到屏幕底）。
        // 这是"条子和标签栏看着是一整块"的前提：标签栏要是自己再画一层，
        // 就又是**两层玻璃挨着**了。
        //
        // ⚠️ 这几样都**显式写**，别只靠 `configureWithTransparentBackground()` 一句：
        // 将来有人改回去，从代码上就看不出差别（而表现是那两层玻璃）。
        appearance.configureWithTransparentBackground()
        appearance.shadowColor = .clear

        // 选中 / 未选中两个颜色各一处出处，appearance 和 tabBar 自己的 tint 都用它们。
        let selectedColor = AppColor.accent
        let normalColor = AppColor.subtitle

        appearance.stackedLayoutAppearance.normal.iconColor = normalColor
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: normalColor]
        appearance.stackedLayoutAppearance.selected.iconColor = selectedColor
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]

        // 两个都要设：`scrollEdgeAppearance` 管"内容顶到边缘时"的样子，
        // 只设 `standardAppearance` 的话，列表滚到顶会突然冒出一层底色。
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance

        // 这两行是给系统自己的那部分（比如某些转场）兜底，跟上面的 appearance 一致。
        tabBar.tintColor = selectedColor
        tabBar.unselectedItemTintColor = normalColor
    }
}

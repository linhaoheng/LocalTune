import UIKit

/// 一个窗口场景的负责人：建窗口、建服务、装根页面。
///
/// 类名要和 `Info.plist` 里 `UISceneDelegateClassName` 写的一致，
/// 系统按那个名字实例化本类，不走 `AppDelegate`。
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    /// 全 App 的服务容器 —— **唯一创建处**，窗口活着它就活着。
    ///
    /// 页面**不从这里拿**（那会变成"谁都能摸到全局"），而是由 `AppRouter`
    /// 造页面时一个个注入进去。
    private(set) var services: AppServices?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else {
            assertionFailure("场景清单里只注册了窗口场景，不会连上别的类型")
            return
        }

        let window = UIWindow(windowScene: windowScene)
        self.window = window
        installRootAndTheme()
        window.makeKeyAndVisible()

        // 小组件 Link 冷启动：URL 随连接参数进来（服务已在上面建好），直接路由。
        for context in connectionOptions.urlContexts {
            WidgetCommandRouter.handleURL(context.url, keeper: services?.backgroundHandler)
        }
    }

    /// 回到前台做两件事 —— **各管各的，互不等**：
    ///
    /// 1. **小组件滞留命令的清场**（手动启动保护）：不是小组件唤醒的情况（含冷启动兜底）在这里丢掉。
    ///    顺序上它跑在冷启动 URL 路由**之后** —— 路由已消费掉的队列在这里是空的，两条先后不会互相误伤。
    /// 2. **核对一次「被打断那首是不是还在等续」**：打断结束时系统**可能什么都不说**
    ///    （我们**有意不接** `interruptionNotification`），
    ///    于是"打断结束了"这件事**没有出口**。回到前台是**与打断无关**的既有生命周期事件，
    ///    借它核对一次 —— 判据（票还在 ＋ 别的 App 没在放）只有 `PlayManager` 那一处，
    ///    这里只负责"在正确的时刻问一句"。设计：`播放中断与恢复设计.md` §10.2。
    func sceneDidBecomeActive(_ scene: UIScene) {
        WidgetCommandRouter.dropPendingState()
        services?.playManager.resumeAfterAppActivationIfSafe()
    }

    /// 小组件 Link 热启动：App 活着时点按钮，URL 从这里进来。
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            WidgetCommandRouter.handleURL(context.url, keeper: services?.backgroundHandler)
        }
    }

    /// 装根页 + 套主题。**新建 / 重试两条路都走这一个出口**，下次再加步骤只改这儿。
    private func installRootAndTheme() {
        window?.rootViewController = makeRootViewController()
        // 外观要在窗口**显示之前**定下来 —— 否则会先闪一下默认外观。
        // 建服务失败时（`services` 还是 nil）不套主题，那一页就用系统默认。
        if let theme = services?.settings.theme {
            AppAppearance.applyTheme(theme)
        }
    }

    /// 建服务 → 决定装哪一页。
    ///
    /// ⚠️ 建服务会**真的打开（没有就新建）数据库**，这是启动时唯一可能失败的重活。
    /// 失败就装「曲库打不开」那一页 —— **不能让失败表现成白屏**：
    /// 白屏上用户什么也做不了、也不知道出了什么事。
    private func makeRootViewController() -> UIViewController {
        do {
            // 🔴 全工程**唯一一处**跨对象取用：桥归 `AppDelegate`（系统入口只有它拿得到
            // 构造缝），场景这边取一次。系统一定先建 `AppDelegate`、再连场景。
            let bridge = (UIApplication.shared.delegate as? AppDelegate)?.intentBridge
            let services = try AppServices(intentBridge: bridge)
            self.services = services
            return MainTabBarController(services: services)
        } catch let error as LibraryDatabaseError {
            return makeFailureViewController(error)
        } catch {
            // 启动只可能抛 `LibraryDatabaseError`。走到这儿说明有没想到的路径 ——
            // 开发期直接炸出来，别让它变成"偶尔白屏"这种事后查不出的问题。
            assertionFailure("启动失败只该来自 LibraryDatabaseError，实际是：\(error)")
            return makeFailureViewController(
                .cannotOpen(path: LibraryDatabase.defaultPath, error: error)
            )
        }
    }

    private func makeFailureViewController(_ error: LibraryDatabaseError) -> UIViewController {
        let failure = LibraryUnavailableViewController(error: error)
        failure.onRetry = { [weak self] in
            guard let self else { return }
            // 重新建一遍：好了就正常进 App，还是不行就再回到这一页。
            self.installRootAndTheme()
        }
        return failure
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // 进后台不落盘：进程还活着，真相在内存。
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // iOS 13+ 从多任务划掉挂起 App 走这里（不走 applicationWillTerminate）。
        services?.playManager.persistSession()
        // 小组件退场兜底：App 没了，按钮别再显示「暂停中」。
        WidgetSharedStore.markNotPlaying()
    }
}

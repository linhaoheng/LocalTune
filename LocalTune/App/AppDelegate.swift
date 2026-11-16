import AppIntents
import Intents
import UIKit

/// App 的入口。
///
/// 窗口不在这里建 —— 工程声明了场景清单（`Info.plist` 的 `UIApplicationSceneManifest`），
/// 一个场景对应一个窗口，窗口由 `SceneDelegate` 负责。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    /// Intent / 快捷指令的桥 —— **全 App 由这里建一次**。
    ///
    /// 系统入口（`handlerFor` / `AppIntent.perform`）拿不到 `AppServices` 的 init 缝，
    /// 所以桥必须挂在系统自己会创建的那个对象上 —— `AppDelegate` 就是它。
    /// 之后由它交给系统入口：Siri 那条路构造注入，快捷指令那条路登记进框架的依赖表。
    let intentBridge = LocalTuneIntentBridge()

    /// Siri 媒体意图处理器 —— 主 App 直办。
    private lazy var playMediaIntentHandler = PlayMediaIntentHandler(bridge: intentBridge)


    /// 主窗口 —— **这一条不是给我们自己用的**。
    ///
    /// ⚠️ 我们自己不用它（窗口归 `SceneDelegate`，见上面的说明）。
    /// 它是**给还在按老写法取窗口的库留的**：那些库写的是
    /// `UIApplication.sharedApplication.delegate.window` ——
    /// 那个属性在 `UIApplicationDelegate` 里是**可选**的，不实现它，
    /// 库里那句就变成 `unrecognized selector` **直接崩**。
    ///
    /// 当初踩响它的是：**长按搜索框**弹出系统的编辑菜单时，QMUI 的
    /// `UIMenuController+QMUI` 从这条路取窗口，整个 App 挂掉 ——
    /// 报的就是 `-[LocalTune.AppDelegate window]`。
    ///
    /// 🔴 **不许删。** QMUI 从工程摘除后，这一条曾有人提议可以一并去掉 ——
    /// **军师不同意**，理由两条：
    ///
    /// 1. 它的理由**从来不是 QMUI**。会踩这个坑的是「按老写法取窗口」这一整类代码：
    ///    在用的库里 `SVProgressHUD` 就写着这个取法（`SVProgressHUD.m:80` 的 `+mainWindow`），
    ///    只是那句落在 iOS 13 的另一条分支里，而我们最低支持 16，走不到而已。
    /// 2. 留它是 **1 行**；删它省不下什么，将来真踩上却是 `unrecognized selector`
    ///    —— 最难查的那一种崩溃。
    ///
    /// ⚠️ 给的是**当下那个 key window**，不是存下来的某个窗口 —— 多窗口下也对。
    ///
    /// ⚠️ **必须写成 `get` + 空 `set`，不能只给 getter。**
    /// 协议里这个属性是**可读可写**的（`UIApplication.h:454`：
    /// `@property (nullable, nonatomic, strong) UIWindow *window`）。
    /// 只给 getter 的话，编译器会报
    /// 「Property 'window' nearly matches optional requirement 'window'」——
    /// 那句的意思是**它不算实现了协议要求**，防崩的效果也就没了保障。
    /// `set` 留空是**有意**的：窗口不归 `AppDelegate` 管（见上面的说明）。
    var window: UIWindow? {
        get { UIApplication.shared.keyAppWindow }
        set {}
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 锁屏 / 耳机线控来的远端事件：进程级接缝，启动就开。
        // ⚠️ 它**不是** `MPRemoteCommandCenter` 那套（那套归 `NowPlayingCenter`，
        // 跟播放器同寿、随装配一起建）—— 这一条是「从系统往 App 递事件」的开关，
        // 早于任何播放器对象存在，所以归启动这一层。
        application.beginReceivingRemoteControlEvents()

        // 快捷指令那条路的依赖登记：`AppIntent` / `EntityQuery` 靠框架从这儿取桥。
        // 必须早于任何 Intent 被调起（极冷启动下 Siri 可能很快就来），所以放在启动第一刻。
        let bridge = intentBridge
        AppDependencyManager.shared.add { bridge }

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // 前台被系统终止时落盘（划掉挂起主路径在 sceneDidDisconnect）。
        for case let scene as UIWindowScene in application.connectedScenes {
            (scene.delegate as? SceneDelegate)?.services?.playManager.persistSession()
        }
        // 小组件退场兜底：进程要没了，按钮别再显示「暂停中」。
        WidgetSharedStore.markNotPlaying()
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        WindowOrientation.mask(from: window?.rootViewController)
    }

    /// iOS 14+：系统把 `INPlayMediaIntent` 交给主 App 时走这里。
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        if intent is INPlayMediaIntent {
            return playMediaIntentHandler
        }
        return nil
    }
}

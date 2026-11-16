import UIKit

/// 小组件命令在主 App 内的落点 —— URL 路由、Darwin 兜底消费、回桌面。
///
/// 只管 iOS 16 那条路（Link 前台化主 App）和兜底路（Darwin 叫醒）；
/// iOS 17+ 的 `AudioPlaybackIntent` 不经过这里（`perform` 直接调执行口）。
///
/// 🔴 回后台后的保活**不自己 `beginBackgroundTask`**，而是借进程的 `BackgroundHandler`
/// （调用方当参数传进来）—— 同一件系统资源只有一个记账人。
///
/// ## 线程
///
/// 全在主线程：SceneDelegate 回调在主线程，Darwin 回调在
/// `WidgetPlaybackCommand.observeCommands` 里已派发主队列。
///
/// ## 🔴 私有 API 说明
///
/// `bounceToBackground()` 用字符串选择器调私有 `suspend` 让 App 立刻回桌面 ——
/// 这是 iOS 16 链路「点组件执行完回桌面」效果的**唯一**实现手段。
/// 调用点全工程仅此一处；**上架前需评估是否摘除**（摘除后 iOS 16 的按钮变成
/// 「执行并留在 App」，iOS 17+ 不受影响）。
@MainActor
enum WidgetCommandRouter {

    /// 手动启动保护：非小组件唤醒（用户手点图标）时丢弃滞留命令与回桌面标记。
    ///
    /// 🔴 没有这一句的话：上一次没消费掉的「回桌面」标记会让用户
    /// 一打开 App 就被莫名打回桌面。
    static func dropPendingState() {
        _ = WidgetSharedStore.takePendingCommand()
        _ = WidgetSharedStore.consumeBounceFlag()
    }

    /// iOS 16 链路入口：小组件 Link 前台化主 App，系统把 URL 送进来。
    ///
    /// `keeper` ＝ 进程的后台窗口记账人（`BackgroundHandler`）。服务没建起来
    /// （曲库打不开那一页）时为 `nil` —— 那就只执行命令、不借窗口。
    ///
    /// - Returns: 是不是我们的命令地址（不是就交给别的 URL 处理者）。
    @discardableResult
    static func handleURL(_ url: URL, keeper: BackgroundHandler?) -> Bool {
        guard let command = WidgetPlaybackCommand.command(from: url) else { return false }
        // 直达主 App 了，队列里滞留的旧命令（Darwin 兜底路写下的）已被本次点击覆盖。
        _ = WidgetSharedStore.takePendingCommand()
        execute(command, bounce: true, keeper: keeper)
        return true
    }

    /// Darwin 兜底路的消费口（`AppServices` 装配时挂观察）：
    /// 命令从队列取，回桌面标记**只在挂着时**弹回后台。
    static func handleDarwinCommand(_ command: WidgetPlaybackCommand, keeper: BackgroundHandler?) {
        _ = WidgetSharedStore.takePendingCommand()
        execute(command, bounce: WidgetSharedStore.consumeBounceFlag(), keeper: keeper)
    }

    // MARK: - 私有

    private static func execute(
        _ command: WidgetPlaybackCommand,
        bounce: Bool,
        keeper: BackgroundHandler?
    ) {
        if bounce {
            bounceToBackground()
            // 执行 + 落盘 + reload 都发生在回后台之后的短暂窗口里 —— 向进程的
            // 后台窗口记账人借一张罩住它，不然 reload 请求会被系统挂起吞掉。
            // 走同一个记账人（不再各自徒手 `beginBackgroundTask`）：全工程「请假」
            // 只剩一个出处；正在播时它本就持着，这里只是把计数叠上去。
            keeper?.increment()
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.keepAlive) {
                keeper?.decrement()
            }
        }
        // 装配没成（曲库都打不开的失败页）就没人消费 —— 此时小组件本来
        // 也刷不出新内容，不做无声的假动作之外的补救。
        WidgetIntentExecution.handler?(command)
    }

    /// 🔴 私有 selector —— 见文件头说明，**全工程唯一调用点**。
    private static func bounceToBackground() {
        UIApplication.shared.perform(NSSelectorFromString("suspend"))
    }

    private enum Timing {
        /// 回后台后保活多久 —— 罩住「执行命令 → 落盘 → reload」这串事。
        static let keepAlive: TimeInterval = 1.2
    }
}

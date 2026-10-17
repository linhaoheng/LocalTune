import UIKit

/// 「向系统借一段后台时间」这个动作的形状 —— 生产是 `UIApplication`，测试塞假件，
/// 不必真碰系统。
///
/// 抽成协议只为让「计数对不对」能在测试里跑一遍，不带真 App。
protocol BackgroundTaskCreating: AnyObject {
    func beginKeepAlive(
        name: String,
        expirationHandler: @escaping () -> Void
    ) -> UIBackgroundTaskIdentifier

    func endKeepAlive(_ identifier: UIBackgroundTaskIdentifier)
}

extension UIApplication: BackgroundTaskCreating {
    func beginKeepAlive(
        name: String,
        expirationHandler: @escaping () -> Void
    ) -> UIBackgroundTaskIdentifier {
        beginBackgroundTask(withName: name, expirationHandler: expirationHandler)
    }

    func endKeepAlive(_ identifier: UIBackgroundTaskIdentifier) {
        endBackgroundTask(identifier)
    }
}

/// 引用计数式「后台窗口」记账人：多个地方各记各的一笔，**计数从 0 起才借一张、
/// 回到 0 才还** —— 中途来回不会把系统任务反复借还抖掉。
///
/// 它是**进程级**设施，不认识播放：谁想在后台多活一会儿，谁就 `increment` /
/// `decrement` 它。正因为不认识播放，它属 `App` 层（进程生命周期），不属 `Playback`。
///
/// ## 线程
///
/// **只在主线程用**：`UIApplication.beginBackgroundTask` 要求主线程，所有调用点
/// （`AppServices` 里那根订阅）也都在主线程。因此 `counter` / `taskIdentifier`
/// **不加锁** —— 加锁只会给不存在的并发做样子。
@MainActor
final class BackgroundHandler {

    /// 借 / 还的动作本体。默认真系统，测试传假件。
    private let creator: BackgroundTaskCreating

    /// 现在借着的那张任务；`nil` ＝ 没借着（含被系统到期收走之后）。
    private var taskIdentifier: UIBackgroundTaskIdentifier?

    /// 还有几笔没还。
    private var counter = 0

    init(creator: BackgroundTaskCreating) {
        self.creator = creator
    }

    /// 记一笔。**判据是「没借着」，不是「计数刚好从 0 变 1」** ——
    /// 系统到期会把任务收走（`taskIdentifier` 归 `nil`）而计数还在，
    /// 只按计数判就再也借不回来；按「没借着」判，下一次就会重借。
    func increment() {
        counter += 1
        guard taskIdentifier == nil else { return }
        taskIdentifier = creator.beginKeepAlive(name: Self.taskName) { [weak self] in
            // 系统到期回调：把那张结掉、记「没借着」。**不动计数** ——
            // 计数代表还有几笔要用，任务被收走不代表事做完了。
            self?.releaseCurrentTask()
        }
    }

    /// 还一笔。**没借着时什么都不做**（连计数都不减）——
    /// 任务已被系统收走时再减一遍，会把这笔账减穿，下次该借时反而借不出来。
    func decrement() {
        guard taskIdentifier != nil else { return }
        counter -= 1
        guard counter == 0 else { return }
        releaseCurrentTask()
    }

    deinit {
        // 对象没了也得把任务还掉，否则那张会一直挂到系统到期。
        guard let identifier = taskIdentifier else { return }
        creator.endKeepAlive(identifier)
    }

    /// 把当前这张还给系统，并记「没借着」。
    private func releaseCurrentTask() {
        guard let identifier = taskIdentifier else { return }
        taskIdentifier = nil
        creator.endKeepAlive(identifier)
    }

    /// 仪器 / 系统日志里认领用的名字，不参与行为。
    private static let taskName = "local-tune"
}

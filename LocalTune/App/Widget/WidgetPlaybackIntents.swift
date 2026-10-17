import AppIntents

/// 小组件三颗键的 iOS 17+ 执行路径 —— `AudioPlaybackIntent`。
///
/// 🔴 这三个类型**主 App 与扩展两个 target 都要编**：`Button(intent:)` 在扩展里声明，
/// 但 `perform()` 由系统路由到**主 App 进程**执行（必要时后台唤起）——
/// 这是 `AudioPlaybackIntent` 的契约。主 App 里没装配完时明确走「入队叫醒」兜底，
/// 不假装成功、也不把 Siri 桥的类型链拖进扩展。
///
/// `openAppWhenRun = false`：按按钮不把 App 拉到前台 —— 播放照切，用户停在桌面。
struct WidgetPlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "播放或暂停"
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await WidgetIntentExecution.run(.playPause)
        return .result()
    }
}

struct WidgetNextIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "下一首"
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await WidgetIntentExecution.run(.next)
        return .result()
    }
}

struct WidgetPreviousIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "上一首"
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await WidgetIntentExecution.run(.previous)
        return .result()
    }
}

/// 三颗键共用的执行步骤 —— **只写这一处**。
///
/// ## 线程
///
/// `handler` 只在**主线程**读写：装配层写入（`AppServices` init，主线程约定），
/// 消费在 Intent `perform`（`@MainActor`）。静态存储只是省掉一层传递，
/// 没有跨线程的读写竞争。
enum WidgetIntentExecution {

    /// 主 App 进程内由装配层（`AppServices`）挂上的执行口；
    /// **扩展进程里保持 nil** —— 进程身份的判据，兜底随之二选一。
    ///
    /// 🔴 为什么是静态可写：系统入口（`Intent.perform`）没有 `AppServices` 的 init 缝，
    /// 和 Siri 桥挂在 `AppDelegate` 是同一类「系统入口的构造缝」问题。
    /// 装配**仍然只发生在装配层** —— 这里不是第二个装配点。
    static var handler: ((WidgetPlaybackCommand) -> Void)?

    @MainActor
    static func run(_ command: WidgetPlaybackCommand) async throws {
        guard let handler else {
            // 兜底：够不着主 App 的执行口（扩展进程 / 尚未装配）——
            // 命令入队 + Darwin 通知叫醒还活着的主 App 来消费。
            WidgetSharedStore.queueCommand(command)
            WidgetPlaybackCommand.postDarwinNotification(for: command)
            return
        }
        let before = WidgetSharedStore.loadSnapshot().updatedAt
        handler(command)
        // perform 返回前等主 App 把新状态落盘 —— 返回太早的话，
        // WidgetKit 紧跟着的 reload 拿到的还是旧帧，按钮就像「没反应」。
        await WidgetSharedStore.waitForSnapshotUpdate(since: before)
    }
}

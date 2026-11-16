import Foundation
import WidgetKit

/// 小组件跨进程通道的**唯一出口** —— 全工程只有这里读写 App Group。
///
/// 装两样东西：
/// - **状态通道**：播放快照（UserDefaults）+ 封面（App Group 里的一张 JPEG 文件）；
/// - **命令通道**：小组件按钮 → 主 App 的命令队列 + Darwin 通知叫醒。
///
/// 业务代码里不许出现 `UserDefaults(suiteName:)` / 封面路径拼接 —— 那是这一处的事
/// （对齐 `BackupExclusion` 的「唯一出处」口径）。
///
/// ## 线程
///
/// 写只在**主 App 主线程**（发布者落盘、命令路由）；读任意线程（扩展进程的
/// TimelineProvider 在自己的渲染时机读）。`UserDefaults` 自身线程安全，
/// 封面文件走原子写；两边没有共享的可变内存，不需要锁。
enum WidgetSharedStore {

    /// App Group 标识 —— 主 App 与扩展两个 entitlements 必须都登记同一个值。
    static let appGroupID = "group.com.localmusic.player"

    /// 小组件种类名 —— 主 App reload 与扩展登记用的是**同一份**。
    static let widgetKind = "LocalTuneNowPlaying"

    // MARK: - 键与常量

    private static let snapshotKey = "widget.playbackSnapshot"
    private static let isPlayingKey = "widget.isPlaying"
    private static let pendingCommandKey = "widget.pendingCommand"
    private static let bounceToBackgroundKey = "widget.bounceToBackground"
    private static let artworkFileName = "widgetArtwork.jpg"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    private static var artworkURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(artworkFileName)
    }

    // MARK: - 状态通道 · 读（扩展侧用）

    /// 读当前快照；通道上还没有（或读不出）就是 `empty`。
    static func loadSnapshot() -> WidgetPlaybackSnapshot {
        guard let data = defaults?.data(forKey: snapshotKey) else { return .empty }
        // 敢吞 `try?`：解码失败退回空快照 —— 下一帧 save 会覆盖，
        // 比让整个小组件渲染失败强。
        return (try? JSONDecoder().decode(WidgetPlaybackSnapshot.self, from: data)) ?? .empty
    }

    /// 读封面字节；没有就是 `nil`，视图画占位音符。
    static func artworkData() -> Data? {
        guard let url = artworkURL else { return nil }
        // 敢吞 `try?`：封面读不出来就占位，封面是缓存，不挡小组件渲染。
        return try? Data(contentsOf: url)
    }

    // MARK: - 状态通道 · 写（主 App 发布者用）

    /// 落一份快照 + 封面，然后请求 reload。
    ///
    /// 🔴 `updatedAt` 在**这里**打点（落盘时刻）：发布者构造的快照不带时间戳，
    /// 「内容没变就不写」的去重才不会被时间戳打破。
    ///
    /// `isPlaying` 单独再写一个键：按钮图标可以不解析整份快照就读播放态。
    static func save(_ snapshot: WidgetPlaybackSnapshot, artworkJPEG: Data?) {
        var stamped = snapshot
        stamped.updatedAt = Date().timeIntervalSince1970
        guard let data = try? JSONEncoder().encode(stamped) else { return }
        defaults?.set(data, forKey: snapshotKey)
        defaults?.set(stamped.isPlaying, forKey: isPlayingKey)
        writeArtwork(artworkJPEG)
        reloadWidget()
    }

    /// 落「暂停」态（App 正常退场路径的兜底）。
    ///
    /// 已经是暂停态就不白写一趟 —— 那会白白消耗一次 reload 预算。
    static func markNotPlaying() {
        var snapshot = loadSnapshot()
        guard snapshot.isPlaying else { return }
        snapshot.isPlaying = false
        save(snapshot, artworkJPEG: snapshot.hasArtwork ? artworkData() : nil)
    }

    /// 封面文件：有就原子覆盖，没有就删 —— 文件有无跟着 `hasArtwork` 走，不另记一份。
    private static func writeArtwork(_ data: Data?) {
        guard let url = artworkURL else { return }
        guard let data else {
            // 敢吞 `try?`：删不掉的孤儿封面只占几 KB，不值得为它报错；
            // 下一次带封面的 save 会覆盖同名文件。
            try? FileManager.default.removeItem(at: url)
            return
        }
        // 敢吞 `try?`：写失败 = 这次封面没换上，快照里的 `hasArtwork` 会跟
        // 实际文件对不上一次 —— 视图有占位兜底，下一帧 save 会再试。
        try? data.write(to: url, options: [.atomic])
    }

    /// 请求系统重载小组件时间线。**只发一次** ——
    /// 多路 reload 请求只会更快耗尽系统的刷新预算，不会更快上屏。
    private static func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    // MARK: - 命令通道

    /// 有界等待「快照比某时刻新」—— Intent `perform` 返回前等主 App 落盘，
    /// 等到了 WidgetKit 才会拿到带新状态的快照。
    ///
    /// 上限 40 × 50ms = 2s：跨进程没有回执，轮询是唯一能用的确认方式；
    /// 等不到就返回（按钮已按命令执行，小组件随后自己会 reload）。
    static func waitForSnapshotUpdate(since: TimeInterval) async {
        for _ in 0..<40 {
            if loadSnapshot().updatedAt > since { return }
            // 敢吞 `try?`：睡被打断只少等一轮，上限兜着。
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 命令入队 + 挂「执行完回后台」标记 —— 给够不着主 App 进程的那条路用。
    static func queueCommand(_ command: WidgetPlaybackCommand) {
        defaults?.set(command.rawValue, forKey: pendingCommandKey)
        defaults?.set(true, forKey: bounceToBackgroundKey)
    }

    /// 取走队首命令（取走即清）；没有就是 `nil`。
    static func takePendingCommand() -> WidgetPlaybackCommand? {
        guard let raw = defaults?.string(forKey: pendingCommandKey) else { return nil }
        defaults?.removeObject(forKey: pendingCommandKey)
        return WidgetPlaybackCommand(rawValue: raw)
    }

    /// 取走「执行完回后台」标记（取走即清）；没有就是 `false`。
    static func consumeBounceFlag() -> Bool {
        guard let defaults else { return false }
        let flagged = defaults.bool(forKey: bounceToBackgroundKey)
        defaults.removeObject(forKey: bounceToBackgroundKey)
        return flagged
    }
}

/// 小组件按钮的**命令词汇** —— 三键各一档，横跨 URL / Darwin / 队列三种载体。
enum WidgetPlaybackCommand: String, CaseIterable {

    case playPause
    case next
    case previous

    /// URL scheme —— 主 App `Info.plist` 注册的同一个值。
    static let urlScheme = "localtune"

    /// iOS 16 按钮的落地地址：`localtune://open/widget_action?cmd=…`。
    var actionURL: URL {
        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = "open"
        components.path = "/widget_action"
        components.queryItems = [URLQueryItem(name: "cmd", value: rawValue)]
        guard let url = components.url else {
            // 全部字段都是字面量加枚举原始值，这里不可能失败 —— 撞上就是程序员写错。
            assertionFailure("固定字段拼小组件命令 URL 失败，检查 scheme/host 字面量")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    /// 从落地地址认回命令；不是我们的地址就是 `nil`。
    static func command(from url: URL) -> WidgetPlaybackCommand? {
        guard url.scheme == urlScheme,
              url.path.hasSuffix("widget_action") || url.host == "widget_action"
        else { return nil }
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmd" })?
            .value
        else { return nil }
        return WidgetPlaybackCommand(rawValue: raw)
    }

    /// Darwin 通知名前缀 —— 按命令接尾。
    private static let darwinNamePrefix = "com.localmusic.player.widget.command."

    var darwinName: String { Self.darwinNamePrefix + rawValue }

    init?(darwinName: String) {
        guard darwinName.hasPrefix(Self.darwinNamePrefix) else { return nil }
        self.init(rawValue: String(darwinName.dropFirst(Self.darwinNamePrefix.count)))
    }

    /// 把命令投到 Darwin 通知中心 —— 兜底那一路的「叫醒」。
    ///
    /// ⚠️ Darwin 通知**唤不醒**挂起 / 死掉的进程；它只对本来就在跑的接收方有效。
    static func postDarwinNotification(for command: WidgetPlaybackCommand) {
        guard let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }
        CFNotificationCenterPostNotification(
            center, CFNotificationName(command.darwinName as CFString), nil, nil, true
        )
    }

    /// Darwin 观察的回调上下文盒 —— C 函数指针捕获不了任何上下文，
    /// handler 只能装进对象、经 `CFNotificationCenterAddObserver` 的
    /// `observer` 指针参数带进回调，再用 `Unmanaged` 取回（C 回调带上下文的教科书做法）。
    private final class CommandHandlerBox {
        let handler: (WidgetPlaybackCommand) -> Void
        init(_ handler: @escaping (WidgetPlaybackCommand) -> Void) { self.handler = handler }
    }

    /// 盒本体 —— 观察跟进程同寿，盒也跟进程同寿（这里持有），`Unmanaged` 走不保留语义。
    private static var commandHandlerBox: CommandHandlerBox?

    /// 挂上三个命令名的 Darwin 观察（**只在主 App** 挂一次，随进程同寿）。
    ///
    /// 回调是 **C 函数指针**：闭包体内一个外部量都不许抓，全靠 `observer`
    /// 指针把上下文带进去 —— 这就是装 `CommandHandlerBox` 的原因。
    static func observeCommands(handler: @escaping (WidgetPlaybackCommand) -> Void) {
        guard let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }
        // 挂一次：重复调用会叠出多套观察，主 App 装配层只该调这一回。
        guard commandHandlerBox == nil else { return }
        let box = CommandHandlerBox(handler)
        commandHandlerBox = box
        let observer = Unmanaged.passUnretained(box).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer,
                  let raw = name?.rawValue as String?,
                  let command = WidgetPlaybackCommand(darwinName: raw)
            else { return }
            let box = Unmanaged<CommandHandlerBox>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { box.handler(command) }
        }
        for command in WidgetPlaybackCommand.allCases {
            CFNotificationCenterAddObserver(
                center, observer, callback, command.darwinName as CFString, nil, .deliverImmediately
            )
        }
    }
}

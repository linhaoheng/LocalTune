import AVFAudio
import Foundation

/// 音频会话 —— 🔴 **全工程只有这一个地方碰 `AVAudioSession`。**
///
/// 它**只管执行**：「要不要配、配成什么样」是 `Decisions/SessionPlanPolicy` 算好的
/// （那边是纯函数、能单测），这里只剩"把算好的方案落到系统上"。
///
/// 🔴 同一个决定**不许有两处实现** —— 一处「看条件才配」、一处「无条件配」
/// 于是从不同入口进来行为不一样。现在执行只有一处。
///
/// ⚠️ **不做这件事的后果是听得见的**：系统默认类别会尊重静音开关 ⇒
/// 静音键拨下去，歌就没声了。
///
/// ## 换出口（`routeChangeNotification`）
///
/// 系统换音频出口（拔耳机 / 蓝牙断开 / 被抢到通话档 / AirPlay 回本机）时，
/// **只有这里**订那条通知，把系统那份 `userInfo` 收成一份**值**（`AudioRouteChangeFacts`）交给外面。
/// 「该不该暂停 / 重抢 / 续播」是**判断**（`Decisions/AudioRoutePolicies.swift`），不在这里做 ——
/// 这里只负责「读会话对象 → 值」，一个暂停令都不下。
///
/// ## 🔴 为什么这里**不**订 `interruptionNotification`（有意不接，别再补）
///
/// 来电 / 闹钟 / 别的 App 抢音频，系统都会发 `AVAudioSession.interruptionNotification`。
/// 我们**故意不订它**，三条理由：
///
/// 1. **SFB 内部已经订了** ⇒ 我们再订就是**第二条链路**，两边对同一次打断各记一份，
///    早晚不同步；
/// 2. 它给的 `userInfo` 我们**只需要 `shouldResume` 这一位**，而这一位 SFB
///    **已经替我们消化**了（有它才报「在播」）—— 我们要的信息**在引擎档位里已经有了**；
/// 3. 少一条观察链 ⇒ 少一处 dispose / 线程 / 时序的坑。
///
/// ⚠️ **代价**：`.ended` 不带 `shouldResume` 时 SFB **一声不吭**，我们**分不出**
/// 「打断结束了但系统不让恢复」和「还在打断中」—— 用户点播放时补会话 ＋ 起引擎（够用）；
/// 没人点播放的那一半，由**回前台核对一次**兜住（见下面「媒体服务重启 / 回前台核对」一节
/// 与 `Decisions/AppActivationResumePolicy.swift`）。
///
/// ⇒ 「被打断」这个说法**不由通知表达**，由 `Decisions/PlaybackStatusPolicy` 的第三参
/// （恢复票）表达；票在 `PlaybackHolds` 里记 / 销 / 作废。
/// 落地规格与真值表见 `docs/设计/播放中断与恢复设计.md`；缺口对账见
/// `docs/设计/播放器能力对账.md` §一 B。
///
/// ## 媒体服务重启（`mediaServicesWereResetNotification`）
///
/// 媒体服务进程（`mediaserverd`）崩了又起，系统会发这条通知 —— **手里所有音频对象全部作废**
/// （`AVAudioEngine` / 节点 / 会话），表现出来是「彻底没声」且**不自愈**：那条「停」的回调
/// **根本不来**（对象已经死了，谁回调你）。**只有这里**订它，收成一个**不带值**的回调。
///
/// 🔴 **只订 `reset`，不订 `lost`**：`lost` ＝ 服务已经没了、**还没回来**；只有 `reset` 之后
/// 才**建得出来**音频对象。在 `lost` 上丢对象 / 重造 / 起播 ＝ 对着一个不存在的服务建对象
/// （`AVAudioEngine` 建不出来 ⇒ SFB `throw std::runtime_error`，从 ObjC++ 边界抛出来是**崩溃**）。
/// 出处：Apple **QA1749**「Most applications only need to respond to the later reset notification」。
///
/// ⚠️ **这里只「观察到」（收成一句不带值的回调）** —— 「丢死对象 / 重造 / 要不要接着放」
/// 全不在这儿。别在这儿下任何播放的令。
/// 接线在 `PlayManager.init`（旁边就是 `startObservingRouteChanges` 那根线）。
///
/// ## 线程
///
/// **全在主线程**：通知观察挂在主队列上（`queue: .main`），所以回调、`routeChangeHandler`、
/// 观察句柄都在主线程读写，不需要锁。`prepareForPlayback()` 也由主线程调（`PlayManager`）。
///
/// 🔴 这一句现在**由编译器看着**（整个类 `@MainActor`）—— 以前它只是句注释。
/// 两条观察的「挂 / 摘」是这条规矩里唯一要绕一下的地方，绕法见各自的调用点
/// （观察块里 `MainActor.assumeIsolated`、`deinit` 里直接摘句柄）。规矩与实测见 `线程亲和设计.md`。
@MainActor
final class AudioSessionController {

    /// 换出口时的回调 —— 值进、值出，跑在主线程。
    private var routeChangeHandler: ((AudioRouteChangeFacts) -> Void)?

    /// 通知观察的句柄（`stopObservingRouteChanges` / `deinit` 要拿它退订）。
    private var routeChangeObserver: NSObjectProtocol?

    /// 媒体服务重启时的回调 —— **不带值**（通知的 `userInfo` 没有我们要的东西），跑在主线程。
    private var mediaServicesResetHandler: (() -> Void)?

    /// 媒体服务通知的观察句柄（`stopObservingMediaServices` / `deinit` 要拿它退订）。
    private var mediaServicesObserver: NSObjectProtocol?

    /// 要开始播了 —— 把会话配成「音乐播放」并激活。
    ///
    /// 调用方（`PlayManager`）只说这一句，不用知道"配成什么"。
    func prepareForPlayback() {
        apply(audioSessionPlan(for: .willStartPlayback))
    }

    /// 不出声了 —— 把输出**还回去**（`setActive(false, .notifyOthersOnDeactivation)`）。
    ///
    /// 🔴 与 `prepareForPlayback()` 同一个形状：调用方**只说理由**，「配成什么样」不归它管。
    /// 判据（"该不该还"）在 `SessionPlanPolicy`（`.didStopPlayback` ⇒ `.deactivate`）。
    ///
    /// ⚠️ **谁调它**：`PlayManager` 盯「要不要出声」**那一个信号**（`isPlaybackActive` 由真变假）——
    /// **不在 7 个停机点各补一句**（漏一处就永不释放，那正是加这一刀之前的现状）。
    func deactivate() {
        apply(audioSessionPlan(for: .didStopPlayback))
    }

    /// 开始盯系统换出口 —— **全工程唯一**订 `routeChangeNotification` 的地方。
    ///
    /// 回调在主队列上、带一份值；重复调会先退掉上一次的观察（不会叠观察）。
    func startObservingRouteChanges(_ handler: @escaping (AudioRouteChangeFacts) -> Void) {
        stopObservingRouteChanges()
        routeChangeHandler = handler
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            // 🔴 观察块本身**不带隔离**：`queue: .main` 是运行时事实，类型上没写。
            // 这里把「已知在主队列上」写成一次**显式声明** —— 哪天真不在主线程，debug 会当场炸，
            // 而不是悄悄写坏状态。
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        }
    }

    /// 不盯了（`PlayManager` 拆的时候 / 本对象销毁时）。
    func stopObservingRouteChanges() {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        routeChangeObserver = nil
        routeChangeHandler = nil
    }

    /// 开始盯**媒体服务重启** —— **全工程唯一**订 `mediaServicesWereResetNotification` 的地方。
    ///
    /// 🔴 **只订 `reset`**（不订 `lost`），理由见类头那一节。回调不带值、跑在主队列上；
    /// 重复调会先退掉上一次的观察（不会叠观察），与 `routeChange` 那条同一规矩。
    func startObservingMediaServices(_ handler: @escaping () -> Void) {
        stopObservingMediaServices()
        mediaServicesResetHandler = handler
        mediaServicesObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            // 同上面路由那条：`queue: .main` 是运行时事实，这里显式声明出来。
            MainActor.assumeIsolated { self?.mediaServicesResetHandler?() }
        }
    }

    /// 不盯了（`PlayManager` 拆的时候 / 本对象销毁时）。
    func stopObservingMediaServices() {
        if let mediaServicesObserver {
            NotificationCenter.default.removeObserver(mediaServicesObserver)
        }
        mediaServicesObserver = nil
        mediaServicesResetHandler = nil
    }

    /// 现在的出口是不是蓝牙**通话档**（HFP）—— 续播前问一句。
    ///
    /// 别的 App 抢麦克风（微信长按说话、语音备忘录）时，系统会把蓝牙从 A2DP 切到 HFP；
    /// 这时去激活我们的非混音会话会**把对方刚开的录音打断**。所以「要出声」之前先问它。
    var isCurrentRouteBluetoothHFP: Bool {
        currentOutputKinds().contains(.bluetoothHFP)
    }

    /// **别的 App 是不是正在出声** —— 回前台续播前问一句。
    ///
    /// 🔴 它是「抢回音频输出」的**第二道闸**：光有恢复票不够，别的 App 正在放时**不许抢**
    /// （用户刚点开别的音乐 App，我们一进去就把声音抢回来是耍流氓）。
    /// 判断在 `Decisions/AppActivationResumePolicy.swift`，这里只**现读**事实。
    var otherAudioIsPlaying: Bool {
        AVAudioSession.sharedInstance().isOtherAudioPlaying
    }

    /// 现读一份事实 —— 没有变更事件时的兜底（HFP 续播看门狗轮询用）。
    ///
    /// ⚠️ 这不是一次变更 ⇒ `reasonIsOldDeviceUnavailable` 填 `false`、旧 / 新出口都填**现读**的。
    /// 蓝牙那条判据只看新出口，不受影响。
    func currentRouteFacts() -> AudioRouteChangeFacts {
        let kinds = currentOutputKinds()
        return AudioRouteChangeFacts(
            reasonIsOldDeviceUnavailable: false,
            previousOutputs: kinds,
            currentOutputs: kinds
        )
    }

    /// 唯一的执行点 —— 把算好的方案落到系统上。
    ///
    /// ⚠️ `setActive` 是**同步**的、要等系统响应（几毫秒），所以它跑在调用它的那条线程上
    /// （＝主线程，`PlayManager` 里）。
    ///
    /// ⚠️ 两个方向各自的失败去向不同，所以分开接：
    /// - 「配类别 / 模式」失败 ＝ 参数写错（程序员 bug）⇒ `assertionFailure`；
    /// - 「激活」失败会**自愈** ⇒ 吞；
    /// - 「释放」失败**本来就常见**（打断中调用必然失败）⇒ 吞。
    private func apply(_ plan: AudioSessionPlan) {
        let session = AVAudioSession.sharedInstance()

        switch plan {
        case .activate(let category, let mode):
            do {
                try session.setCategory(category, mode: mode)
            } catch {
                // 「不可能发生的状态」：类别 / 模式是常量，写对后这条永不失败 ——
                // 走到这儿＝参数写错了（程序员 bug）。按宪法 §三·零容忍 1 用 assertionFailure，
                // 不给用户弹错；release 继续，声音按系统默认类别出去（＝降级行为）。
                assertionFailure("音频会话类别 / 模式非法：\(error)")
            }
            do {
                try session.setActive(true)
            } catch {
                // 敢吞：这条**会自愈** —— 被电话 / 其他 App 打断、切路由都会例行失败，库常自己恢复。
                // 去向：影响有界（这一次声音可能按系统默认类别出去、被静音键静掉）；
                // 自愈路径＝下一次起播 prepareForPlayback() 重配，不重试、不打扰用户。
                // 🔴 不弹错、不许跳歌或把状态打成 `.failed`：会话失败和「这首歌能不能放」是两回事。
            }

        case .deactivate:
            do {
                // 🔴 `notifyOthersOnDeactivation` 是**关键** —— 它才是「我让路了，你们可以起」那句通知。
                // 省掉它，别人的 App 仍要等系统来把我们中断一遍，这一刀就白做了。
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                // 敢吞：打断**中**调用 `setActive(false)` 本来就会失败，那不是错
                // （与上面 `setActive(true)` 那条"敢吞"同一条口径）。
                // 去向：下一次 `prepareForPlayback()` 会重新配、重新激活，不重试、不打扰用户。
            }
        }
    }

    /// 通知来了 ⇒ 收成一份值，交给外面。
    ///
    /// ⚠️ 观察挂在主队列上，所以这里就在主线程：可以**现读**当前路由
    /// （`userInfo` 里那份是变更**前**的旧路由）。
    private func handleRouteChange(_ note: Notification) {
        let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let previousOutputs = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription)?.outputs ?? []
        let facts = AudioRouteChangeFacts(
            // 比 `rawValue` 而不是 `init(rawValue:)` —— 那个初始化器的可失败性在 SDK 间不一致。
            reasonIsOldDeviceUnavailable: reasonValue
                == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            previousOutputs: previousOutputs.map { AudioRoutePortKind($0.portType) },
            currentOutputs: currentOutputKinds()
        )
        routeChangeHandler?(facts)
    }

    /// 现读当前出口、翻成我们的词。
    private func currentOutputKinds() -> [AudioRoutePortKind] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { AudioRoutePortKind($0.portType) }
    }

    deinit {
        // 通知的观察块被 `NotificationCenter` 持有 ⇒ 必须显式退订（代码标准第 13 条）。
        //
        // 🔴 **不写 `stopObservingRouteChanges()` / `stopObservingMediaServices()`**：`deinit` 在 Swift 里
        // **永远是非隔离的**，调不了本类的主隔离方法（编译器会拦）。这里直接摘句柄 ——
        // 那两个方法多出来的「顺手清掉 handler」在对象正在销毁时没有意义。
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        if let mediaServicesObserver {
            NotificationCenter.default.removeObserver(mediaServicesObserver)
        }
    }
}

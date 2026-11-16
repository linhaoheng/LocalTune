import AVFAudio

/// 一个输出口的「类」—— 把系统的 `AVAudioSession.Port` 收成我们自己的词。
///
/// 🔴 **判断层只吃这个，不碰会话对象。** 「读会话」留在执行层（`AudioSessionController`）；
/// 这里只是一个**值**，所以判断层能不带引擎跑单测。
///
/// ⚠️ 本文件用 `AVAudioSession.Port` 这个**值类型**（`String` 的包装）当构造入参 ——
/// 和 `AudioSessionPlan` 用 `AVAudioSession.Category` / `.Mode` 是同一条先例：
/// 碰的是值类型、不是 `AVAudioSession` 那个对象，判断层的「纯」没破。
enum AudioRoutePortKind: Equatable {
    /// 本机扬声器 / 听筒 —— 就是「外放」。
    case builtIn

    case airPlay

    case bluetoothA2DP

    /// 蓝牙**通话档** —— 别的 App 抢麦克风时系统会切到它。
    case bluetoothHFP

    case bluetoothLE

    /// 别的**外接**：有线耳机 / USB 耳放 / 车机 / HDMI……
    ///
    /// ⚠️ 判「是不是外接」看的是**「不是 `.builtIn`」**，不是在这里穷举 ——
    /// 新出的口类型一律落到这儿，也就自动算外接。
    case other

    /// 系统的 port 类型 → 我们的词。
    ///
    /// 值类型自己的构造（同 `init(rawValue:)`）：纯、无副作用、能单测 ——
    /// 所以「读会话」与「分类」这两件事分得开。
    init(_ port: AVAudioSession.Port) {
        switch port {
        case .builtInSpeaker, .builtInReceiver:
            self = .builtIn
        case .airPlay:
            self = .airPlay
        case .bluetoothA2DP:
            self = .bluetoothA2DP
        case .bluetoothHFP:
            self = .bluetoothHFP
        case .bluetoothLE:
            self = .bluetoothLE
        default:
            self = .other
        }
    }
}

/// 一次「系统换了音频出口」的快照 —— 判断层只吃它。
///
/// 🔴 **判断和执行两边都用**（`AudioSessionController` 产、`Decisions/` 消费）⇒ 归最底的
/// `Model/`。
struct AudioRouteChangeFacts: Equatable {

    /// 通知给的 reason 是不是 `.oldDeviceUnavailable`。
    ///
    /// ⚠️ **光看它不够** —— iOS 会在仍挂内建扬声器时发这个 reason（假通知），
    /// 也会在蓝牙 A2DP ↔ HFP 换档时报它。它只当外接丢失判据里**三个条件的一个**。
    let reasonIsOldDeviceUnavailable: Bool

    /// 变更**前**的出口（从通知的 `userInfo` 里取）。
    let previousOutputs: [AudioRoutePortKind]

    /// 变更**后**（现读）的出口。
    let currentOutputs: [AudioRoutePortKind]
}

/// 「蓝牙被抢到通话档之后，那趟续播还续不续」的结论。
///
/// 与 primuse 同名同义：`wait`（还不能动，票留着）/ `discard`（票作废）/ `resume`（接着放）。
enum BluetoothDeferredResumeDecision: Equatable {
    /// 现在还不能动（还在通话档 / 不欠打断收尾）—— 票留着，等下一次。
    case wait

    /// 这张票作废了（票主不是当前曲 / 用户已经不想听）—— 清掉，绝不偷偷响起来。
    case discard

    /// 条件齐了 —— 接着放。
    case resume
}

/// 一次 `routeChange` 该怎么处理 —— 判断层的**唯一出口**。
///
/// 🔴 返回 enum、不返回 `Bool`：出口要说清「是哪一种」，
/// 顺带把处理**顺序**（AirPlay 重抢 → 外接丢失暂停 → 蓝牙延期续播）钉在判断层一处，
/// 执行层不再自己排。
enum AudioRouteChangeAction: Equatable {
    /// 什么都不做。
    case none

    /// AirPlay 回到本机 ⇒ 重抢本地会话焦点并接着放。
    case reacquireAfterAirPlay

    /// 外接真丢了（拔耳机 / 蓝牙断开）⇒ 暂停，别外放。
    case pauseForExternalLoss

    /// 蓝牙被抢到通话档 ⇒ 按这张结论处理。
    case bluetoothDeferred(BluetoothDeferredResumeDecision)
}

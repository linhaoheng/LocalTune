import AVFAudio

/// 会话「为什么来」—— 调用方只说理由，「配成什么样」由判断算。
///
/// ⚠️ 两个理由是**方向相反**的：一个要**拿**输出、一个要**还**输出。
/// 以后再来别的（打断结束 / 耳机拔插那几种）**只往这个 enum 里加 case** ——
/// 判断加一条、执行那边一个字不用改。
///
/// 🔴 这是值类型，放 `Model/`（判断和执行同源）：
/// - 判断（`SessionPlanPolicy`）收它当输入；
/// - 它和 `AudioSessionPlan` 一起构成"会话这件事"的词汇表。
enum AudioSessionReason {
    /// 要开始出声了 —— 拿输出。
    case willStartPlayback

    /// 不出声了 —— 把输出**还回去**（别占着，让别的 App 能立刻起）。
    case didStopPlayback
}

/// 会话该配成什么样 —— 判断的**输出值**。
///
/// ⚠️ 这里用 `AVAudioSession.Category` / `.Mode`，但**没有碰 `AVAudioSession` 那个对象** ——
/// 它俩本身就是值类型（`String` 的包装），能在测试里直接构造出来。判断层的"纯"没破。
///
/// 🔴 **为什么是 `enum` 不是「带各种开关的 `struct`」**：
/// 会话这件事有**两个方向相反**的动作 —— **激活**（配类别 ＋ 起）和**释放**（关掉、通知别人）。
/// 拿一个 `struct` 加个 `shouldActivate = false` 来表达"释放"，会连带表达出
/// "**要释放了还得先把类别配一遍**"这种不存在的组合（会话都要关了，配类别是多余动作）。
/// 换成 enum，`.deactivate` **没有** `category` / `mode` 可填 —— 组合非法就写不出来。
///
/// 🔴 这是值类型，放 `Model/`：
/// - 判断（`SessionPlanPolicy`）产它；
/// - 执行（`AudioSessionController.apply(_:)`）消费它。
enum AudioSessionPlan: Equatable {
    /// 配成这类别 / 模式，并**拿**输出。
    case activate(category: AVAudioSession.Category, mode: AVAudioSession.Mode)

    /// **还**输出（`setActive(false, .notifyOthersOnDeactivation)`）。
    case deactivate
}

/// 「现在这个状态，该不该把输出还回去」—— 判断的**输出值**。
///
/// 🔴 **为什么是 enum 不是 `Bool`**：这是 `SessionPlanPolicy` 的
/// **具名出口**，两个答案的后果差得很远 —— `.release` 是**同步跨进程**把会话关掉，
/// `.keepActive` 是**一个字都不动**。一个 `Bool` 传到调用点只剩 `guard x else { return }`，
/// 读的人得回去翻函数名才知道 `true` 到底代表「还」还是「留」（两种读法都通顺，早晚读反）。
///
/// 🔴 这是值类型，放 `Model/`：
/// - 判断（`SessionPlanPolicy`）产它；
/// - 执行（`PlayManager` 那条订阅）消费它。
enum AudioSessionRelease: Equatable {
    /// 真·不出声了（播完 / 没放成 / 什么都没装）—— 把输出**还回去**。
    case release

    /// 留着，别动 —— 暂停 / 在播 / 在装。
    ///
    /// ⚠️ 和 `.release` 的差别**不是程度、是方向**：`deactivate()` 是同步跨进程调用，
    /// 「先还了、要播再拿回来」不是等价做法 —— 中间那段时间别人能把输出抢走。
    case keepActive
}

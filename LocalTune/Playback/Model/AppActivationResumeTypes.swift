import Foundation

/// 「回到前台，被打断那一首该不该自己续」—— 判断的**输出值**。
///
/// 判据本身在 `Decisions/AppActivationResumePolicy.swift`（纯函数、两项输入），这里只有结论。
///
/// 🔴 **为什么是 enum 不是 `Bool`**：这是那个判据的**具名出口**。
/// `.resume` 会**抢回音频输出**（起引擎、出声），`.keepHeld` 一个字都不动；一个 `Bool`
/// 到了 `resumeAfterAppActivationIfSafe()` 里就是 `guard x else { return }`，
/// 而「x 为真 ＝ 续」这个约定只活在函数名里，读的人得回去对一遍。
///
/// 🔴 这是值类型，放 `Model/`：
/// - 判断（`AppActivationResumePolicy`）产它；
/// - 执行（`PlayManager`）消费它。
enum AppActivationResumeDecision: Equatable {
    /// 票还在 ＋ 别的 App 没在放 ⇒ **续**（唯一该续的一格）。
    case resume

    /// 不续 —— **票原样留着**，用户点播放仍然是出口。
    ///
    /// ⚠️ 两种来路落进这一格：没有票（用户自己按的暂停）、别的 App 正在放（不许抢）。
    /// 两种的后果一样（什么都不做），所以不拆成两个 case。
    case keepHeld
}

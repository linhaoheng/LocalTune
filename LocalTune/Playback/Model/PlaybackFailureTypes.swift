import Foundation

/// 「这一首放不了」之后该怎么办 —— 判断的**输出值**。
///
/// 🔴 **为什么在 `Model/` 而不是 `Decisions/`**：判断（`Decisions/PlaybackFailurePolicy.swift`）
/// 产它，执行（`Queue/PlayManager.handleFailure`）拿它决定跳不跳 —— **两边都用**
/// ⇒ 抽到最底 `Model/`。
///
/// 两种失败要分开：
/// - **这一首自己的事**（文件被外面删了、格式坏了）→ 跳过它，接着放下一首；
/// - **不是哪一首的事**（存储掉了、卡没挂上）→ 连着几首都放不了，再往下跳只是让条子
///   唰唰唰地跳给用户看，还不如停下给个交代。
enum PlaybackFailureRecovery: Equatable {

    /// 跳过这一首，接着放下一首。
    case skipToNext

    /// 停下 —— 已经不是"哪一首"的问题了。
    case giveUp
}

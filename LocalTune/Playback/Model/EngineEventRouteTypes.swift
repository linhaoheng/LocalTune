import Foundation

/// 引擎来的一条事件，该走哪条路。
///
/// 判断（`engineEventRoute`）产它、执行（`PlayManager`）按它分路 ⇒ 归 `Model/`。
enum EngineEventRoute: Equatable {
    /// 上一次点播迟到的事 —— 扔掉。
    case stale
    /// 正在放的这一首的事。
    case current
    /// 库**自己往后走了**：号比当前大，只可能是我们排过的下一首。
    /// `isArmed` ＝ 它是不是**现在排着的那张**（不是 ⇒ 是被换掉之前已经提交的孤儿）。
    case successor(isArmed: Bool)
}

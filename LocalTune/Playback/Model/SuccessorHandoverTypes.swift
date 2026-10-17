import Foundation

/// 库自己换到下一首时，认不认。
///
/// 判断（`successorHandover`）产它、执行（`PlayManager`）按它走 ⇒ 归 `Model/`。
enum SuccessorHandover: Equatable {
    /// 换过去的就是队列说的下一首 —— 状态跟着换。
    case accept
    /// 换错了 —— 立即播放队列说的那首（或者队列到头了 ⇒ 停）。
    case redirect
}

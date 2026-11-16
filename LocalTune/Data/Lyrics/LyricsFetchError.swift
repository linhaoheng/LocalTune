import Foundation

/// 取词的两种收尾 —— 「没找到」与「连不上」。
///
/// 🔴 语义上**不是**"这首歌没有词"的证据（`LookupOutcome` 那条纪律）——
/// 所以 `.unreachable` 的文案只说网络，不许暗示"没这首歌的歌词"。
enum LyricsFetchError: LocalizedError {

    /// 服务器明确说没有（空候选 / 空正文）。
    case notFound

    /// 连不上 / 超时 / `5xx` / 限流 / 响应不成形。
    case unreachable

    /// 人话 —— **非可选那一版**，给页面 / 浮层直接用。
    var message: String {
        switch self {
        case .notFound: return "没找到这首歌的歌词"
        case .unreachable: return "网络不可用，稍后再试"
        }
    }

    var errorDescription: String? { message }
}

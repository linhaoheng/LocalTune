import Foundation

/// 变速五档。用枚举不用 `Float`：档位穷举，给节点的数字由纯函数翻。
enum PlaybackRate: String, Equatable, CaseIterable, Codable {
    case x075
    case x1
    case x125
    case x15
    case x2

    /// 列表上那几个字。`1` 写成 `1×`，其余去尾零。
    var title: String {
        switch self {
        case .x075: "0.75×"
        case .x1: "1×"
        case .x125: "1.25×"
        case .x15: "1.5×"
        case .x2: "2×"
        }
    }
}

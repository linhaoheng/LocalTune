import Foundation

/// 时间单位换算常量 —— 别在代码里散 `1000`。
enum TimeUnit {
    /// 一秒有多少毫秒（KRC 布局用毫秒，我们模型用秒）。
    static let millisecondsPerSecond: Double = 1_000
}

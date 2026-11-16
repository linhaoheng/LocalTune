import Foundation

/// `PlaybackError` 的**显示用**扩展：把「哪一种失败」翻成一个给人看的短词。
///
/// 🔴 **为什么单独一个文件**：`PlaybackErrorTypes.swift` 回答「有哪几种失败」，
/// 这里回答「这种失败叫什么」—— 是两件事，分开之后找显示逻辑不用去类型文件里翻。
/// 跟 `Track+Display` / `ImportResult+Display` 是同一个模式。
///
/// 🔴 **判断标准只有一条：它不依赖任何界面框架**（不 `import UIKit`、不碰 `HUD`）。
/// 所以它只吐**短词**，**不拼整句** —— 「已跳过 / 已停止」「前面挂哪个歌名」都取决于
/// 执行结果（跳没跳成）和当前曲目，那两样只有播放页知道。
///
/// ⚠️ 这里**不出现 `HUD.Style`**：`HUD` 在 `Components/`（`import UIKit`），
/// 播放域指不了它。三态的语气统一是「出错」，由播放页决定。
extension PlaybackError {

    /// 这一种失败叫什么 —— 短词，供播放页拼进整句。
    var displayText: String {
        switch self {
        case .fileMissing:       return "找不到文件"
        case .unsupportedFormat: return "格式不支持"
        case .engineFailed:      return "播放出错了"
        }
    }
}

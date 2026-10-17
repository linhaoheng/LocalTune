import Foundation

/// `Track` 的**显示用**扩展：从一份数据里"算出给人看的文字"。
///
/// 🔴 **为什么单独一个文件**：`Track.swift` 回答「数据长什么样」，这里回答
/// 「怎么显示成一行字」，是两件事 —— 分开之后找显示逻辑不用去数据文件里翻。
///
/// 🔴 **判断标准只有一条：它不依赖任何界面框架**（不 `import UIKit`、不碰任何视图控件）。
/// 这样分层方向是对的 —— 界面依赖数据，数据不依赖界面。
/// 哪天它需要知道字体、颜色、或者 `UILabel`，就必须搬到显示层去，不能留在这儿。
extension Track {

    /// 列表行副标题用的「艺人 - 专辑」。
    ///
    /// 空 / 只有空白就换成「未知艺人」「未知专辑」，中间用 `" - "` 连起来。
    var artistAlbumLine: String {
        "\(Self.displayName(artist, empty: "未知艺人")) - \(Self.displayName(album, empty: "未知专辑"))"
    }

    /// 时长文本：不到一小时写 `分:秒`（分钟补零，`03:05`），满一小时写 `时:分:秒`
    /// （小时不补零，`1:05:07`）。
    ///
    /// 🔴 拆秒这件事**不在这儿做** —— 规则在 `DurationText`（播放页那两个时间标签
    /// 用的是同一份）。这里只管两件事：**毫秒先四舍五入到秒**（不是截断：
    /// `119_600 ms` 该显示 `02:00`，截断会少报一秒），以及**读不出来就 `nil`**。
    ///
    /// 读不出来（`nil`）、或者压根不成立（`<= 0`）都返回 `nil`，占位符由显示方自己定。
    /// 这里**不用 `max(0, …)` 去夹**：写进来的本来就只会是 `> 0` 的值，
    /// 0 和负数只可能是坏数据 —— 那就该说「不知道」，而不是报一个 `00:00`。
    var durationText: String? {
        guard let durationMs, durationMs > 0 else { return nil }
        return DurationText.text(seconds: Int((Double(durationMs) / 1000).rounded()))
    }

    private static func displayName(_ value: String, empty fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

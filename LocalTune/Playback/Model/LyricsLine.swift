import Foundation

/// 一个逐字音节 —— 增强 LRC 里 `<mm:ss.xx>` 切出来的一个词。
///
/// 行级歌词没有逐字数据，`LyricsLine.syllables` 就是 `nil`。
struct LyricSyllable: Hashable {

    var text: String
    var start: TimeInterval
    var end: TimeInterval

    init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// 一行歌词（值，零行为）。
struct LyricsLine: Hashable {

    /// 行起点，秒。
    var timestamp: TimeInterval

    /// 正文。带逐字标签的行，这里已经是**剥掉标签**的纯文字。
    var text: String

    /// 能不能跟拍滚动、能不能点这一行跳转。
    ///
    /// 纯文本歌词（一个时间戳都没有）每行都是 `false`：它的 `timestamp` 只是
    /// 占位 `0`，不代表"在第 0 秒唱"。
    var isSynchronized: Bool

    /// 逐字数据；`nil` = 行级歌词。
    var syllables: [LyricSyllable]?

    /// 文件里**写在同一时间戳**上的附属行 —— 第一条当首选译文。
    ///
    /// 来源是双语 LRC：
    /// ```
    /// [00:12.00]I love you
    /// [00:12.00]我爱你
    /// ```
    /// 文件里的先后顺序就是作者想要的阅读顺序，我们**不猜**哪一条是注音、
    /// 哪一条是翻译，只按顺序摆。
    var manualTranslation: String?

    /// 同一时间戳上的第 2、第 3 条附属行，按文件顺序。
    var alternateTranslations: [String]

    init(
        timestamp: TimeInterval,
        text: String,
        isSynchronized: Bool? = nil,
        syllables: [LyricSyllable]? = nil,
        manualTranslation: String? = nil,
        alternateTranslations: [String] = []
    ) {
        self.timestamp = timestamp
        self.text = text
        // 不传就自己推：有时间戳、或者有逐字，才算"跟得上拍"。
        self.isSynchronized = isSynchronized ?? (timestamp > 0 || syllables?.isEmpty == false)
        self.syllables = syllables
        self.manualTranslation = manualTranslation
        self.alternateTranslations = alternateTranslations
    }

    /// 行下要显示的全部附属字，**按文件里的顺序**（首选译文在前）。界面用。
    var companionTexts: [String] {
        (manualTranslation.map { [$0] } ?? []) + alternateTranslations
    }
}

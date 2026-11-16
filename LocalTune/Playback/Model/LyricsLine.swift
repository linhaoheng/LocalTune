import Foundation

/// 一个音节的**结束时间是从哪儿来的**。
///
/// 只有"起点式"的格式（ELRC 一行 `<mm:ss.xx>字` 排下去）需要分清这一格：
/// 一个字的结束靠**下一个字的标记**表达，所以"这个结束是数据给的"与
/// "这个结束是我顺着下一个字推出来的"在文本里长得一模一样，
/// 不记来源就分不出**该不该把它写出去**（照 primuse `LyricSyllableEndTiming`）。
///
/// - `explicit`：源档直接给了「这个字唱多久」—— **只剩 KRC 布局的「字长」一种**。
/// - `inferred`：结束是**顺下一格的起点**读出来的。ELRC 只写起点；后面没有下一格就推不出来，
///   `end == start`（零长）—— 这正是"末字一开口就满亮"的来源，**不兜底**。
///
/// ⚠️ 句尾那一格（`isLineEnd`，正文里最后一个空块）**不是字**：它的 `end` 恒等于 `start`，
/// 不参与任何判断 —— 末字的结束就是从**它的起点**推出来的。
///
/// ⚠️ 2026-11-17 起 `explicit` 少了一条来源：ELRC 行末空块不再塞给末字（它自己站一格）。
/// 编辑页打点 / 微调**不再改写这一栏**：它们只动 `inferred` 那一半的 `end`
/// （`endTiming != .explicit` 才拉走），KRC 布局的明写字长原样留着 —— 照 primuse
/// `stampSyllable` / `nudgeSyllable` 的守卫。
enum LyricSyllableEndTiming: Hashable {
    case explicit
    case inferred
}

/// 一个逐字音节 —— 增强 LRC 里 `<mm:ss.xx>` 切出来的一个词。
///
/// 行级歌词没有逐字数据，`LyricsLine.syllables` 就是 `nil`。
///
/// ## 🔴 数组里装的是两种东西：字，和「这一行的结束」
///
/// ELRC 每句末尾那个 `<mm:ss.xx>` 后面不跟文字 —— 它是**句尾时间**。我们把它
/// 留成数组的**最后一项**（`text` 为空），因为编辑器需要它才能把"这一句唱到几秒"
/// 打下来、`±` 调、点着听。它**不是字**：不唱、不扫光、不算进字数。
///
/// 判据只有一条（`isLineEnd`），**别在别处再写一遍 `text.isEmpty`** ——
/// 写得多了就有人漏掉，漏一处就会出现"句尾格被当成一个字扫了个空"。
struct LyricSyllable: Hashable {

    var text: String
    var start: TimeInterval
    var end: TimeInterval

    /// `end` 的出处。默认 `.explicit`：调用方既然给了一个具体的结束时间，
    /// 那就是数据（推出来的那种由解析器显式标 `.inferred`）。
    var endTiming: LyricSyllableEndTiming

    init(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        endTiming: LyricSyllableEndTiming = .explicit
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.endTiming = endTiming
    }

    /// 这一项是不是「这一行的结束」那一格，而不是一个字。
    ///
    /// 🔴 唯一的判据：**没有文字**。正文里句尾那个空块不写字，它唯一的职责是把
    /// 句尾时间写下来 —— 编辑侧拿它当一格打点，播放侧拿它的 `start` 当末字的结束。
    var isLineEnd: Bool { text.isEmpty }
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

    /// **显式行尾**（KRC 布局的「行长」）；LRC / ELRC 没有这个信息，是 `nil`。
    ///
    /// 为什么需要它：KRC 布局每行都带行长，行级 KRC 布局（没有字块）的行尾只能从这里来；
    /// 丢了它，KRC 布局往返一次行长就变成 0。
    var endTimestamp: TimeInterval?

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
        endTimestamp: TimeInterval? = nil,
        manualTranslation: String? = nil,
        alternateTranslations: [String] = []
    ) {
        self.timestamp = timestamp
        self.text = text
        // 不传就自己推：有时间戳、或者有逐字，才算"跟得上拍"。
        self.isSynchronized = isSynchronized ?? (timestamp > 0 || syllables?.isEmpty == false)
        self.syllables = syllables
        self.endTimestamp = endTimestamp
        self.manualTranslation = manualTranslation
        self.alternateTranslations = alternateTranslations
    }

    /// 行下要显示的全部附属字，**按文件里的顺序**（首选译文在前）。界面用。
    var companionTexts: [String] {
        (manualTranslation.map { [$0] } ?? []) + alternateTranslations
    }

    /// 最后一个**字** —— 跳过句尾那一格。
    ///
    /// 🔴 想在 `syllables` 末尾取"末字"的地方都用它，别写 `syllables.last` ——
    /// 末项是「这一行的结束」（见 `LyricSyllable.isLineEnd`），它的 `end` 是句尾时间，
    /// 拿它当"末字唱到几秒"会看着一样、但拿它当"末字"去量字长就是零。
    var lastWord: LyricSyllable? {
        syllables?.last(where: { !$0.isLineEnd })
    }
}

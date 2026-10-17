import UIKit

/// 语义字号层 —— **业务代码唯一该碰的字号入口**。
///
/// 三层：页面 → `AppFont`（本文件，语义）→ `FontScale`（真值）→ `UIFont.scaled(_:weight:)`（机制）。
/// 页面里不写 `systemFont(ofSize:)` —— 那样「这个 15 是随手写的还是定下来的」就分不清了。
///
/// 这里只写「哪儿用哪一号」，每一档都指向 `FontScale`；要调字号，改 `FontScale` 一处就够。
enum AppFont {

    /// 列表主标题（曲名）。
    static var songTitle: UIFont { FontScale.p4 }

    /// 列表副标题（艺人）。
    static var songSubtitle: UIFont { FontScale.p6 }

    /// 列表行里那个**格式标记**（`FLAC` / `ALAC` / `MP3`）。
    ///
    /// **9 中等**（`h7`）。
    ///
    /// ⚠️ 跟下面徽章那个 **8 粗** 是**两档不同的字重、也不同字号**，别合成一个：
    /// 两枚挨着站时，刻意让"格式名"比"档位"轻一点、也小一点。
    static var formatTag: UIFont { FontScale.h7 }

    /// 列表行那枚音质徽章里那两个字（`SD` / `HQ` / `SQ` / `HR`）。
    ///
    /// **8 粗**（`boldP8`）。
    ///
    /// ⚠️ 比旁边那个格式标记**小一号**（9 → 8）：那点层次是刻意的。
    /// ⚠️ 也跟播放页那枚**不是一档**（那枚是 9 粗）—— 两处共用一个字号，必有一处偏。
    static var songRowQualityBadge: UIFont { FontScale.boldP8 }

    /// 列表行「耳机 + 播放次数」—— 图标与数字同号。
    ///
    /// **11 常规**（`p6`）—— 图标与数字同号，所以是点尺寸 11。
    static var songRowPlayCount: UIFont { FontScale.p6 }

    /// 歌单名。
    static var playlistTitle: UIFont { FontScale.boldP3 }

    /// 歌单副标题（曲目数）。
    static var playlistSubtitle: UIFont { FontScale.p5 }

    /// 歌单详情页表头那两个键上的字（「播放」/「随机播放」）。
    ///
    /// **15 粗**（`boldP4`）—— 跟列表行歌名（`songTitle` = 15 常规）**同字号、不同字重**：
    /// 那两个键是"一整块可以按的东西"，字得比旁边的正文实一点。
    static var playlistActionTitle: UIFont { FontScale.boldP4 }

    /// 页面级的主提示 —— 一整页只有一句话那种（比如「曲库打不开」）。
    static var pageTitle: UIFont { FontScale.h3 }

    /// 页面级的说明文字 —— 主提示下面那段解释。
    static var pageMessage: UIFont { FontScale.p5 }

    /// 空状态那一行说明（「您的音乐库中没有歌曲」）。
    ///
    /// 跟歌名那种"一句话是主角"的档位（`p3`）—— 空状态整页就这一句话，
    /// 用副标题那一档（`p6`）会小得像个脚注。
    static var emptyStateMessage: UIFont { FontScale.p3 }

    /// 浮层主文案（「已导入 3 首」）。
    ///
    /// 跟列表主标题同一档（`p4`）—— 浮层的效果要求见映射表 §3。
    static var hudMessage: UIFont { FontScale.p4 }

    /// 迷你播放条上的歌名。
    ///
    /// **15 半粗**（`FontScale.h4`）—— 条子上这条字要比列表行里那个歌名**实一点**：
    /// 它单独占一行、周围没有别的内容帮它分层次。
    ///
    /// ⚠️ 跟列表行里那个歌名（`p4`，15 常规）**同字号、不同字重**。
    /// ⚠️ **条子上只有这一行**：不放艺人 —— 条子只有 60 高，两行会挤。
    static var miniPlayerTitle: UIFont { FontScale.h4 }

    /// 索引条按下时、**屏幕正中那个气泡**里的大字母。
    ///
    /// 用到最大那一档（`p1`）—— 它就是"一屏一个字"的用法，24 就是为它定的。
    static var indexBubbleLetter: UIFont { FontScale.p1 }

    // MARK: - 播放页

    /// 播放页上的歌名。
    ///
    /// 用 **19 medium**（`h2`）—— 它是整页最大的一行字。
    /// ⚠️ 19 是这么定的：信息行标题那格高 **23**，19 号字的行高正好落在这一档（≈ 22.8）。
    static var nowPlayingTitle: UIFont { FontScale.h2 }

    /// 播放页上的艺人 / 专辑。
    ///
    /// **13 常规**（`p5`）。
    ///
    /// ⚠️ 曾经写成"跟列表副标题（`songSubtitle`）**同一档**" —— 那是错的：
    /// 副标题是 **11 常规**（`p6`），跟它压根不是一档，两者也不相干。
    static var nowPlayingArtist: UIFont { FontScale.p5 }

    /// 音质那一条的**说明文字**（`FLAC · 16bit/44.1kHz`）。
    ///
    /// **11 中等**（`h6`）。
    ///
    /// ⚠️ 曾经写成 **11 常规**（`p6`）—— 那是"它比艺人低一档"自己推的，字重不对。
    /// ⚠️ 它跟艺人那一档（`nowPlayingArtist` = 13 常规）**是两个不同角色**，别看着
    /// "都是说明文字"就并成一个 —— 这两个是 medium 与 regular 之别。
    static var nowPlayingQuality: UIFont { FontScale.h6 }

    /// 播放页那枚音质徽章里那两个字。
    ///
    /// **9 粗**（`boldP7`）。
    ///
    /// ⚠️ 跟列表行那枚（`songRowQualityBadge` = 8 粗）**差一号**，是刻意分开的
    /// —— 播放页地方大、徽章能大一点；列表行那枚旁边站着 9pt 的格式标记，得比它小。
    static var nowPlayingQualityBadge: UIFont { FontScale.boldP7 }

    /// 进度条两头的时间。
    ///
    /// **11 常规**（`p6`）—— 也是说明性的。
    static var nowPlayingTime: UIFont { FontScale.p6 }

    // MARK: - 播放页 · 歌词

    /// 歌词**正文**：当前行粗体、其余行常规体（并缩到 0.9×）。
    ///
    /// ⚠️ 这一档跟别的不一样，它**收字号**而不是指向 `FontScale` 的某一档 ——
    /// 歌词字号是**用户可调**的（`AppMetrics.nowPlayingLyricsFontSize`，4c 接设置面板），
    /// 写死一档就调不动了。也用不了 `FontScale` 那条 Dynamic Type 管线：歌词尺寸由
    /// 列表自己的算法撑行高，跟着系统字号变会让"算出来的行高"和"画出来的字"对不上。
    /// 缩放常数（普通行 0.9×）在 `AppMetrics`，理由见那儿。
    static func lyricsLine(baseSize: CGFloat, isCurrent: Bool) -> UIFont {
        isCurrent
            ? .systemFont(ofSize: baseSize, weight: .bold)
            : .systemFont(ofSize: baseSize * AppMetrics.nowPlayingLyricsNormalFontScale, weight: .regular)
    }

    /// 歌词**行下附属字**（内嵌歌词里本来就带的译文 / 注音）：`base × 0.65`、中等。
    static func lyricsCompanion(baseSize: CGFloat) -> UIFont {
        .systemFont(ofSize: baseSize * AppMetrics.nowPlayingLyricsCompanionScale, weight: .medium)
    }

    /// 「暂无歌词」占位的主句 —— 跟歌词同字号、常规体。
    static func lyricsPlaceholder(baseSize: CGFloat) -> UIFont {
        .systemFont(ofSize: baseSize, weight: .regular)
    }

    // MARK: - 播放页 · 歌词设置面板

    /// 面板标题（「歌词显示设置」）—— **18 粗**。
    ///
    /// 🔴 **不落 `FontScale` 某一档**：18 不在那八档里（17 是 `s3`、19 是 `s2`）—— 就写死 18。
    /// ⚠️ 也**不跟系统字号缩放**：面板的高是按它算死的（`AppMetrics.lyricsSettingsContentHeight`），
    /// 跟着变会让"算出来的高"和"画出来的字"对不上。
    static var lyricsSettingsTitle: UIFont { .systemFont(ofSize: 18, weight: .bold) }

    /// 面板里每个段的标题（「对齐方式」/「文字大小」）—— **16 中等**。
    static var lyricsSettingsSectionTitle: UIFont { .systemFont(ofSize: 16, weight: .medium) }

    /// 面板里字号那枚读数 —— **16 medium 等宽数字**（`monospacedDigitSystemFont`）。
    ///
    /// ⚠️ 用等宽数字：不然滑杆从 20 拖到 19 时整块读数会左右晃。
    static var lyricsSettingsValue: UIFont { .monospacedDigitSystemFont(ofSize: 16, weight: .medium) }

    /// 面板底部「关闭」—— 跟队列页那颗**同一档**（`FontScale.p4`）。
    static var lyricsSettingsCloseTitle: UIFont { FontScale.p4 }

    // MARK: - 队列页

    /// 表头「当前播放(N)」—— 粗体 `p5`。
    static var queueHeaderTitle: UIFont { FontScale.boldP5 }

    /// 每行的歌名 —— `p5`。
    static var queueRowTitle: UIFont { FontScale.p5 }

    /// 底部「关闭」—— `p4`。
    static var queueCloseTitle: UIFont { FontScale.p4 }

    // MARK: - 歌曲信息编辑页

    /// 编辑页每一行左边的字段名（「标题:」那一列）。
    static var editorFieldTitle: UIFont { FontScale.boldP4 }

    /// 编辑页输入框 / 只读值。
    static var editorFieldValue: UIFont { FontScale.p4 }

    // MARK: - 编辑歌词页

    /// 📍 本节是编辑歌词页的版式规格，字号逐个标在下面。
    ///
    /// ⚠️ **有意不落 `FontScale`**：这一页是**写死的字号**（不跟系统字号缩放），
    /// 跟旁边那个歌词设置面板同一个理由 —— 这一页上有好几处"版式的和"（歌曲条 68、键高 48/38/30…），
    /// 字号跟着系统变，算出来的高和画出来的字就对不上了。**就写死**。

    /// 歌曲条：歌名 **15 半粗**· 艺人 **12 常规**· 当前时间 **12 等宽中等**。
    static var lyricsEditorSongTitle: UIFont { .systemFont(ofSize: 15, weight: .semibold) }
    static var lyricsEditorSongArtist: UIFont { .systemFont(ofSize: 12) }
    static var lyricsEditorSongTime: UIFont { .monospacedDigitSystemFont(ofSize: 12, weight: .medium) }

    /// 逐行行里（对齐工作台 `LyricsStudioLineRowView`）：已打轴时刻 **11 等宽常规**·
    /// 未打轴「打点」**10 中等**· 正文 **13 常规**· 问题角标 **11 常规**。
    static var lyricsEditorRowTime: UIFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
    static var lyricsEditorRowStamp: UIFont { .systemFont(ofSize: 10, weight: .medium) }
    static var lyricsEditorRowText: UIFont { .systemFont(ofSize: 13) }
    static var lyricsEditorRowIssue: UIFont { .systemFont(ofSize: 11) }

    /// 打轴面板：上一句 / 下一句 **14 常规**· 行号 **12 中等**·
    /// 当前时间 **16 等宽半粗**· 当前句 **22 半粗**· 汇总 **12 常规**。
    static var lyricsEditorTimingNeighbor: UIFont { .systemFont(ofSize: 14) }
    static var lyricsEditorTimingLineNumber: UIFont { .systemFont(ofSize: 12, weight: .medium) }
    static var lyricsEditorTimingCurrentTime: UIFont { .monospacedDigitSystemFont(ofSize: 16, weight: .semibold) }
    static var lyricsEditorTimingCurrentLyric: UIFont { .systemFont(ofSize: 22, weight: .semibold) }
    static var lyricsEditorTimingSummary: UIFont { .systemFont(ofSize: 12) }

    /// 打轴面板那条主键上的字：**16 半粗**。
    static var lyricsEditorPrimaryButton: UIFont { .systemFont(ofSize: 16, weight: .semibold) }

    /// 底部工具条每颗键上的字：**13 中等**。
    static var lyricsEditorToolbarButton: UIFont { .systemFont(ofSize: 13, weight: .medium) }

    /// 原文那个文本框里的字：**14 等宽常规**。
    static var lyricsEditorSource: UIFont { .monospacedSystemFont(ofSize: 14, weight: .regular) }

    /// 逐字块上的两行：词 **12 中等** · 起点时间 **9 等宽常规**。
    ///
    /// ⚠️ 时间那一档是**块里最轻的一行**（比词还小 3 档）—— 一块的正面是"字"，时间是脚注。
    /// 曾经取 11：块里两行几乎一样重，一排过去像一串时间码。
    static var lyricsEditorSyllableChip: UIFont { .systemFont(ofSize: 12, weight: .medium) }
    static var lyricsEditorSyllableChipTime: UIFont { .monospacedDigitSystemFont(ofSize: 9, weight: .regular) }

    /// 当前字细条（对齐工作台 `adjustmentRow`）：`k/n` **11 中等** · 时间 **10 等宽常规**。
    ///
    /// ⚠️ 时间那一档**不是主文字**（10 常规），跟块上那颗一份口径 —— 细条是"哪一格"的说明，
    /// 不是一屏的主角。`±` 两颗键改画 **SF Symbol（`minus` / `plus`，10 半粗）**，不再用文字 ⇒
    /// 不再有"小键字体"这一档。
    static var lyricsEditorSyllableDetailIndex: UIFont { .systemFont(ofSize: 11, weight: .medium) }
    static var lyricsEditorSyllableDetailTime: UIFont { .monospacedDigitSystemFont(ofSize: 10, weight: .regular) }

    // MARK: - 均衡器

    /// EQ 页自绘顶栏标题。`h3`。
    static var equalizerTitle: UIFont { FontScale.h3 }

    /// 「保存自定义 / 重置」。`p5`。
    static var equalizerHeaderAction: UIFont { FontScale.p5 }

    /// 预设卡标题。`15 medium`。
    static var equalizerPresetTitle: UIFont { FontScale.h4 }

    /// 预设卡「已选中 / 选择」。12；字号表没有 12，就近 `p5`（13）。
    static var equalizerPresetStatus: UIFont { FontScale.p5 }

    /// 频段上下两个数字。12；同上走 `p5`。
    static var equalizerBandLabel: UIFont { FontScale.p5 }

    // MARK: - 睡眠定时

    /// 选中行倒计时 `分:秒`。`p5`（13）。
    static var sleepTimerRemaining: UIFont { FontScale.p5 }

    /// 开关下面那句说明。系统 footnote，就近 `p6`。
    static var sleepTimerFooter: UIFont { FontScale.p6 }

    // MARK: - 歌单封面流

    /// 封面下流歌名 **21 半粗**、艺人 **13 中黑**。
    ///
    /// ⚠️ **不进 FontScale 八档**：最近是 19 / 15 / 13，硬套会差 pt。
    /// 只这一块用，跟歌词编辑器那几处同一条。
    static var coverFlowTitle: UIFont { .systemFont(ofSize: 21, weight: .semibold) }
    static var coverFlowSubtitle: UIFont { .systemFont(ofSize: 13, weight: .medium) }
}

// ⚠️ 上面必须是计算属性（`var`），不能写成 `let`：
// 字号取决于**当前**的系统文字大小，缓存住就再也不会跟着变了。

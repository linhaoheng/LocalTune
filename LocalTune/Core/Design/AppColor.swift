import UIKit

/// 语义色层 —— **业务代码唯一该碰的颜色入口**。
///
/// 三层：页面 → `AppColor`（本文件，语义）→ `RadixPalette`（令牌）→ `UInt32` 色值。
/// 换主题、换深浅只改下面两层，页面一行都不用动。
///
/// 灰阶统一用 Slate（蓝调灰，与强调色 blue 同族）。阶位含义按 Radix 官方约定：
/// 1-2 背景 · 3-5 表面与交互 · 6-8 边框 · 9-10 实色 · 11-12 文字。
enum AppColor {

    // MARK: - 强调色

    /// 主强调色：导航、按钮、播放控件、链接。
    static let accent = RadixPalette.blue9.uiColor

    /// 破坏性操作：删除。
    static let destructive = RadixPalette.red9.uiColor

    /// 实心强调色块上的文字（强调色按钮上的字）。
    ///
    /// 色板里只有带透明度的 `whiteA1…A12`，**没有不透明的白** ——
    /// 而实色底上的文字必须不透明，所以这一档直接取系统白。
    static let onAccent = UIColor.white

    // MARK: - 文字

    /// 主文字：标题、曲名。
    static let title = RadixPalette.slate12.uiColor

    /// 次级文字：按钮文字、时长、角标。
    static let secondaryText = RadixPalette.slate11.uiColor

    /// 弱文字：艺人、摘要、索引。
    static let subtitle = RadixPalette.slate10.uiColor

    // MARK: - 背景与表面

    /// 页面底色。
    static let pageBackground = RadixPalette.slate1.uiColor

    /// 次级页面底色（表单类整页）。
    static let secondaryPageBackground = RadixPalette.slate2.uiColor

    /// 组件表面：工具栏、输入框、进度轨道。
    static let surface = RadixPalette.slate3.uiColor

    /// 选中高亮。曲库 / 歌单的行选中底色 —— 跟深浅色走。
    static let selection = RadixPalette.slate4.uiColor

    /// 队列页行选中高亮 —— **固定**黑 12% 半透明，不跟深浅色变。
    ///
    /// ⚠️ 跟 `selection` 是两个概念，不许合成一个：队列页恒浮在播放页的**深色 blur** 上，
    /// 选中要的是「blur 透出来的淡黑」—— 半透明压暗一层；实心动态色（`selection`）无论
    /// 哪一档都把底下盖死，出来的只能是"漆黑一块"或"白块"。底不翻 ⇒ 固定一档。
    static let queueSelection = UIColor(white: 0, alpha: 0.12)

    /// 封面占位底 —— 列表外、跟外观走的缩略图占位（如编辑页封面）。
    ///
    /// ⚠️ **迷你条空歌底不用这一档**：那边要的是 `surface`（slate3）；这一档是 slate5，更深一档。
    /// 试过纯黑 8% 半透明、和浅一档的 `slate3` —— 在部分场景实机都比这一档差
    /// （太淡时占位方块"看不见"，浅灰又跟封面本身的亮色糊在一起）⇒ 其它占位仍用 `slate5`。
    ///
    /// 🔴 **常暗浮层（播放页大封面）不许用这一档**：它是**实色**（浅/深两套值），
    /// 系统浅色时解析成近白，压在黑页面上就是一块白。那边走浮层色族 —— `overlayFillSubtle`。
    /// 判据一句话：**底会跟着系统外观翻的用实色，底是常暗的用 `overlay*`。**
    static let artworkPlaceholder = RadixPalette.slate5.uiColor

    /// 索引角标底。
    static let badge = RadixPalette.slate6.uiColor

    /// 「最爱的歌曲」封面底：浅色近白，深色用同族 alpha 阶压暗。
    ///
    /// 这一处必须自己包一层动态色：两个分支取的是**不同外观**下的值，
    /// 不能靠一个 token 的自动切换表达。
    static let favoritesCover = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? RadixPalette.slateA7.uiColor(for: .dark)
            : RadixPalette.slate1.uiColor(for: .light)
    }

    // MARK: - 分割线与阴影

    /// 分割线：列表行之间、导航栏下方。
    static let separator = RadixPalette.slateA6.uiColor

    /// 阴影色：纯黑。**强度不在这儿** —— 由使用方的 `shadowOpacity` 管
    /// （见 `AppMetrics.miniPlayerShadowOpacity`），两层别叠透明度，否则相乘出来的数没人要过。
    ///
    /// 阴影这种东西**不跟深浅色走**（影子本来就该是黑的），所以它是静态色，设一次就够。
    static let shadow = UIColor.black

    /// 封面流下方**倒影**的遮罩色：纯黑，用作 `CALayer.mask`（表达"哪些像素可见"）。
    ///
    /// ⚠️ **不复用上面 `shadow`**：那是"阴影"（压暗），强度由使用方 `shadowOpacity` 管；
    /// 这是"倒影淡出"（遮罩），强度由 `AppMetrics.coverFlowReflectionMaskTopOpacity` 管 ——
    /// 同一个黑，两条**互不相干**的轴，各有各的强度，混用就会出现两层透明度相乘。
    ///
    /// 遮罩同样不跟深浅色走：倒影本来就是黑底上的镜像。
    static let coverFlowReflectionMask = UIColor.black

    // MARK: - 遮罩

    /// 弹层背后那层压暗（播放页、半屏弹窗都用它）。
    ///
    /// 取色板 `blackA7` = **黑 50%**（浅深两套都是）。
    ///
    /// ⚠️ **透明度写在这个 token 里，不写在用它的地方** —— 跟上面 `shadow` 那条正好相反。
    /// 原因是弹层库（`PanModal` 的 `DimmedView`）**自己还会再动一次 `alpha`**（0 → 1 做淡入）：
    /// 它要的是一个"最暗能到多少"的**色**，不是"这一处要压多暗"的**强度**。
    static let modalScrim = RadixPalette.blackA7.uiColor

    // MARK: - 深色浮层（播放页、半屏弹窗、封面流）

    /// 浮层分割线。
    static let overlaySeparator = RadixPalette.whiteA1.uiColor

    /// 浮层轻微填充：播放页封面的占位底。
    ///
    /// 🔴 **白 12%**：色板在这里没有对应的档（`whiteA2` = 10% · `whiteA3` = 15%），所以不走色板。
    /// ⚠️ 曾经取 `whiteA2`：真机比过截图，没封面时那块方框暗 4~5 个色阶，一眼就"闷"。
    static let overlayFillSubtle = UIColor(white: 1, alpha: 0.12)

    /// 浮层填充：分段控件底。
    static let overlayFill = RadixPalette.whiteA3.uiColor

    /// 浮层描边：滑杆轨道。
    static let overlayBorder = RadixPalette.whiteA5.uiColor

    /// 浮层弱色调：歌词常态、图标弱态。
    static let overlayTint = RadixPalette.whiteA7.uiColor

    /// 浮层弱文字：关闭、删除。
    static let overlayTextTertiary = RadixPalette.whiteA8.uiColor

    /// 浮层次级文字：队列曲名。
    static let overlayTextSecondary = RadixPalette.whiteA9.uiColor

    /// 浮层中强文字。
    static let overlayTextStrong = RadixPalette.whiteA10.uiColor

    /// 浮层主文字。
    static let overlayText = RadixPalette.whiteA11.uiColor

    /// 播放页**一级前景** —— **不掺 alpha 的实白**。
    ///
    /// 🔴 **不能用上面那家 `overlay*`**：它们全是**半透明白**（最强的 `overlayText` = `whiteA11` =
    /// alpha `0xE6` = **90%**），压在深底上会透出底色。
    /// 这一页的一级前景**全是纯白**，逐处点名是为了别把它们并进 `overlayText`：
    /// - 曲名　　`titleLabel.textColor = .white`
    /// - 两个时间 —— 两个 label 都是 `.white`
    /// - 传输行五颗 —— `styleSymbol(...)` 里 `button.tintColor = .white`
    ///   （连 `modeButton` 的**开态和关态都显式设 `.white`**）
    /// - 进度条已播那截＋圆点
    ///
    /// ⚠️ 另一档是 `overlayTextSecondary`（70%）—— **关闭键 / 更多键 / 艺人 / 收藏 / 引用**用那个
    /// （`NowPlayingChrome.tint`）；再暗一档 `overlayTextTertiary`（60%）只给**歌词设置键**。
    static let nowPlayingSolid = UIColor.white

    /// 播放页歌词**行下附属字**（内嵌歌词里本来就带的译文 / 注音）—— 纯白 α0.4。
    ///
    /// 🔴 比**常态行正文**（`overlayTint` = α0.5）再暗一档：附属字是配角，两档拉开才分得清
    /// 谁是正文。出处：primuse 的附属字走"次级"那一档（`NowPlayingView.swift:6218`，
    /// 见 `播放页歌词.md` §A.5）。
    ///
    /// ⚠️ **当前行**（高亮行）的正文是 `nowPlayingSolid`、附属字**仍然是这一档** ——
    /// 附属字不跟着行状态变，免得"高亮行的小字"比"普通行的正文"还亮。
    static let nowPlayingLyricsSecondary = RadixPalette.whiteA6.uiColor

    /// 歌词列表**上下淡出遮罩**的色阶：`[透明, 白, 白, 透明]`。
    ///
    /// ⚠️ 这是**遮罩**（`CALayer.mask`），表达的是"哪些像素可见" —— 与浅色/深色无关，
    /// 所以这里的白是**纯白**、不掺 alpha，也不走 `RadixPalette` 那一套语义色。
    /// 分界点见 `AppMetrics.nowPlayingLyricsFadeLocations`。
    static let lyricsFadeMaskColors: [CGColor] = [
        UIColor.clear.cgColor,
        UIColor.white.cgColor,
        UIColor.white.cgColor,
        UIColor.clear.cgColor
    ]

    /// 逐字扫光**合成掩码**里"满亮"那一档的纯白（`KaraokeMaskRenderer` 用）。
    ///
    /// ⚠️ **不能复用上面 `lyricsFadeMaskColors`**：那是个**固定四档**的数组，
    /// 表达"整列表上下淡出"；这儿是**逐字合成**的 —— 每个 syllable 往同一张 mask 里
    /// 画一份自己的贡献，实心档与柔边档的数量**由排版结果决定**、事先不知道。
    /// 一个是"一条渐变的两端"，一个是"很多段各自的实心/柔边"，两件事。
    ///
    /// 同 `lyricsFadeMaskColors` 的理由：都是**掩码**（"哪些像素可见"），
    /// 与浅色/深色无关 ⇒ 纯白、不掺 alpha、不走 `RadixPalette` 语义色。
    static let karaokeMaskLit: CGColor = UIColor.white.cgColor

    /// 逐字扫光合成掩码里"完全透明"那一档（`.fill` 之外不画的区域）。
    static let karaokeMaskClear: CGColor = UIColor.clear.cgColor

    /// 播放页的底色 —— 一个**不透明**的深色，**不跟系统外观翻**。
    ///
    /// 🔴 **不能用上面那一家 `overlay*`**：它们全是**半透明白**，表达的是"压在别的东西上面的
    /// 一层浮层"（滑杆轨道、描边、弱文字）。播放页要的是一个**实底** —— 后面什么都没有。
    ///
    /// ⚠️ **也不能写成 `RadixPalette.slate12.uiColor`**（顺手拿"文字色"当底）：那个 token 是
    /// 两套值 —— 浅色模式下是近黑、**深色模式下是近白** ⇒ 深色模式一开，这一页会变成白底，
    /// 而页面上那些字是 `whiteA*`（两套都是白的）⇒ 白字白底，整页看不见。
    ///
    /// 🔴 **纯黑**（`view.backgroundColor = .black`）。
    /// 平时它被取色渐变整块盖住；只有渐变那层还没铺到的边角（转屏那一帧）会露出来 ——
    /// 渐变底下最暗的一档就是黑压层，露出来的底也得是黑，才不会闪一条灰边。
    /// 色板里没有不透明的黑（`blackA*` 全带透明度），所以直接取系统黑（同 `onAccent` 那一条）。
    ///
    /// ⚠️ **没封面时的样子不归它管** —— 那是 `NowPlayingBackdrop.fallbackPalette`
    /// （渐变照样画，只是用兜底的三个色）。
    static let nowPlayingBackground = UIColor.black

    // MARK: - 播放页背景（取色渐变）

    /// 播放页背景（一条取色渐变 ＋ 一层黑压层）要的颜色（`Features/NowPlaying/Background/`）。
    enum NowPlayingBackdrop {

        /// 封面取不到色（没封面 / 读不出像素）时用的**三个主色** —— 灰紫三档。
        ///
        /// 🔴 **色值原样保留 0~1 浮点**（同 `QualityBadge` 那条理由），不换算成十六进制。
        /// 它们跟取出来的主色走**同一套**压暗配方（`BackdropGradient`），所以屏幕上看到的比这三个更暗。
        ///
        /// ⚠️ **只留这一份**：曾经还有第二份默认色（setup 0.15 档）给"刚建好还没取色"那一刻 ——
        /// 两份不一样，没封面的歌一进页会从深灰紫渐到浅灰紫（消闪；稳态仍走同一套配方）。
        static let fallbackPalette = (
            primary: UIColor(red: 0.35, green: 0.35, blue: 0.40, alpha: 1),
            secondary: UIColor(red: 0.30, green: 0.30, blue: 0.38, alpha: 1),
            tertiary: UIColor(red: 0.32, green: 0.30, blue: 0.36, alpha: 1)
        )

        /// 压在渐变最上面那层黑：**上 10% · 中 20% · 下 15%**，保证白字压得住。
        ///
        /// 这三个值就是 `overlayTopAlpha / overlayMiddleAlpha / overlayBottomAlpha`。
        /// 正好落在色板 `blackA2 / blackA4 / blackA3` 上（`0x1a / 0x33 / 0x26` ≈ 0.10 / 0.20 / 0.15）。
        static let scrimTop = RadixPalette.blackA2.uiColor
        static let scrimMiddle = RadixPalette.blackA4.uiColor
        static let scrimBottom = RadixPalette.blackA3.uiColor
    }

    // MARK: - 编辑歌词页 · 逐字

    /// 工作台 SwiftUI `Color.accentColor` 的同一出处：Assets `AccentColor`。
    ///
    /// 🔴 **不是** `AppColor.accent`（Radix `blue9`），也**不是** Radix `blueA3/A4`：
    /// 工作台写的是 `Color.accentColor.opacity(0.10 / 0.15 / 0.72)`，资源里那颗蓝是
    /// `(0, 0.478, 1)`；以前拿 `blueA3`（P3 里 alpha 只有 ~0.087）去「近似 10%」，
    /// 叠出来就是明显更淡 —— **不是** SwiftUI / UIKit 画法差异，是色值没对齐。
    static let lyricsEditorAccent = UIColor(named: "AccentColor") ?? accent

    /// 工作台 `Color.secondary.opacity(x)`：取系统 `secondaryLabel` 的 RGB，透明度按 x。
    ///
    /// ⚠️ 不能 `secondaryLabel.withAlphaComponent(x)` —— `secondaryLabel` 自己已带透明度，
    /// 再乘一次会淡到几乎看不见。
    private static func lyricsEditorSecondaryFill(_ opacity: CGFloat) -> UIColor {
        UIColor { traits in
            let base = UIColor.secondaryLabel.resolvedColor(with: traits)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            if base.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                return UIColor(red: red, green: green, blue: blue, alpha: opacity)
            }
            var white: CGFloat = 0
            if base.getWhite(&white, alpha: &alpha) {
                return UIColor(white: white, alpha: opacity)
            }
            return base.withAlphaComponent(opacity)
        }
    }

    /// 逐字块（常态）的**中性淡底** —— 工作台 `secondary.opacity(0.08)`。
    ///
    /// 🔴 **必须是半透明，不能取实色 `surface`**：块与键都画在「当前句」那层强调色淡染**之上**，
    /// 实色底会把行高亮整块盖死 —— 选中的那一行会出现一排"抠出来的灰方块"。
    static let lyricsEditorSyllableFill = lyricsEditorSecondaryFill(0.08)

    /// 逐字块**选中**的底色 —— 工作台 `accentColor.opacity(0.15)`。
    ///
    /// ⚠️ 跟下面 `lyricsEditorCurrentLine` **值相近、概念不同**，不许并成一个：
    /// 一个是"这一块字被点中了"（块自己那层底），一个是"整行是当前句"（行底色）。
    static let lyricsEditorSyllableSelectedFill = lyricsEditorAccent.withAlphaComponent(0.15)

    /// 逐字块**选中**的描边（1pt）—— 工作台 `accentColor.opacity(0.72)`。
    static let lyricsEditorSyllableSelectedBorder = lyricsEditorAccent.withAlphaComponent(0.72)

    /// 编辑歌词页「当前句」整行的底色 —— 工作台 `accentColor.opacity(0.10)`。
    ///
    /// ⚠️ **画在行自己的圆角底板上**（`LyricsEditorLineCell` 的 `backgroundView`），
    /// 不再整格平铺 —— 工作台那一行的淡染就是一块圆角 **6** 的板子，四周留着底色。
    static let lyricsEditorCurrentLine = lyricsEditorAccent.withAlphaComponent(0.10)

    /// 行首**已打轴**时间键的浅灰底 —— 工作台 `secondary.opacity(0.12)`。
    static let lyricsEditorRowTimeFill = lyricsEditorSecondaryFill(0.12)

    /// 行首**未打轴「打点」**键的浅灰底 —— 工作台 `secondary.opacity(0.08)`。
    static let lyricsEditorRowStampFill = lyricsEditorSecondaryFill(0.08)

    /// 细条上那对 `±` 小键的浅灰底 —— 工作台 `secondary.opacity(0.10)`。
    static let lyricsEditorNudgeButtonFill = lyricsEditorSecondaryFill(0.10)

    // MARK: - 小组件

    /// 小组件底色。
    static let widgetBackground = RadixPalette.slate10.uiColor

    // MARK: - 音质徽章

    /// 音质徽章四档的渐变 —— **一对端色**（起 → 止，横向），白字压在上面。
    ///
    /// 🔴 原本是**五档**（蓝 / 绿 / 金 / 紫 / 灰），去掉灰档 ⇒
    /// 那四档非灰配色依次落到我们的 `SD / HQ / SQ / HR` 上。
    ///
    /// ⚠️ 所以**颜色和档位的"语义"不是一一对应的**（最低档拿到的是第二档的蓝）——
    /// 这是"五档砍成四档"必然带出来的结果，不是抄错了。要重排配色，改这一处就够。
    ///
    /// ⚠️ 这四个是**手挑的色值**，不在 `RadixPalette` 里（那一层是生成的、不许手改），
    /// 所以直接写 `UIColor`；沿用 0~1 浮点，**不换算成十六进制**（换算会丢精度）。
    enum QualityBadge {

        /// 最低档 —— 蓝。
        static let sd = (
            start: UIColor(red: 0.30, green: 0.55, blue: 0.75, alpha: 1),
            end: UIColor(red: 0.22, green: 0.47, blue: 0.68, alpha: 1)
        )

        /// 高码率有损 —— 绿。
        static let hq = (
            start: UIColor(red: 0.28, green: 0.65, blue: 0.40, alpha: 1),
            end: UIColor(red: 0.20, green: 0.55, blue: 0.32, alpha: 1)
        )

        /// 无损 —— 金。
        static let sq = (
            start: UIColor(red: 0.76, green: 0.60, blue: 0.20, alpha: 1),
            end: UIColor(red: 0.70, green: 0.50, blue: 0.15, alpha: 1)
        )

        /// 最高档 —— 紫。
        static let hr = (
            start: UIColor(red: 0.58, green: 0.35, blue: 0.72, alpha: 1),
            end: UIColor(red: 0.48, green: 0.28, blue: 0.62, alpha: 1)
        )
    }
}

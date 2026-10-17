import Foundation

/// 「这一行算不算歌词」—— 首/尾两段「制作信息块」里**哪几行删、哪几行留**。
///
/// 纯函数、零 UIKit、能离线单测。
///
/// ## 为什么有它
///
/// 酷狗把「词：…／曲：…／编曲：…」这类**制作信息**当成**真的歌词行**排在最前/最后
/// （有行时间、有字块，实测《晴天》头部 13 行）。判据的底子照搬 `Lyricify-Lyrics-Helper`
///
/// ## 🔴 词／曲／艺人／专辑是**特例**，一律保留
///
/// > 「歌词曲艺人专辑都能留，那些腾讯翻译版权腾讯by编曲混音制作人策划等等的不要」
///
/// ⇒ 判据分两层：
/// 1. **块边界**：什么还算「信息块」—— 信息行 ＋ **受保护的署名行** ＋ 歌名行。
///    受保护/歌名行**也把块续下去**（它们后面跟着的编曲、制作人才删得到），但**本身不删**。
/// 2. **删留**：块内只有 `isInfoLine` 命中的行才删；词／曲／艺人／专辑（含「歌名 - 歌手」「裸歌名」行）保留。
///
/// 由此对那套判据的两处**结构性偏离**（不是等价改写）：
/// - **按行删**（`IndexSet`），不再是「从头数 N 行整段丢」—— 署名行混在块中间，整段丢会把它带走；
/// - **「相邻行顺带吃掉」废除** —— 那是整段丢时代的补刀，按行删后它会误杀署名行。
///
/// ## 🔴 判据底子仍旧逐分支照搬，不提炼、不压缩
///
/// 它**不是"一张关键词表"、也不是"三个函数"** —— 是一整套分支：
/// 入口（`removals` / `headingRemovals` / `middleRemovals` / `endingRemovals` /
/// `isInfoLine` ＋ 给转换层用的 `isInBlock` / `isTitleArtistLine`）
/// ＋ 内部判断（`looksLikeArtistSpeakerLabel` `looksLikeTitleAndArtistLine`
/// `containsTitle` `containsArtists` `hasUpcomingBlock` `hasPreviousBlock`
/// `containsAnyKeyword` `containsAny` `isStringTencentClaiming` `isStringCreditBy`
/// `isStringCopyrightClaiming` ＋ `toSimplified`）。
/// 漏掉的分支就是**误删 / 漏删**的口子（"三条口诀"那版就是那么错的）。
///
/// ## 与它的两处**有意偏离**（实现层）
///
/// 1. 简繁归一用平台自带的 ICU 转换：它自带 4000+ 汉字对照表，
///    我们不搬那张表，改用 Foundation 的 `Traditional-Simplified`（同一套 ICU 数据）——
///    判据关心的只是 `詞：` `編曲：` 能不能转成简体去撞词表，两者一致。
/// 2. 标签特例（`protectedLabels`）与按行删留是**我们加的**，它那边没有。
///
/// ## 头、中、尾都做
///
/// - **头 / 尾**：连续信息块内按行删留（署名保留）。
/// - **中部**：头尾块之间凡 `isInfoLine` 命中也删 —— 对齐 Lyricify 那套的
///   middle 段。只扫首尾时，块会被「词表未收录的标签」截断，后面的制作行会漏网
///   （真档《一次就好》「项目督导」断点）。接上中部。
///
/// 词表在 Lyricify 171 条之上增补 **「督导」**（同上真档断点；冒号总闸仍在）。
enum LyricsCreditLinePolicy {

    /// 判「歌名 ＋ 艺人」那条特判要用的两个值 —— 取自**搜歌那一步的候选**
    /// （`songname` / `singername`）。
    ///
    /// `artist` 这个**计算属性**是为了对上它那边的 `TrackMultiArtistMetadata.Artist`
    /// （getter 就是 `string.Join(", ", Artists)`）。
    struct TrackInfo {
        let title: String
        let artists: [String]

        var artist: String { artists.joined(separator: ", ") }
    }

    // MARK: - 判断的结论（三个入口各吐一个）

    /// 「这一行还算在制作信息块里吗」的结论 —— `isInBlock` 吐它。
    ///
    /// 只被判断层自己消费（`LyricsExternalFormatPolicy` 也是判断）⇒ 跟着政策走、留这里
    ///（只判断用的类型不必上 `Model/`）。
    enum BlockMembership: Equatable {
        /// 还在块内。
        case inBlock
        /// 已经出块。
        case outOfBlock
    }

    /// 「这一行是不是标题行」的结论 —— `isTitleArtistLine` 吐它。
    enum LineRole: Equatable {
        /// 裸歌名行，或「歌名 ＋ 艺人」行。
        case titleArtist
        /// 其余。
        case ordinary
    }

    /// 「这一行是不是制作信息行（要删的那种）」的结论 —— `isInfoLine` 吐它。
    enum LineKind: Equatable {
        /// 制作信息行：词表命中 ＋ 有冒号，或腾讯 / 版权声明行。
        case info
        /// 其余（署名行 / 歌名行 / 正文 / 空行）。
        case other
    }

    // MARK: - 入口

    /// 还算在「制作信息块」里的行吗（**公开**）—— 给转换层划定「标题行改写」的作用域用：
    /// 只在头部块**之内**找标题行，正文一个字不碰。吐 `BlockMembership`。
    static func isInBlock(_ text: String, track: TrackInfo?) -> BlockMembership {
        inBlock(text, track: track) ? .inBlock : .outOfBlock
    }

    /// 这一行是不是「标题行」（**公开**）—— 裸歌名行，或「歌名 ＋ 艺人」行。吐 `LineRole`。
    ///
    /// 给转换层把标题行**统一改写成「歌名 - 艺人」**用。
    /// 命中判据与块内保留用的是**同一套**（`isTitleLine` / `looksLikeTitleAndArtistLine`），
    /// 不另立标准。
    static func isTitleArtistLine(_ text: String, track: TrackInfo?) -> LineRole {
        if isTitleLine(text, track: track) { return .titleArtist }
        guard let track else { return .ordinary }
        return looksLikeTitleAndArtistLine(text, track: track) ? .titleArtist : .ordinary
    }

    /// 全文要删的行号：头 ＋ 尾 ＋ **中部**。
    ///
    /// 转换层只调这一处（`LyricsExternalFormatPolicy`），避免漏接中部。
    static func removals(_ lines: [String], track: TrackInfo?) -> IndexSet {
        var drops = headingRemovals(lines, track: track)
        drops.formUnion(endingRemovals(lines, track: track))
        drops.formUnion(middleRemovals(lines, track: track))
        return drops
    }

    /// 头部信息块里要**删**的行号集合（从第 0 行起扫，第一行出块即停）。
    ///
    /// 保留下来的署名行/歌名行**不算**删除项，但**把块续下去**。
    ///
    /// 🔴 **入口特判第二条**（原先漏了）：块入口有**两条** ——
    /// ①第 0 行是标题行 ⇒ 从 1 起看；②**第 0 行认不出、但第 1 行在块内 ⇒ 第 0 行照样算头部**。
    /// 实测《桃花诺》：源档标题行写 `G.E.M. 邓紫棋 (Gem Tang)`（带空格带罗马音），
    /// 搜歌给的艺人串是 `G.E.M.邓紫棋` —— ①认不出 ⇒ 以前块第一步就 break，**一行都没删**。
    /// 补回 ② 后块能扫下去。
    /// ⚠️ ②的语义**有意收窄**：另一种做法会把第 0 行**整段带走**（整段丢），
    /// 我们改成「第 0 行**视作块内、按判据删留**」。
    static func headingRemovals(_ lines: [String], track: TrackInfo?) -> IndexSet {
        let end = headingBlockEnd(lines, track: track)
        var drops = IndexSet()
        for index in 0..<end where isInfoLine(lines[index], track: track) == .info {
            drops.insert(index)
        }
        return drops
    }

    /// 尾部信息块里要**删**的行号集合（从最后一行往回扫）。
    ///
    /// ⚠️ 同一条限制：尾部**没有**整段丢时代那句
    /// 「下一行是信息行 ⇒ 两行一起丢」—— 按行删后更用不着。
    static func endingRemovals(_ lines: [String], track: TrackInfo?) -> IndexSet {
        let start = endingBlockStart(lines, track: track)
        var drops = IndexSet()
        for index in start..<lines.count where isInfoLine(lines[index], track: track) == .info {
            drops.insert(index)
        }
        return drops
    }

    /// 头尾块**之间**凡 `isInfoLine` 命中的行（中部扫描）。
    ///
    /// 署名特例仍走 `isInfoLine == false`，中部不会误删词／曲。
    static func middleRemovals(_ lines: [String], track: TrackInfo?) -> IndexSet {
        let midStart = headingBlockEnd(lines, track: track)
        let midEnd = endingBlockStart(lines, track: track)
        var drops = IndexSet()
        guard midStart < midEnd else { return drops }
        for index in midStart..<midEnd where isInfoLine(lines[index], track: track) == .info {
            drops.insert(index)
        }
        return drops
    }

    /// 头部块右开边界 —— 从 0 连续属于头部的行数；中部扫描的起点。
    static func headingBlockEnd(_ lines: [String], track: TrackInfo?) -> Int {
        guard !lines.isEmpty else { return 0 }

        var index = 0
        while index < lines.count {
            let text = lines[index]
            if isBlank(text) {
                if hasUpcomingBlock(lines, index: index, track: track) {
                    index += 1
                    continue
                }
                break
            }
            // 入口特判②（原先漏了、后补回）：仅对第 0 行豁免一次出块检查 ——
            // 它自己认不出（标题行没对上艺人），但第 1 行在块内 ⇒ 第 0 行照样算头部。
            if index == 0,
               track != nil, lines.count >= 3,
               isTitleArtistLine(lines[0], track: track) == .ordinary,
               inBlock(lines[1], track: track) {
                index += 1
                continue
            }
            guard inBlock(text, track: track) else { break }
            index += 1
        }
        return index
    }

    /// 尾部块左闭起点；中部扫描的右开终点。
    static func endingBlockStart(_ lines: [String], track: TrackInfo?) -> Int {
        guard !lines.isEmpty else { return 0 }

        var index = lines.count - 1
        var start = lines.count
        while index >= 0 {
            let text = lines[index]
            if isBlank(text) {
                if hasPreviousBlock(lines, index: index, track: track) {
                    start = index
                    index -= 1
                    continue
                }
                break
            }
            guard inBlock(text, track: track) else { break }
            start = index
            index -= 1
        }
        return start
    }

    /// 这一行算不算信息行（`IsInfoLine`）—— 按 `docs/设计/获取歌词-酷狗源.md` §D 那张表**逐个分支**走。
    /// 吐 `LineKind`。
    ///
    /// 🔴 **词／曲／艺人／专辑署名行在这里直接返回 `.other`**（特例）——
    /// 它们撞词表也没用，署名优先于词表。
    static func isInfoLine(_ text: String, track: TrackInfo?) -> LineKind {
        if isBlank(text) { return .other }

        // 🔴 特例：「词：」「曲：」「艺人：」「专辑：」这类署名行 **不是** 信息行。
        if isProtectedCreditLine(text) { return .other }

        // 🔴 三步归一化（最容易漏抄的一步）：全角冒号 → 半角冒号 + 空格 · 简繁转简 · 去首尾空白。
        // ⚠️ ①之后串里已无全角冒号 ⇒ 下面 `hasColon` 那个 `|| str.contains("：")` 是**死代码**，
        // 实际只看半角 `':'`（**结论**上仍是"两种冒号都认"，因为全角已被转成半角）—— 照抄。
        let str = toSimplified(text.replacingOccurrences(of: "：", with: ": "))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 保护：行以半角 `:` 收尾、且冒号前正好是本曲艺人 ⇒ **不是**信息行（防误删艺人署名行）。
        if looksLikeArtistSpeakerLabel(text, track: track) { return .other }

        if isStringTencentClaiming(str) { return .info }
        if isStringCreditBy(str) { return .info }

        let hitDict = containsAnyKeyword(str, titleLineInfoDict)
        let hasColon = str.contains(":") || str.contains("：")
        if !hitDict || !hasColon {
            return isStringCopyrightClaiming(str) ? .info : .other
        }
        return .info
    }

    // MARK: - 块边界与特例

    /// 还算在「制作信息块」里的行：信息行 ＋ **受保护署名行** ＋ 歌名行。
    ///
    /// 后两类**不删**，但把块续下去 —— 不然《晴天》的「词：」「曲：」会把块拦腰截断，
    /// 后面的编曲/制作人就删不到了。
    private static func inBlock(_ text: String, track: TrackInfo?) -> Bool {
        if isInfoLine(text, track: track) == .info { return true }
        if isProtectedCreditLine(text) { return true }
        if isTitleLine(text, track: track) { return true }
        if let track, looksLikeTitleAndArtistLine(text, track: track) { return true }
        return false
    }

    /// 🔴 特例表：冒号前的**标签**（归一化后）正好是这些 ⇒ 署名行，**不删**。
    ///
    /// 刻意用**全等**不用子串：「编曲」含「曲」但不在表里 ⇒ 照删；
    /// 「混音」「制作人」「策划」也都不在表里 ⇒ 照删。
    private static let protectedLabels: Set<String> = [
        "词", "作词", "填词", "歌词",
        "曲", "作曲", "词曲", "词/曲",
        "艺人", "歌手", "演唱",
        "专辑",
    ]

    /// 行首标签：全角冒号 → 半角、繁→简、去空白、小写。没有冒号 ⇒ `nil`（不算署名行）。
    private static func creditLabel(of text: String) -> String? {
        let normalized = toSimplified(text.replacingOccurrences(of: "：", with: ":"))
        guard let index = normalized.firstIndex(of: ":") else { return nil }
        let label = normalized[..<index]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return label.isEmpty ? nil : label
    }

    private static func isProtectedCreditLine(_ text: String) -> Bool {
        guard let label = creditLabel(of: text) else { return false }
        return protectedLabels.contains(label)
    }

    /// 裸歌名行（「晴天」）：整行（归一化后）**全等**歌名 ⇒ 算块内、**不删**。
    ///
    /// 刻意全等不用子串 —— 歌名出现在真歌词里很常见（《七里香》那句
    /// "七里香的名字很美"），子串判会把块拖进正文。
    private static func isTitleLine(_ text: String, track: TrackInfo?) -> Bool {
        guard let title = track?.title.trimmingCharacters(in: .whitespacesAndNewlines),
              !isBlank(title)
        else { return false }
        let lineNorm = toSimplified(text).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let titleNorm = toSimplified(title).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !titleNorm.isEmpty && lineNorm == titleNorm
    }

    // MARK: - 词表（172 条＝Lyricify 171 ＋「督导」）

    /// 制作信息关键词表。
    ///
    /// 🔴 里面混着 `声` `音` `曲` 这种**单字** ⇒ 光对词表任何歌词都可能撞上
    /// （"风吹过的声**音**"）—— 所以 `isInfoLine` 里**必须同时带冒号**才算（那道总闸）。
    ///
    /// ⚠️ **「督导」**是相对 Lyricify 的增补：真档《一次就好》头部
    /// `项目督导：…` 不在原表 ⇒ 头部块在此断开；补上后进块，中部扫描也认。
    static let titleLineInfoDict: [String] = [
        "音", "声", "词", "曲", "鼓", "笛", "编曲", "吉他", "吉它", "贝斯",
        "缩混", "胡琴", "扬琴", "提琴", "录音", "弦乐", "键盘", "钢琴", "童声", "助理",
        "古筝", "琵琶", "笛子", "二胡", "唢呐", "出品", "和声", "和音", "编写", "混音",
        "封面", "营销", "发行", "制作", "监制", "督导", "策划", "企划", "推广", "母带", "编写",
        "文案", "编辑", "统筹", "总监", "鸣谢", "感谢", "设计", "视觉", "小号", "长号",
        "管乐", "管弦", "工程", "簧管", "巴松", "原唱", "配唱", "伴唱", "轨道", "演唱",
        "尺八", "乐队", "调校", "伴奏", "主唱", "曲绘", "呼麦", "校对", "设计", "商务",
        "合作", "合唱", "指挥", "经纪", "戏腔", "团队", "协作", "顾问", "翻译", "摄影",
        "协力", "艺人", "行销", "媒介", "运营", "宣传", "管理", "单位", "支持", "平台",
        "录混", "宣发", "念白", "厂牌", "分轨", "贴混", "古琴", "调教", "题字", "海报",
        "图绘", "影像", "导演", "造型", "妆发", "单簧管", "萨克斯", "打击乐", "合成器", "马头琴",
        "热瓦普", "葫芦丝", "冬不拉", "工作室", "科布兹", "专辑介绍", "巴拉莱卡", "OA", "OP", "OT",
        "PV", "SP", "A&R", "PGM", "ISRC", "Bass", "Drum", "Pads", "Brass", "Cello",
        "Choir", "Horns", "Mixed", "Mixer", "Piano", "Synth", "Viola", "Vocal", "Winds", "Kobza",
        "Assist", "Violin", "Mixing", "String", "Guitar", "Master", "Chorus", "Record", "violins", "Arrange",
        "Conduct", "Editing", "Hormony", "Ocarina", "Produce", "Strings", "Whistle", "Stylist", "Engineer", "Keyboard",
        "Director", "Harmonica", "Mastering", "Recording", "Balalaika", "Percussion", "Programing", "Production", "Programming",
        "Additional programming", "Irish whistle",
    ]

    // MARK: - 私有（内部判断，逐分支照搬）

    /// `LooksLikeArtistSpeakerLabel` —— 冒号前正好是本曲艺人。
    ///
    /// 🔴 **只认半角 `:` 收尾**（全角 `：` 收尾不触发）。
    private static func looksLikeArtistSpeakerLabel(_ raw: String, track: TrackInfo?) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasSuffix(":") { return false }

        // 多艺人逐个比。
        if let artists = track?.artists, !artists.isEmpty {
            for artist in artists {
                if isBlank(artist) { continue }
                let candidate = artist.trimmingCharacters(in: .whitespacesAndNewlines) + ":"
                if candidate.lowercased() == text.lowercased() { return true }
            }
        }
        // 单艺人（那边 `TrackMetadata.Artist`）。
        if let single = track?.artist, !isBlank(single) {
            let candidate = single.trimmingCharacters(in: .whitespacesAndNewlines) + ":"
            if candidate.lowercased() == text.lowercased() { return true }
        }
        return false
    }

    /// `LooksLikeTitleAndArtistLine` —— 「标题行（歌名 ＋ 艺人）」的完整判据。
    ///
    /// 🔴 它的角色变了：从「删」的判据变成「**块内保留**」的判据
    /// （艺人/歌名行要留）—— 命中 ⇒ 算块内、不删。
    private static func looksLikeTitleAndArtistLine(_ line: String, track: TrackInfo) -> Bool {
        if isBlank(line) { return false }

        let lineNorm = line.lowercased().replacingOccurrences(of: "’", with: "'")
        let titleNorm = toSimplified(track.title.lowercased(), force: true)
            .replacingOccurrences(of: "’", with: "'")
        let artistNorm = toSimplified(track.artist.lowercased(), force: true)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: ", ", with: "/")

        if containsTitle(lineNorm, titleNorm),
           containsArtists(lineNorm, track: track, singleArtistNorm: artistNorm) {
            return true
        }

        // 标题本身含 ` - `：取它前那段 `t0`。
        if track.title.contains(" - ") {
            let lowered = track.title.lowercased().replacingOccurrences(of: "’", with: "'")
            if let t0 = lowered.components(separatedBy: " - ").first,
               !isBlank(t0),
               lineNorm.contains(t0),
               lineNorm.contains(artistNorm) {
                return true
            }
        }

        // 标题含中文：拿**未转小写**的原串比（那边用的是 `line`，不是 `lineNorm`）。
        if hasChinese(track.title) {
            if line.contains(toSimplified(track.title)),
               line.contains(toSimplified(track.artist)) {
                return true
            }
        }
        return false
    }

    /// `ContainsTitle` —— 四条：直接包含 · **行**有 `(` 时比括号前那段 ·
    /// **标题**有 `(` 时比括号前那段 · **标题**有 ` - ` 时比它前面那段。
    private static func containsTitle(_ lineLower: String, _ titleLower: String) -> Bool {
        if isBlank(titleLower) { return false }
        if lineLower.contains(titleLower) { return true }

        if let index = lineLower.firstIndex(of: "(") {
            let position = lineLower.distance(from: lineLower.startIndex, to: index)
            if position > 0 {
                let before = String(lineLower[lineLower.startIndex..<index])
                if before.contains(titleLower) { return true }
            }
        }

        if let index = titleLower.firstIndex(of: "(") {
            let position = titleLower.distance(from: titleLower.startIndex, to: index)
            if position > 0 {
                let before = String(titleLower[titleLower.startIndex..<index])
                    .trimmingCharacters(in: .whitespaces)
                if !before.isEmpty && lineLower.contains(before) { return true }
            }
        }

        if let range = titleLower.range(of: " - ") {
            let position = titleLower.distance(from: titleLower.startIndex, to: range.lowerBound)
            if position > 0 {
                let before = String(titleLower[titleLower.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if !before.isEmpty && lineLower.contains(before) { return true }
            }
        }
        return false
    }

    /// `ContainsArtists` —— 单艺人含即算；多艺人要**命中 >1 个**，
    /// 或（命中 1 个**且**该曲只有 1 位艺人）。
    private static func containsArtists(
        _ lineLower: String, track: TrackInfo, singleArtistNorm: String
    ) -> Bool {
        if !isBlank(singleArtistNorm) && lineLower.contains(singleArtistNorm) { return true }

        if !track.artists.isEmpty {
            var hit = 0
            for artist in track.artists {
                if isBlank(artist) { continue }
                let norm = toSimplified(artist.lowercased(), force: true)
                    .replacingOccurrences(of: "’", with: "'")
                    .replacingOccurrences(of: ", ", with: "/")
                if !norm.isEmpty && lineLower.contains(norm) { hit += 1 }
            }
            if hit > 1 || (hit == 1 && track.artists.count == 1) { return true }
        }
        return false
    }

    /// `HasUpcomingInfo` —— 往下跳过空行、**最多看 2 个非空行**，其内有**块内行**即可。
    private static func hasUpcomingBlock(_ lines: [String], index: Int, track: TrackInfo?) -> Bool {
        var seen = 0
        var i = index + 1
        while i < lines.count && seen < 2 {
            let text = lines[i]
            if !isBlank(text) {
                seen += 1
                if inBlock(text, track: track) { return true }
            }
            i += 1
        }
        return false
    }

    /// `HasPreviousInfo` —— 往上跳过空行、最多看 2 个非空行。
    private static func hasPreviousBlock(_ lines: [String], index: Int, track: TrackInfo?) -> Bool {
        var seen = 0
        var i = index - 1
        while i >= 0 && seen < 2 {
            let text = lines[i]
            if !isBlank(text) {
                seen += 1
                if inBlock(text, track: track) { return true }
            }
            i -= 1
        }
        return false
    }

    /// `ContainsAnyKeyword` —— 词表里任何一条是子串即算（**大小写不敏感**）。
    private static func containsAnyKeyword(_ text: String, _ dict: [String]) -> Bool {
        if dict.isEmpty { return false }
        let haystack = text.lowercased()
        for keyword in dict where !isBlank(keyword) {
            if haystack.contains(keyword.lowercased()) { return true }
        }
        return false
    }

    /// `ContainsAny` —— 任一条是子串即算（大小写不敏感）。
    private static func containsAny(_ text: String, _ parts: [String]) -> Bool {
        let haystack = text.lowercased()
        for part in parts where !part.isEmpty {
            if haystack.contains(part.lowercased()) { return true }
        }
        return false
    }

    /// `IsStringTencentClaiming` —— 腾讯翻译权声明行。
    private static func isStringTencentClaiming(_ str: String) -> Bool {
        let text = toSimplified(str)
        return (text.contains("腾讯") || text.contains("TME"))
            && text.contains("享有")
            && text.contains("翻译")
            && text.contains("权")
    }

    /// `IsStringCreditBy` —— 英文署名行。
    private static func isStringCreditBy(_ str: String) -> Bool {
        if containsAny(str, ["st:", "or:", "Lyrics:", " by:", " By:"]) { return true }
        let lowered = str.lowercased()
        if lowered.contains("er:"),
           !lowered.contains("tedder:"),
           !lowered.contains("bieber:") {
            return true
        }
        return false
    }

    /// `IsStringCopyrightClaiming` —— 版权声明行（词表 **≥4** 个）。
    private static func isStringCopyrightClaiming(_ str: String) -> Bool {
        var score = 0
        for keyword in ["未经", "许可", "授权", "不得", "请勿", "使用", "版权"] where str.contains(keyword) {
            score += 1
        }
        return score >= 4
    }

    // MARK: - 私有 · 小工具

    /// `ToSC` —— 繁 → 简。`force` 那一路另加它写死的 4 条替换（照抄）。
    private static func toSimplified(_ text: String, force: Bool = false) -> String {
        var result = text
        if force {
            result = applyingT2S(result)
            result = result
                .replacingOccurrences(of: "藉", with: "借")
                .replacingOccurrences(of: "咀", with: "嘴")
                .replacingOccurrences(of: "昇", with: "升")
                .replacingOccurrences(of: "髒", with: "脏")
        }
        return applyingT2S(result)
    }

    /// 平台自带的 ICU「繁 → 简」转换（见类 doc 那处**有意偏离**）。
    private static func applyingT2S(_ text: String) -> String {
        text.applyingTransform(StringTransform(rawValue: "Traditional-Simplified"), reverse: false)
            ?? text
    }

    /// `StringHelper.HasChinese`。
    private static func hasChinese(_ text: String) -> Bool {
        text.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil
    }

    /// `string.IsNullOrWhiteSpace`。
    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

import Foundation
import RxRelay
import RxSwift

/// 「编辑歌词」页的**草稿与动作** —— 页面只订阅它、把用户动作交给它。
///
/// ## 它管什么
///
/// **当前这一份草稿**＝ **行数组是唯一真相**；原文模式的文本只是行的投影。
/// 每一次改动都走 `LyricsEditorPolicy` 那一族纯函数算出新的一份，再推出去。
/// 页面不持有草稿 —— 页面一关就没了，而"这一份还没存"这件事要跨整个会话活着。
///
/// ## 🔴 它不认识的东西
///
/// - **不碰播放器的状态**：打点时**读一次** `currentPosition`；播放进度由页面订 `position` 只喂歌曲条。
///   「0.1 s Timer 全刷、并把播放头写进打轴中间格」—— 是抄错（真机 0.5 s 只刷歌曲条；
///   中间格是行时间）。按 0.5 s 那套，不跟那份错抄。
/// - **不碰音频文件 / 侧表那份内嵌歌词**：保存只调 `LibraryStore.saveCustomLyrics`
///
/// ## 线程
///
/// 全在主线程（页面动作来自主线程；`playManager.state` / `.position` 两条流也保证在主线程上推）。
@MainActor
final class LyricsEditorViewModel {

    // MARK: - 推给页面的东西

    /// 三个模式 —— **用 enum，不写 `Int` 魔法数 0/1/2**。
    ///
    /// 判据：哪一个"主区"在屏上。别用三个 `isHidden` 分支散在四处，
    /// 这里收成一处。
    enum Mode: Int, CaseIterable {
        /// 逐行：行表格（改词 ＋ 打点）。
        case lines
        /// 打轴：上下文排版（上句 / 当前句 / 下句 ＋ 大按钮）。
        case timing
        /// 原文：裸文本框。
        case source

        /// 分段控件上那一段的名字。**顺序就是 `rawValue`**，所以 `allCases.map` 能直接当控件项。
        var title: String {
            switch self {
            case .lines: return "逐行"
            case .timing: return "打轴"
            case .source: return "原文"
            }
        }
    }

    /// 「打轴」内部的**两页**。
    ///
    /// ⚠️ **不往顶栏加段**：`逐行 / 打轴 / 原文` 已经三段，再加就挤成四~五段 ——
    /// 打轴是同一件事的两个侧重点，属**同级细分**。
    enum TimingPage: Int, CaseIterable {
        /// 逐行打轴：现成那七块，给**整行**打点。
        case line
        /// 逐字打轴：同一套七块，多逐字块条 ＋ 当前字细条，给**每个字**打点。
        case syllable

        var title: String {
            switch self {
            case .line: return "逐行打轴"
            case .syllable: return "逐字打轴"
            }
        }
    }

    /// 草稿这一刻的样子 —— 页面重画**全靠这一份**。
    ///
    /// ⚠️ 字段是 `var` 不是 `let`：VM 的 `commit` 每改一处就重算另外几个（光标夹紧、每行问题、
    /// 改过没有）—— 一份草稿的四个字段**是同一件事**，不是一个能各改各的容器。
    /// 页面只读它，不写。
    struct Snapshot: Equatable {

        /// 正在编辑的行 —— 🔴 **草稿唯一真相**；保存、问题清单、`isEdited` 都只看它。
        var lines: [LyricsEditorLine]

        /// **每一行**的问题，与 `lines` 同长（行 cell 按行号取）。
        ///
        /// 🔴 在这里**算好一次**而不是让页面现问：角标要在每次重画时都用到，
        /// 现问就是每次重画 O(n²) —— 一份两百行的歌词在滚动时会很显眼。
        var rowIssues: [[LyricIssueKind]]

        /// 逐行 / 打轴两个模式下的光标行号（行高亮与打轴面板都用它）。
        var cursorIndex: Int

        /// 现在是哪个模式。
        var mode: Mode

        /// 打轴里现在是「逐行打轴」还是「逐字打轴」那一页。
        var timingPage: TimingPage

        /// 逐字打轴里**正在打的那个字**（`0`-based）；这一行没有逐字时无意义（恒 `0`）。
        ///
        /// 🔴 跟 `cursorIndex` 是**两级游标**（行 → 字），不是同一件事的两种说法：
        /// 换行的时候字游标要回 0，而在同一行里挪字游标不该动行游标。
        var syllableCursorIndex: Int

        /// 「原文」模式文本框里那一段 —— **行的投影**，不是第二条草稿。
        ///
        /// 进原文时用 `export(lines)` 填；原文里每改一次就 `parse` 回 `lines`。
        /// 所以保存永远可以只看 `lines`，不必再问"现在是不是原文模式"。
        var sourceText: String

        /// 用户改过没有 —— 决定右上「保存」能不能点、关页时要不要问。
        ///
        /// 🔴 比的是**行数组**、不是导出后的字符串（`LyricsEditorPolicy.isEdited`）：
        /// 导出会把 `[00:05.2]` 规范成 `[00:05.20]`，比字符串等于"一打开就显示有改动"。
        var isEdited: Bool

        static let empty = Snapshot(
            lines: [],
            rowIssues: [],
            cursorIndex: 0,
            mode: .lines,
            timingPage: .line,
            syllableCursorIndex: 0,
            sourceText: "",
            isEdited: false
        )
    }

    /// 要跟用户说的一句话（保存成功 / 失败）。
    struct Notice: Equatable {
        let text: String
        let style: HUD.Style
    }

    /// 草稿流。**每次改动推一份**（`Equatable`，页面可以自己去重）。
    let snapshot: Observable<Snapshot>

    /// 正在播否 —— 只给歌曲条那颗键换图标。
    ///
    /// 🔴 单独一条、不塞进 `Snapshot`：它是"播放状态变了"，跟"草稿变了"是两件事，
    /// 混进草稿会让**每 10 Hz 的进度 tick 都重算一遍角标**。
    let isPlaying: Observable<Bool>

    /// 一次性提示（保存结果）。
    let notice: Observable<Notice>

    // MARK: - 依赖

    private let track: Track
    private let library: LibraryStore
    private let playManager: PlayManager

    // MARK: - 内置状态

    private let snapshotRelay: BehaviorRelay<Snapshot>
    private let isPlayingRelay: BehaviorRelay<Bool>
    private let noticeRelay = PublishRelay<Notice>()
    private let disposeBag = DisposeBag()

    /// 现在的草稿。**只由本页改**（页面拿不到它，只能通过下面的方法改）。
    private var current: Snapshot

    /// 开页时那一行（只用于判"改过没有"）。
    ///
    /// 🔴 **只留在 VM，不塞进 `Snapshot`** —— 页面拿它没有用，而"两份都带着同一个事实"
    /// 正是铁律里最常见的一种病（同 `PlayerState` 那条注释）。
    private let originalLines: [LyricsEditorLine]

    // MARK: - 建立

    /// - Parameters:
    ///   - track: 要改歌词的那首。
    ///   - lyrics: 开页时显示的那份歌词 —— 🔴 **由调用方按 `LyricsSourcePolicy` 取**，
    ///     这一层不关心它是从内嵌还是自定义层来的。
    ///   - library: 保存时写 `customLyrics`。
    ///   - playManager: 打点时读"现在几秒"、点播放键时发动作。
    init(track: Track, lyrics: String, library: LibraryStore, playManager: PlayManager) {
        self.track = track
        self.library = library
        self.playManager = playManager

        let parsed = LyricsEditorPolicy.parse(lyrics)
        originalLines = parsed
        // 🔴 `sourceText` 一开始就跟 `lines` 对齐（`export`），不要留开页原文当第二条草稿 ——
        // 否则进原文时若条件写错，文本框会露出"解析前"那份，跟行上已改的内容对不上。
        current = Snapshot(
            lines: parsed,
            rowIssues: LyricsEditorPolicy.rowIssues(in: parsed),
            cursorIndex: 0,
            mode: .lines,
            timingPage: .line,
            syllableCursorIndex: 0,
            sourceText: LyricsEditorPolicy.export(parsed),
            isEdited: false
        )
        snapshotRelay = BehaviorRelay(value: current)
        isPlayingRelay = BehaviorRelay(value: playManager.stateRelayCurrentIsPlaying)
        snapshot = snapshotRelay.asObservable()
        isPlaying = isPlayingRelay.asObservable()
        notice = noticeRelay.asObservable()

        // 播放状态变了 → 歌曲条那颗键换图标。
        // 🔴 订 `state`（低频），**不订 `position`**：这一页只有"点一下打点"要位置，
        // "这一刻几秒"由页面自己去订 `position`。
        playManager.state
            .map(\.isPlaybackActive)
            .distinctUntilChanged()
            .subscribe(onNext: { [weak self] playing in
                self?.isPlayingRelay.accept(playing)
            })
            .disposed(by: disposeBag)
    }

    // MARK: - 页面问它

    /// 这一刻的草稿（页面建控件时用一次）。
    var now: Snapshot { current }

    /// 这首歌（歌曲条上的歌名 / 艺人 / 封面都从这儿取）。
    var trackForDisplay: Track { track }

    // MARK: - 动作

    /// 切模式。
    ///
    /// 🔴 **行是唯一真相**：
    /// - **进原文** → `sourceText = export(lines)`（投影，不是另开一份草稿）；
    /// - **出原文** → `lines = parse(sourceText)`（原文里的改动已经在 `setSourceText` 里同步过，
    ///   这里再解析一次是收口，防页面漏调）。
    func setMode(_ mode: Mode) {
        guard current.mode != mode else { return }
        var next = current
        if current.mode == .source {
            next.lines = LyricsEditorPolicy.parse(current.sourceText)
        } else if mode == .source {
            next.sourceText = LyricsEditorPolicy.export(current.lines)
        }
        next.mode = mode
        commit(next)
    }

    /// 改第 `index` 行的正文。
    func setText(_ text: String, at index: Int) {
        guard current.lines.indices.contains(index), current.lines[index].text != text else { return }
        var next = current
        next.lines = LyricsEditorPolicy.settingText(text, at: index, in: next.lines)
        commit(next)
    }

    /// 改「原文」模式文本框里的那一段。
    ///
    /// 🔴 **立刻 `parse` 回 `lines`** —— 原文不是第二条草稿；不这样的话：
    /// 保存只看 `lines`、`isEdited` 只比 `lines`，在原文里改完字会既存不上、保存键也不亮。
    func setSourceText(_ text: String) {
        guard current.sourceText != text else { return }
        var next = current
        next.sourceText = text
        next.lines = LyricsEditorPolicy.parse(text)
        commit(next)
    }

    /// 取词取回来的那一份 —— **整份换进工作层**（口径同 `setSourceText`：文本 → `parse` → `lines`）。
    ///
    /// 🔴 **`sourceText` 必须一起换**：保存时若正在「原文」模式，`linesForSave()` 走的是
    /// `parse(sourceText)` —— 只换 `lines` 的话，用户在原文模式点保存，**取回来的词会被旧正文盖回去**。
    ///
    /// ⚠️ **不去跟当前内容比"变没变"**：`sourceText` 只在进出原文模式时才跟 `lines` 对齐，
    /// 拿它当"改过没有"的判据会在"在逐行模式改过字、再取回原样的词"时误判成没改而整份不换。
    /// 换不换的**只有取词页那一句确认**，到这儿就是无条件换。
    ///
    /// - Parameter text: 取词页转好交回来的正文（**非空**：转完一个字都不剩算「没找到」，根本不会交回来）。
    func applyFetchedLyrics(_ text: String) {
        guard !text.isEmpty else {
            assertionFailure("取词交回来的正文不该是空的 —— 空的那一边就该报「没找到」")
            return
        }
        var next = current
        next.sourceText = text
        next.lines = LyricsEditorPolicy.parse(text)
        // 整份都换了 ⇒ 光标回第一行（停在第 37 行没有意义，而那一行现在可能是空的）。
        next.cursorIndex = 0
        next.syllableCursorIndex = 0
        commit(next)
    }

    /// 把光标移到第 `index` 行（点行、上一句 / 下一句、跟随播放都走它）。
    func moveCursor(to index: Int) {
        var next = current
        next.cursorIndex = Self.clampedCursor(index, in: current.lines.count)
        // 换了行 ⇒ 字游标回第一个字（不然会带着上一行的字号跑到新行里去）。
        if next.cursorIndex != current.cursorIndex { next.syllableCursorIndex = 0 }
        commit(next)
    }

    // MARK: - 动作 · 逐字（打轴页那一页）

    /// 当前字所在那一行的逐字块 —— **当场解析**，不缓存。
    var syllablesInCursorLine: [LyricsEditorSyllable] {
        guard current.lines.indices.contains(current.cursorIndex) else { return [] }
        return LyricsSyllableTimingPolicy.syllables(inLine: current.lines[current.cursorIndex].text)
    }

    /// 切「打轴」里的那一页（逐行打轴 / 逐字打轴）。
    func setTimingPage(_ page: TimingPage) {
        guard current.timingPage != page else { return }
        var next = current
        next.timingPage = page
        commit(next)
    }

    /// 选中第 `index` 个字（点逐字条上某一块）。
    func selectSyllable(at index: Int) {
        var next = current
        next.syllableCursorIndex = index
        commit(next)
    }

    /// 字游标前后挪一格（打轴面板逐字条选中；工具条始终管行，不走这里）。
    func moveSyllableCursor(by offset: Int) {
        var next = current
        next.syllableCursorIndex = current.syllableCursorIndex + offset
        commit(next)
    }

    /// 给**当前这一个字**打点，字游标往前推一格 —— 就是那颗「打这一字并下一字」。
    ///
    /// ⚠️ 时间**读一次** `currentPosition`（跟整行打点同一条口径）。
    /// 🔴 写的只是那一个 `<mm:ss.xx>` 标签的字节，其余正文一个不动。
    func stampSyllableAndAdvance() {
        let row = current.cursorIndex
        guard current.lines.indices.contains(row) else { return }
        var next = current
        if let rewritten = LyricsSyllableTimingPolicy.replacingStart(
            playManager.currentPosition,
            ofSyllableAt: current.syllableCursorIndex,
            inLine: current.lines[row].text
        ) {
            next.lines = LyricsEditorPolicy.settingText(rewritten, at: row, in: next.lines)
        }
        next.syllableCursorIndex = current.syllableCursorIndex + 1
        commit(next)
    }

    /// 微调**当前这一个字**（打轴页工具条上那对 `±`）。
    func nudgeCurrentSyllable(by delta: TimeInterval) {
        nudgeSyllable(at: current.cursorIndex, syllable: current.syllableCursorIndex, by: delta)
    }

    /// 打点 —— 把**现在**的时间打给第 `index` 行，并把光标移过去。
    ///
    /// 🔴 时间**读一次** `currentPosition`，不订流（打点用播放头瞬时值；中间格随后显示打完的行时间）。
    func stampNow(at index: Int) {
        guard current.lines.indices.contains(index) else { return }
        var next = current
        next.lines = LyricsEditorPolicy.settingTime(
            playManager.currentPosition, at: index, in: next.lines
        )
        next.cursorIndex = index
        commit(next)
    }

    /// 微调光标那一行（`±0.5 s`）—— **整行一起挪**（行时间 ＋ 正文里的逐字标记）。
    /// **还没打轴时**以"现在几秒"为基准。
    func nudgeCurrent(by delta: TimeInterval) {
        var next = current
        next.lines = LyricsEditorPolicy.nudging(
            delta,
            at: current.cursorIndex,
            base: playManager.currentPosition,
            in: next.lines
        )
        commit(next)
    }

    /// 微调第 `index` 行里第 `syllable` 个字的起点（`±0.1s`，「当前字细条」上那对键）。
    ///
    /// 🔴 **只换那一个 `<mm:ss.xx>` 标签的字节**，其余正文一个不动；
    /// 句子时间不跟着改。到界（邻字或句子时间夹住）时 `nudgingStart` 返回 `nil`，这里就什么都不做。
    func nudgeSyllable(at index: Int, syllable: Int, by delta: TimeInterval) {
        guard current.lines.indices.contains(index) else { return }
        let line = current.lines[index]
        guard let rewritten = LyricsSyllableTimingPolicy.nudgingStart(
            by: delta,
            syllableAt: syllable,
            inLine: line.text,
            lineTime: line.time
        ) else { return }
        var next = current
        next.lines = LyricsEditorPolicy.settingText(rewritten, at: index, in: next.lines)
        commit(next)
    }

    /// 现在该高亮第几行 —— 跟着播放头走的那一格。
    ///
    /// ⚠️ **不进 `Snapshot`**：它是"播放头变了"，跟"草稿变了"是两件事；
    /// 混进草稿会让**每 10 Hz 的 tick 都重算一遍每行问题**（O(n²)，正是这一页当初
    /// 刻意不订 `position` 的原因）。页面拿它只做一件事：把光标挪过去。
    ///
    /// - Returns: 这一趟该高亮的行；播放头还没到第一句 / 一行都没打轴 ⇒ `nil`。
    func followedLineIndex(at playbackTime: TimeInterval) -> Int? {
        LyricsPlaybackPolicy.activeLineIndex(
            inOrderedTimestamps: current.lines.map(\.time),
            at: playbackTime
        )
    }

    /// 全局偏移 —— 整份一起挪（行时间 ＋ 正文里的逐字标记），撞到 0 就**整份一起停住**。
    ///
    /// 🔴 不是逐行 `max(0, time + value)`（§B10：会把靠前的句子先塌到 0 挤成一堆、
    /// 行距**永久破坏且不可逆**）。修法见 `LyricsEditorPolicy.shifted`（照 primuse 做法）。
    ///
    /// - Parameter seconds: 偏移量（负数 = 整体提前）。
    func applyGlobalShift(seconds: TimeInterval) {
        var next = current
        next.lines = LyricsEditorPolicy.shifted(next.lines, by: seconds)
        commit(next)
    }

    /// 播放 / 暂停 —— 歌曲条那颗键。
    func togglePlayback() {
        playManager.togglePlayPause()
    }

    // MARK: - 保存

    /// 保存前的**问题清单**（空数组 ＝ 没问题，可直接存）。
    ///
    /// - 文案照抄（标题「保存歌词时遇到问题」＋ 每行 `N行，xxx`，最多 4 条），只换了存储。
    func saveIssueMessages() -> [String] {
        LyricsEditorPolicy.saveIssueMessages(in: linesForSave())
    }

    /// 存。
    ///
    /// 🔴 **只写 `customLyrics`**：不碰侧表那份内嵌歌词、不碰音频文件。
    /// ⇒ 保存完**不用**在这里通知播放器 —— `AppServices` 盯着曲库流，变了会把**整张表**换给
    /// `PlayManager.updateTrackTable`。这一页不必认识播放器。
    func save() {
        let text = LyricsEditorPolicy.export(linesForSave())
        do {
            try library.saveCustomLyrics(text, for: track)
            noticeRelay.accept(Notice(text: "歌词已应用", style: .success))
        } catch {
            noticeRelay.accept(Notice(text: "保存失败", style: .error))
        }
    }

    // MARK: - 私有

    /// 保存用的行 —— 原文模式再从 `sourceText` 收一次，防页面漏调 `setSourceText`。
    private func linesForSave() -> [LyricsEditorLine] {
        if current.mode == .source {
            return LyricsEditorPolicy.parse(current.sourceText)
        }
        return current.lines
    }

    /// 算出下一份并推出去。
    ///
    /// 🔴 **每一份的「每行问题」都在这里算好**（不散在各个动作里）—— 否则"改了正文 ⇒ 角标要跟着变"
    /// 这件事会在每个动作里各写一遍，漏一处就出现"改了字但角标还是老的"。
    private func commit(_ next: Snapshot) {
        var normalized = next
        // 光标可能落在新行数之外（原文模式改短了）—— 收口在这一处，别在每个动作里各夹一次。
        normalized.cursorIndex = Self.clampedCursor(next.cursorIndex, in: next.lines.count)
        // 字游标同理：换了行 / 这一行少了一个字，都要夹回来（同样只在收口处夹一次）。
        normalized.syllableCursorIndex = Self.clampedSyllableCursor(
            next.syllableCursorIndex,
            in: syllableCount(ofRowAt: normalized.cursorIndex, in: normalized.lines)
        )
        normalized.rowIssues = LyricsEditorPolicy.rowIssues(in: normalized.lines)
        normalized.isEdited = LyricsEditorPolicy.isEdited(
            normalized.lines, comparedTo: originalLines
        ) == .edited
        current = normalized
        snapshotRelay.accept(current)
    }

    /// 把行号夹进 `0 ..< count`（`count` 为 0 时给 0）。
    private static func clampedCursor(_ index: Int, in count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, index), count - 1)
    }

    /// 把字游标夹进 `0 ..< count`（`count` 为 0 时给 0）。
    private static func clampedSyllableCursor(_ index: Int, in count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, index), count - 1)
    }

    /// 第 `row` 行有几个字；行越界 ⇒ `0`。
    private func syllableCount(ofRowAt row: Int, in lines: [LyricsEditorLine]) -> Int {
        guard lines.indices.contains(row) else { return 0 }
        return LyricsSyllableTimingPolicy.syllables(inLine: lines[row].text).count
    }
}

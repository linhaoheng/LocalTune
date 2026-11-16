import Foundation
import RxRelay
import RxSwift

/// 「编辑歌词」页的**草稿与动作** —— 页面只订阅它、把用户动作交给它。
///
/// ## 真相
///
/// **原文（`sourceText`）是真相**；`lines` 是内存里的工作副本（带逐字 start/end）。
/// 任何编辑都改工作副本，然后按**原文的语法**（`.lrc` / `.krcLayout`）写回 `sourceText`。
/// 不编辑就不重写 ⇒ 保存时原文可以逐字节不变。
///
/// ## 🔴 它不认识的东西
///
/// - **不碰播放器的状态**：打点时**读一次** `currentPosition`。
/// - **不碰音频文件 / 侧表那份内嵌歌词**：保存只调 `LibraryStore.saveCustomLyrics`。
///
/// ## 线程
///
/// 全在主线程。
@MainActor
final class LyricsEditorViewModel {

    // MARK: - 推给页面的东西

    /// 三个模式。
    enum Mode: Int, CaseIterable {
        case lines
        case timing
        case source

        var title: String {
            switch self {
            case .lines: return "逐行"
            case .timing: return "打轴"
            case .source: return "原文"
            }
        }
    }

    /// 「打轴」内部的**两页**。
    enum TimingPage: Int, CaseIterable {
        case line
        case syllable

        var title: String {
            switch self {
            case .line: return "逐行打轴"
            case .syllable: return "逐字打轴"
            }
        }
    }

    /// 草稿这一刻的样子 —— 页面重画**全靠这一份**。
    struct Snapshot: Equatable {

        /// 行投影（逐字写成 `<mm:ss.xx>` 标签）—— 页面只读它。
        var lines: [LyricsEditorLine]

        var rowIssues: [[LyricIssueKind]]
        var cursorIndex: Int
        var mode: Mode
        var timingPage: TimingPage
        var syllableCursorIndex: Int

        /// 「原文」文本框里那一段 —— **真相**。
        var sourceText: String

        var isEdited: Bool

        /// 这份原文能不能进「原文」模式改（KRC 布局写不了时不能）。
        var canEditSource: Bool

        static let empty = Snapshot(
            lines: [],
            rowIssues: [],
            cursorIndex: 0,
            mode: .lines,
            timingPage: .line,
            syllableCursorIndex: 0,
            sourceText: "",
            isEdited: false,
            canEditSource: true
        )
    }

    struct Notice: Equatable {
        let text: String
        let style: HUD.Style
    }

    let snapshot: Observable<Snapshot>
    let isPlaying: Observable<Bool>
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

    /// 工作副本（不是持久数据）。
    private var lines: [LyricsLine]

    /// 原文的语法 —— **打开时实际读成了什么**（不是"看着像什么"）。
    ///
    /// 它同时决定这份原文能不能改：没有写口的语法（`yrc` / `qrc` / `lys` / `vtt` / `srt` /
    /// `ttml`）整页**只读** —— 能看、能跟着播，但一个字都不许改，因为改了也没地方写回去，
    /// 而保存只会把原文原样保存（§6.3）。KRC 布局写不了时**不翻格式**，等用户补轴。
    private var syntax: LyricsSyntax

    /// **真相**：原文。
    private var sourceText: String

    /// 打开时解析出的工作副本（判"改过没有"）。
    private let originalLines: [LyricsLine]

    /// 打开时原文里的问题 —— **那些行解析时就被丢掉了**，工作副本里看不到它们。
    /// 打开后报一次（`announceSourceIssues`），之后不再打扰。
    private let sourceIssues: [LyricsEditorPolicy.SourceIssue]

    /// 提示只弹一次：KRC 布局写不了 / 只读语法不许改 / 原文里读不出来的行。补好之后复位。
    private var krcLayoutNoticeShown = false
    private var readOnlyNoticeShown = false
    private var sourceIssuesAnnounced = false

    private var current: Snapshot

    // MARK: - 建立

    init(track: Track, lyrics: String, library: LibraryStore, playManager: PlayManager) {
        self.track = track
        self.library = library
        self.playManager = playManager

        let document = Self.readDocument(lyrics)
        self.lines = document.lines
        self.syntax = document.syntax
        self.sourceText = lyrics
        self.originalLines = document.lines
        self.sourceIssues = LyricsEditorPolicy.sourceIssues(in: lyrics)

        let rows = Self.rows(from: document.lines)
        current = Snapshot(
            lines: rows,
            rowIssues: LyricsEditorPolicy.rowIssues(in: rows),
            cursorIndex: 0,
            mode: .lines,
            timingPage: .line,
            syllableCursorIndex: 0,
            sourceText: lyrics,
            isEdited: false,
            canEditSource: Self.canEditSource(syntax: document.syntax, lines: document.lines)
        )
        snapshotRelay = BehaviorRelay(value: current)
        isPlayingRelay = BehaviorRelay(value: playManager.stateRelayCurrentIsPlaying)
        snapshot = snapshotRelay.asObservable()
        isPlaying = isPlayingRelay.asObservable()
        notice = noticeRelay.asObservable()

        playManager.state
            .map(\.isPlaybackActive)
            .distinctUntilChanged()
            .subscribe(onNext: { [weak self] playing in
                self?.isPlayingRelay.accept(playing)
            })
            .disposed(by: disposeBag)
    }

    // MARK: - 页面问它

    var now: Snapshot { current }
    var trackForDisplay: Track { track }

    /// 打开后报一次**原文级问题** —— 读的时候被丢掉的坏行。
    ///
    /// 只报第一条 ＋ 总数：这是"提醒你原文里有东西看不懂"，不是逐条清单（逐行清单在
    /// 页面上由 `rowIssues` 标）。页面在 `viewDidAppear` 调一次。
    func announceSourceIssues() {
        guard !sourceIssuesAnnounced, let first = sourceIssues.first else { return }
        sourceIssuesAnnounced = true
        let suffix = sourceIssues.count > 1 ? "（共 \(sourceIssues.count) 处）" : ""
        noticeRelay.accept(
            Notice(text: "第\(first.lineNumber)行 \(first.kind.label)\(suffix)", style: .error)
        )
    }

    // MARK: - 动作

    /// 切模式。原文是真相，所以进/出原文都**不再 export/parse 覆盖**。
    func setMode(_ mode: Mode) {
        guard current.mode != mode else { return }
        // KRC 布局写不了（有没打轴的行等）时，原文框没法忠实显示工作副本 —— 先别进去。
        if mode == .source, !current.canEditSource {
            if syntax == .krcLayout, let issue = LyricsTextSerializer.krcLayoutIssue(in: lines) {
                notifyKRCLayoutIssue(issue, force: true)
            }
            return
        }
        if current.mode == .source {
            // 从原文回来：把文本重新拆成工作副本（文本在 `setSourceText` 里已经是最新的）。
            let document = Self.readDocument(sourceText)
            lines = document.lines
            syntax = document.syntax
        }
        var next = current
        next.mode = mode
        commit(next)
    }

    /// 改第 `index` 行的正文。正文一变，逐字清掉（区间失效）。
    func setText(_ text: String, at index: Int) {
        guard lines.indices.contains(index), lines[index].text != text else { return }
        guard ensureEditable() else { return }
        lines[index].text = text
        lines[index].syllables = nil
        syncText()
        commit(current)
    }

    /// 改原文文本 —— **真相**。立刻重拆工作副本。
    func setSourceText(_ text: String) {
        guard sourceText != text else { return }
        guard ensureEditable() else { return }
        sourceText = text
        let document = Self.readDocument(text)
        lines = document.lines
        syntax = document.syntax
        readOnlyNoticeShown = false
        commit(current)
    }

    /// 取词取回来的那一份 —— 整份换进原文。
    ///
    /// 取词出口已经**一律转成 LRC**（`歌词子系统设计.md` §5.2），所以换进来的这份
    /// 无论源站是什么格式，语法都是 `.lrc`（可改、可写回）。这里不用再判格式。
    func applyFetchedLyrics(_ text: String) {
        guard !text.isEmpty else {
            assertionFailure("取词交回来的正文不该是空的 —— 空的那一边就该报「没找到」")
            return
        }
        sourceText = text
        let document = Self.readDocument(text)
        lines = document.lines
        syntax = document.syntax
        readOnlyNoticeShown = false
        krcLayoutNoticeShown = false
        var next = current
        next.cursorIndex = 0
        next.syllableCursorIndex = 0
        commit(next)
    }

    func moveCursor(to index: Int) {
        var next = current
        next.cursorIndex = Self.clampedCursor(index, in: current.lines.count)
        if next.cursorIndex != current.cursorIndex { next.syllableCursorIndex = 0 }
        commit(next)
    }

    // MARK: - 逐字

    var syllablesInCursorLine: [LyricsEditorSyllable] {
        syllables(inRow: current.cursorIndex)
    }

    /// 某一行的逐字块 —— **直接从工作副本拿**，不从正文重新解析。
    ///
    /// 那份数组里最后一项可能是「这一行结束」那一格（`text` 空，见 `LyricSyllable.isLineEnd`）；
    /// 它照样投影过来，逐字条才有最后一格可点、可打。
    func syllables(inRow row: Int) -> [LyricsEditorSyllable] {
        guard lines.indices.contains(row), let syllables = lines[row].syllables else { return [] }
        return syllables.map {
            LyricsEditorSyllable(text: $0.text, start: $0.start)
        }
    }

    func setTimingPage(_ page: TimingPage) {
        guard current.timingPage != page else { return }
        var next = current
        next.timingPage = page
        commit(next)
    }

    func selectSyllable(at index: Int) {
        var next = current
        next.syllableCursorIndex = index
        commit(next)
    }

    func moveSyllableCursor(by offset: Int) {
        var next = current
        next.syllableCursorIndex = current.syllableCursorIndex + offset
        commit(next)
    }

    /// 给**当前这一个字**打点，字游标往前推一格。
    func stampSyllableAndAdvance() {
        guard ensureEditable() else { return }
        let row = current.cursorIndex
        var next = current
        next.syllableCursorIndex = current.syllableCursorIndex + 1

        guard lines.indices.contains(row),
              var syllables = lines[row].syllables,
              syllables.indices.contains(current.syllableCursorIndex) else {
            commit(next)
            return
        }

        let index = current.syllableCursorIndex
        let lowerBound = index > 0 ? syllables[index - 1].start : 0
        let target = max(lowerBound, playManager.currentPosition)
        let delta = target - syllables[index].start

        if delta != 0 {
            for i in index..<syllables.count {
                syllables[i].start = max(target, syllables[i].start + delta)
                syllables[i].end = max(syllables[i].start, syllables[i].end + delta)
            }
        }
        if index > 0 {
            // 上一字的结束 = 这一格的起点 —— 一个数、一处表达。
            // 🔴 **只改推出来的那种**（`.inferred`）：KRC 布局每个字自带明写的字长（`.explicit`），
            // 那是源档的数据，不许被"下一格开口"顶掉 —— 照 primuse `stampSyllable` 的守卫。
            // 打的就是句尾那一格时，这一下同时把"这一句唱到几秒"定下来了。
            if syllables[index - 1].endTiming != .explicit {
                syllables[index - 1].end = target
            }
        } else {
            lines[row].timestamp = target
            lines[row].isSynchronized = true
        }
        // 行尾（KRC 布局的「行长」）跟着这一趟平移走：末字被推后了，行尾不能留在原地，
        // 否则写回去的行长比末字的结束还短。照 primuse `stampSyllable` 同一句。
        if let end = lines[row].endTimestamp {
            lines[row].endTimestamp = max(syllables.map(\.end).max() ?? target, end + delta)
        }
        lines[row].syllables = syllables
        syncText()
        commit(next)
    }

    func nudgeCurrentSyllable(by delta: TimeInterval) {
        nudgeSyllable(at: current.cursorIndex, syllable: current.syllableCursorIndex, by: delta)
    }

    /// 打点 —— 把**现在**的时间打给第 `index` 行，并把光标移过去。
    func stampNow(at index: Int) {
        guard ensureEditable() else { return }
        guard lines.indices.contains(index) else { return }
        let target = max(0, playManager.currentPosition)
        if lines[index].isSynchronized {
            shiftLine(at: index, by: target - lines[index].timestamp)
        } else if let first = lines[index].syllables?.first {
            shiftLine(at: index, by: target - first.start)
        }
        lines[index].timestamp = target
        lines[index].isSynchronized = true
        syncText()

        var next = current
        next.cursorIndex = index
        commit(next)
    }

    /// 微调光标那一行：整行连同逐字一起挪；没打轴时以"现在几秒"为基准。
    func nudgeCurrent(by delta: TimeInterval) {
        guard ensureEditable() else { return }
        let index = current.cursorIndex
        guard lines.indices.contains(index) else { return }
        if lines[index].isSynchronized {
            let target = max(0, lines[index].timestamp + delta)
            shiftLine(at: index, by: target - lines[index].timestamp)
            lines[index].timestamp = target
        } else {
            lines[index].timestamp = max(0, playManager.currentPosition + delta)
            lines[index].isSynchronized = true
        }
        syncText()
        commit(current)
    }

    /// 微调第 `index` 行里第 `syllable` 个字的起点（被前后字夹住）。
    func nudgeSyllable(at index: Int, syllable: Int, by delta: TimeInterval) {
        guard ensureEditable() else { return }
        guard lines.indices.contains(index),
              var syllables = lines[index].syllables,
              syllables.indices.contains(syllable) else { return }

        let currentStart = syllables[syllable].start
        let lowerBound = syllable > 0 ? syllables[syllable - 1].start : 0
        var upperBound = syllable + 1 < syllables.count
            ? syllables[syllable + 1].start
            : .greatestFiniteMagnitude
        // 🔴 **明写的字长是硬上界**：KRC 布局每个字自带时长，起点不许越过自己的结束，
        // 越过去字长就成了负数 —— 照 primuse `nudgeSyllable`。
        // ⚠️ 句尾格例外：它是"一个点"（`end` 恒等于 `start`），拿它当上界会把这一格钉死。
        if syllables[syllable].endTiming == .explicit, !syllables[syllable].isLineEnd {
            upperBound = min(upperBound, syllables[syllable].end)
        }
        // 行尾（KRC 布局的「行长」）同样封顶 —— 照 primuse `nudgeSyllable`。
        if let lineEnd = lines[index].endTimestamp {
            upperBound = min(upperBound, lineEnd)
        }
        let target = min(max(currentStart + delta, lowerBound), upperBound)

        syllables[syllable].start = target
        // 句尾那一格本身就是一个"点"：起点一动，它的结束跟着动（`start == end`），
        // 否则会出现"句尾格自己没有长度、却有个更早的 end"这种自相矛盾。
        if syllables[syllable].isLineEnd {
            syllables[syllable].end = target
        }
        if syllable > 0 {
            // 同打点那一处：推出来的结束跟着这一格的起点走，明写的字长不动。
            if syllables[syllable - 1].endTiming != .explicit {
                syllables[syllable - 1].end = target
            }
        } else {
            lines[index].timestamp = target
        }
        lines[index].syllables = syllables
        syncText()
        commit(current)
    }

    func followedLineIndex(at playbackTime: TimeInterval) -> Int? {
        LyricsPlaybackPolicy.activeLineIndex(
            inOrderedTimestamps: lines.map { $0.isSynchronized ? $0.timestamp : nil },
            at: playbackTime
        )
    }

    /// 全局偏移 —— 整份一起挪，撞到 0 就整份停住。
    func applyGlobalShift(seconds: TimeInterval) {
        guard seconds != 0 else { return }
        guard ensureEditable() else { return }
        var earliest: TimeInterval?
        for line in lines {
            if line.isSynchronized { earliest = min(earliest ?? line.timestamp, line.timestamp) }
            for syllable in line.syllables ?? [] {
                earliest = min(earliest ?? syllable.start, syllable.start)
            }
        }
        guard let earliest else { return }
        let applied = max(0, earliest + seconds) - earliest
        guard applied != 0 else { return }

        for index in lines.indices {
            if lines[index].isSynchronized {
                lines[index].timestamp = max(0, lines[index].timestamp + applied)
            }
            if let end = lines[index].endTimestamp {
                lines[index].endTimestamp = max(0, end + applied)
            }
            if let syllables = lines[index].syllables {
                lines[index].syllables = syllables.map {
                    LyricSyllable(
                        text: $0.text,
                        start: max(0, $0.start + applied),
                        end: max(0, $0.end + applied),
                        endTiming: $0.endTiming
                    )
                }
            }
        }
        syncText()
        commit(current)
    }

    func togglePlayback() {
        playManager.togglePlayPause()
    }

    // MARK: - 保存

    func saveIssueMessages() -> [String] {
        LyricsEditorPolicy.saveIssueMessages(in: current.lines)
    }

    /// 存**原文**（不再 export）。KRC 布局写不了就拒绝，不回落。
    ///
    /// 🔴 **只读语法（`yrc` / `ttml` …）走到这里就是原样保存**：整页一个字都没让改，
    /// `sourceText` 还是打开时那一份 ⇒ 保存等于"原文不变"，不会被改写成 LRC。
    func save() {
        if syntax == .krcLayout, let issue = LyricsTextSerializer.krcLayoutIssue(in: lines) {
            notifyKRCLayoutIssue(issue, force: true)
            return
        }
        do {
            try library.saveCustomLyrics(sourceText, for: track)
            noticeRelay.accept(Notice(text: "歌词已应用", style: .success))
        } catch {
            noticeRelay.accept(Notice(text: "保存失败", style: .error))
        }
    }

    // MARK: - 私有

    /// 工作副本 → 页面投影。
    ///
    /// 🔴 这里**只给正文和时间**：逐字块由页面直接调 `syllables(inRow:)` 从工作副本拿，
    /// 不再拼 `<mm:ss.xx>` 标签让格子再解析回去。
    private static func rows(from lines: [LyricsLine]) -> [LyricsEditorLine] {
        lines.map { line in
            LyricsEditorLine(
                time: line.isSynchronized ? line.timestamp : nil,
                text: line.text
            )
        }
    }

    /// 文本 → 语法 ＋ 工作副本；什么都读不出来时给一行空行（页面永远有一行可编辑）。
    private struct Document {
        let syntax: LyricsSyntax
        let lines: [LyricsLine]
    }

    private static func readDocument(_ text: String) -> Document {
        guard let outcome = LyricsParser.outcome(text), !outcome.lines.isEmpty else {
            return Document(
                syntax: .lrc,
                lines: [LyricsLine(timestamp: 0, text: "", isSynchronized: false)]
            )
        }
        return Document(syntax: outcome.syntax, lines: outcome.lines)
    }

    /// 这份原文能不能改。
    ///
    /// - 没有写口的语法（`yrc` / `qrc` / `lys` / `vtt` / `srt` / `ttml`）：不能 —— 改了没地方写回；
    /// - KRC 布局：还要看今天这堆行写不写得出来（没打轴 / 正文带尖括号 / 带译文都写不了）；
    /// - LRC：能。
    private static func canEditSource(syntax: LyricsSyntax, lines: [LyricsLine]) -> Bool {
        guard syntax.hasWriter else { return false }
        guard syntax == .krcLayout else { return true }
        return LyricsTextSerializer.krcLayoutIssue(in: lines) == nil
    }

    /// 想改工作副本之前的**唯一闸门**。
    ///
    /// 只读语法下弹一次提示就够 —— 用户连点几次不该被刷屏。
    private func ensureEditable() -> Bool {
        guard syntax.hasWriter else {
            if !readOnlyNoticeShown {
                readOnlyNoticeShown = true
                noticeRelay.accept(
                    Notice(text: "\(syntax.displayName) 歌词只能看，不能改", style: .error)
                )
            }
            return false
        }
        return true
    }

    /// 把工作副本写回原文。
    ///
    /// 🔴 **写不了就不写**（不回落）：KRC 布局遇到写不了的行、或这种语法根本没有写口时，
    /// `sourceText` 保持上一次能写的版本 —— 绝不退回另一种语法替用户换格式。
    private func syncText() {
        if syntax == .krcLayout, let issue = LyricsTextSerializer.krcLayoutIssue(in: lines) {
            notifyKRCLayoutIssue(issue)
            return
        }
        guard let text = LyricsTextSerializer.serialize(lines, as: syntax) else { return }
        krcLayoutNoticeShown = false
        sourceText = text
    }

    /// KRC 布局写不了的提示（每次卡住只弹一次；保存时强制再弹）。
    private func notifyKRCLayoutIssue(
        _ issue: LyricsTextSerializer.KRCLayoutIssue,
        force: Bool = false
    ) {
        guard force || !krcLayoutNoticeShown else { return }
        krcLayoutNoticeShown = true
        let message: String
        switch issue {
        case .untimed(let index):
            message = "第\(index + 1)行没打轴，不能存成 KRC 布局"
        case .markup(let index):
            message = "第\(index + 1)行有 < 或 >，不能存成 KRC 布局"
        case .translation(let index):
            message = "第\(index + 1)行有译文，不能存成 KRC 布局"
        }
        noticeRelay.accept(Notice(text: message, style: .error))
    }

    /// 整行（含逐字、行尾）平移。
    private func shiftLine(at index: Int, by delta: TimeInterval) {
        guard delta != 0 else { return }
        if let end = lines[index].endTimestamp {
            lines[index].endTimestamp = max(0, end + delta)
        }
        guard let syllables = lines[index].syllables else { return }
        lines[index].syllables = syllables.map {
            LyricSyllable(
                text: $0.text,
                start: max(0, $0.start + delta),
                end: max(0, $0.end + delta),
                endTiming: $0.endTiming
            )
        }
    }

    private func commit(_ next: Snapshot) {
        var normalized = next
        normalized.lines = Self.rows(from: lines)
        normalized.sourceText = sourceText
        normalized.isEdited = lines != originalLines
        normalized.cursorIndex = Self.clampedCursor(
            normalized.cursorIndex, in: normalized.lines.count
        )
        normalized.syllableCursorIndex = Self.clampedSyllableCursor(
            normalized.syllableCursorIndex,
            in: syllableCount(at: normalized.cursorIndex)
        )
        normalized.rowIssues = LyricsEditorPolicy.rowIssues(in: normalized.lines)
        normalized.canEditSource = Self.canEditSource(syntax: syntax, lines: lines)

        current = normalized
        snapshotRelay.accept(current)
    }

    private static func clampedCursor(_ index: Int, in count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, index), count - 1)
    }

    private static func clampedSyllableCursor(_ index: Int, in count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, index), count - 1)
    }

    private func syllableCount(at row: Int) -> Int {
        guard lines.indices.contains(row) else { return 0 }
        return lines[row].syllables?.count ?? 0
    }
}

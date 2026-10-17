import Foundation
import RxRelay
import RxSwift

/// 「这首歌的歌词」＋「现在唱到第几行」—— 播放域里**唯一**管歌词的地方。
///
/// ## 它做两件事
///
/// - 订 `PlayManager.state`：装的歌换了（或那首歌的歌词被编辑过）→ 按 `LyricsSourcePolicy` 取一份、用 `LyricsParser` 重解析一遍；
/// - 订 `PlayManager.position`：播放时间 + 行表 → 二分出「现在该高亮第几行」；
///
/// 两样合成**一条** `snapshot` 推给界面 —— 界面拿到的永远是「哪一首 ＋ 行表 ＋ 当前行号」。
///
/// ## 换歌（对齐 primuse）
///
/// primuse 换歌时 `reloadLyrics` **先** `lyrics = []; currentIndex = -1`，再异步装新词
/// （`MacMiniPlayerView.reloadLyrics`）。我们同步解析，但仍分两步推：
/// 1. 空行表 + 新 `trackID`（界面立刻丢掉上一首的字和高亮）；
/// 2. 解析后的行表。
///
/// 只比歌词字符串、或换歌不先清空，都会出现「下一首了，上一首那几句还挂着、高亮还停在第 N 句」。
///
/// ## 线程
///
/// **全在主线程**：`state` / `position` 两条流本来就保证在主线程上推（见 `PlayManager`）。
@MainActor
final class LyricsManager {

    /// 歌词这一刻的样子 —— 界面收这一份就够。
    struct Snapshot: Equatable {

        /// 这份行表属于哪一首；`nil` ＝ 没装歌。
        let trackID: Track.ID?

        /// 解析后的行，按时间升序。没有歌词就是空数组。
        let lines: [LyricsLine]

        /// 现在该高亮第几行；`nil` ＝ 还没到第一句（或没有歌词）。
        let currentIndex: Int?

        static let empty = Snapshot(trackID: nil, lines: [], currentIndex: nil)
    }

    private let lookahead: TimeInterval

    /// 曲库 —— 用来取内嵌歌词。
    ///
    /// **为什么播放域现在要拿数据层**：拆表之前歌词跟着 `Track` 一起来
    ///（`PlayManager.state.track`），拆完之后"这首歌的歌词"要**按 id 再取一次**。
    /// 方向是本来就有的（`NowPlayingViewModel` 早就在 `library` 上取 `track(id:)`），不是新开的口子。
    private let library: LibraryStore

    /// 现在这一份。**界面只订这一条**。
    let snapshot: Observable<Snapshot>

    /// 此刻的快照（换歌时页面要用「正在播的 id」对齐行表）。
    var now: Snapshot { snapshotRelay.value }

    private let snapshotRelay = BehaviorRelay(value: Snapshot.empty)

    /// 上一次解析对应的曲目 ＋ 原文。
    ///
    /// 🔴 **两者都要比**：只比文本 ⇒ 换到歌词碰巧相同的下一首会跳过；
    /// 只比曲目 id ⇒ 同曲编辑过不会重解析。
    private var lastParsedTrackID: Track.ID?
    private var lastParsedText: String?

    private let disposeBag = DisposeBag()

    init(
        playManager: PlayManager,
        library: LibraryStore,
        lookahead: TimeInterval = AppMetrics.nowPlayingLyricsLookahead
    ) {
        self.library = library
        self.lookahead = lookahead
        snapshot = snapshotRelay.asObservable()

        playManager.state
            .subscribe(onNext: { [weak self] state in
                self?.reload(track: state.track)
            })
            .disposed(by: disposeBag)

        playManager.position
            .subscribe(onNext: { [weak self] position in
                self?.updateCurrentIndex(at: position)
            })
            .disposed(by: disposeBag)
    }

    // MARK: - 两条订阅的实现

    /// 曲目或原文变了才重解析。
    private func reload(track: Track?) {
        let trackID = track?.id
        // 内嵌歌词住在侧表 —— 按 id 取一次（主键查，微秒级）。
        let lyrics = trackID.flatMap { id in try? library.lyrics(for: id) }
        let raw = LyricsSourcePolicy.text(for: track, lyrics: lyrics) ?? ""
        let songChanged = trackID != lastParsedTrackID
        guard songChanged || raw != lastParsedText else { return }

        lastParsedTrackID = trackID
        lastParsedText = raw

        // 换歌：先推空表，界面马上拆掉上一首（primuse 同序）。
        if songChanged {
            snapshotRelay.accept(Snapshot(trackID: trackID, lines: [], currentIndex: nil))
        }

        snapshotRelay.accept(
            Snapshot(trackID: trackID, lines: LyricsParser.parse(raw), currentIndex: nil)
        )
    }

    /// 用现在这份行表算当前行号；算出来跟现在一样就不推。
    private func updateCurrentIndex(at position: TimeInterval) {
        let current = snapshotRelay.value
        // 换歌清空后的空表：行号保持 nil，别拿上一首的进度去「猜」一行。
        guard !current.lines.isEmpty else { return }
        let index = LyricsPlaybackPolicy.activeLineIndex(
            in: current.lines, at: position, lookahead: lookahead
        )
        guard index != current.currentIndex else { return }
        snapshotRelay.accept(
            Snapshot(trackID: current.trackID, lines: current.lines, currentIndex: index)
        )
    }
}

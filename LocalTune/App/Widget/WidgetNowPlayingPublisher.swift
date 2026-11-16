import Foundation
import RxSwift
import WidgetKit

/// 播放状态 → 小组件快照的发布者：订流、拼快照、落盘。
///
/// 🔴 **独立类型，不塞进 `PlayManager` 的 extension** —— 那是「按业务功能把核心
/// 职责拆文件」的假拆形状。它是小组件入口自己的订阅方，
/// 由装配层（`AppServices`）创建并持有。
///
/// 它只**读**播放域的流（`state` / `position` / 歌词快照），不碰引擎、不碰
/// `AVAudioSession`、不碰锁屏 —— 四条独占线零波及。
///
/// ## 触发源与采样
///
/// 触发只在**低频**时刻发：状态变了（放 / 停 / 切歌）/ 拖了进度。10Hz 的进度流
/// **只被采样、不当触发源** —— 它一进合并，每秒就是十次落盘加十次 reload，
/// 系统的刷新预算立刻见底。拼快照时用 `withLatestFrom` 采样当时的读数，
/// 与锁屏那条线（`AppServices`）是同一招。
///
/// 歌词换行也**不当触发源**（同理：逐句落盘就是逐句 reload，预算撑不住）——
/// 推进交给扩展按快照排未来 entry，见 `NowPlayingWidget`。
///
/// 落盘前去重：内容没变就不写、不 reload；去重**抹掉播放头**，
/// 否则每次采样都算"变了"。
///
/// ## 线程
///
/// 全在主线程：订的流都在主线程推（见 `PlayManager` / `LyricsManager` 文件头）；
/// 写盘是 `UserDefaults` 原子写加一张小 JPEG，主线程开销可忽略。
@MainActor
final class WidgetNowPlayingPublisher {

    /// 封面字节的产出动作 —— 装配层给（`AppArtwork` 那套「路径 → 字节」）。
    private let artworkJPEG: (String?) -> Data?

    /// 封面 JPEG 按曲目缓存 —— 换句歌词不重压同一张图。
    private var cachedArtwork: (trackID: Track.ID, data: Data?)?

    private let disposeBag = DisposeBag()

    /// 落盘前的那一份 —— 带上曲目身份与封面路径，缓存和落盘才知道用谁。
    private struct PendingSave {
        var snapshot: WidgetPlaybackSnapshot
        var trackID: Track.ID?
        var artworkPath: String?

        /// 同一首歌 + 同一张封面 + 内容没变 —— 详见
        /// `WidgetPlaybackSnapshot.hasSameContent(as:)`（不看时间戳与播放头）。
        func hasSameContent(as other: Self) -> Bool {
            guard trackID == other.trackID, artworkPath == other.artworkPath else { return false }
            return snapshot.hasSameContent(as: other.snapshot)
        }
    }

    init(
        playManager: PlayManager,
        lyricsManager: LyricsManager,
        artworkJPEG: @escaping (String?) -> Data?
    ) {
        self.artworkJPEG = artworkJPEG

        // 两路低频触发合一；每一路都只在"值得落盘"的时刻发一下。
        let triggers = Observable.merge(
            playManager.state.distinctUntilChanged().map { _ in () },
            playManager.seeks.map { _ in () }
        )

        triggers
            .withLatestFrom(context(playManager, lyricsManager)) { _, context in context }
            .map(Self.pendingSave(from:))
            .distinctUntilChanged { $0.hasSameContent(as: $1) }
            .subscribe(onNext: { [weak self] pending in
                self?.save(pending)
            })
            .disposed(by: disposeBag)
    }

    /// 采样源：位置 + 歌词快照 + 状态的"此刻那一份"。**只给 `withLatestFrom` 用**
    /// —— 里面有 10Hz 进度，直接订就是把进度流接进了触发线。
    private func context(
        _ playManager: PlayManager,
        _ lyricsManager: LyricsManager
    ) -> Observable<(state: PlayerState, position: TimeInterval, lyrics: LyricsManager.Snapshot)> {
        Observable.combineLatest(
            playManager.position,
            lyricsManager.snapshot,
            playManager.state
        ) { position, lyrics, state in
            (state: state, position: position, lyrics: lyrics)
        }
    }

    /// 播放域的歌词行 → 通道上的歌词行：**只留同步行**。
    ///
    /// 纯文本歌词（`isSynchronized == false`）的时间戳是占位 `0`，
    /// 混进来的话「按时间找当前行」永远落在它头上，所以整族剔掉。
    /// 剔完一首歌一行同步行都没有 → 空数组，扩展侧画「暂无歌词」。
    /// 🔴 翻译完才上通道 —— 通道模型与展示判断（`WidgetLyricsPolicy`）
    /// 都不认识播放域的值，扩展 target 也因此不用编译播放层。
    static func timedLines(from lines: [LyricsLine]) -> [WidgetLyricLine] {
        lines.filter(\.isSynchronized).map {
            WidgetLyricLine(time: $0.timestamp, text: $0.text)
        }
    }

    /// 拼快照：只装原始数据；没装歌就是 `empty`（视图画「未在播放」占位）。
    private static func pendingSave(
        from context: (state: PlayerState, position: TimeInterval, lyrics: LyricsManager.Snapshot)
    ) -> PendingSave {
        guard let track = context.state.track else {
            return PendingSave(snapshot: .empty, trackID: nil, artworkPath: nil)
        }
        let snapshot = WidgetPlaybackSnapshot(
            title: track.title,
            artist: track.artist,
            isPlaying: context.state.isPlaybackActive,
            hasArtwork: track.artworkPath != nil,
            updatedAt: 0,
            elapsed: context.position,
            lyrics: Self.timedLines(from: context.lyrics.lines)
        )
        return PendingSave(
            snapshot: snapshot,
            trackID: track.id,
            artworkPath: track.artworkPath
        )
    }

    /// 内容变了才落盘；封面字节按曲目缓存，不在触发线上反复压。
    private func save(_ pending: PendingSave) {
        guard let trackID = pending.trackID else {
            WidgetSharedStore.save(pending.snapshot, artworkJPEG: nil)
            return
        }
        WidgetSharedStore.save(pending.snapshot, artworkJPEG: cachedArtworkJPEG(trackID: trackID, pending: pending))
    }

    private func cachedArtworkJPEG(trackID: Track.ID, pending: PendingSave) -> Data? {
        if let cached = cachedArtwork, cached.trackID == trackID {
            return cached.data
        }
        let data = artworkJPEG(pending.artworkPath)
        cachedArtwork = (trackID, data)
        return data
    }
}

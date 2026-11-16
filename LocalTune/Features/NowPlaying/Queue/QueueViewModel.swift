import Foundation
import RxRelay
import RxSwift

/// 队列页的**状态与动作** —— 页面只订阅 `content`、把点击和 × 交给它。
///
/// 它不存队列：「排着哪些歌、播到第几格」只有 `PlayManager` 知道（`queueSnapshot`），
/// 这里只把快照翻成"这一页要画的行"，再把动作原样转回去。
///
/// ## 线程
///
/// **全在主线程**：`PlayManager` 的流在主线程推，页面动作也来自主线程。
@MainActor
final class QueueViewModel {

    // MARK: - 推给页面的东西

    /// 一行。
    struct Row: Equatable {
        /// 这一行是哪首歌 —— 动作要带上它，`PlayManager` 拿它核"这一下过没过期"。
        let trackID: Track.ID
        let title: String
        /// 是不是**正在播的那一格**（按位置认，见 `QueueSnapshot.currentIndex`）。
        let isCurrent: Bool
        /// 声波跳不跳：当前格 **且** 真的在出声（同曲库列表那组竖条，`isActuallyPlaying`）。
        let isPlaying: Bool
    }

    /// 这一页要画的东西。**`Equatable`** ⇒ 内容没变就不重画。
    struct Content: Equatable {
        let rows: [Row]
        /// 当前格在第几行 —— 打开时滚到它。
        let currentRow: Int?

        /// 表头那一行（「当前播放(N)」）。
        var headerTitle: String { "当前播放(\(rows.count))" }

        static let empty = Content(rows: [], currentRow: nil)
    }

    /// 新旧两份之间，表格该怎么动。
    enum RowsChange: Equatable {
        /// 行没增减，只是样子变了（换了当前格 / 播停）—— 刷可见行就行。
        case restyle
        /// 正好少了这一行（× 掉的）—— 带动画删掉它。
        case deleteRow(Int)
        /// 其他变化（换了一整队、插了队、洗了牌）—— 整表重来。
        case reload
    }

    let content: Observable<Content>

    /// 这一刻的 `Content` —— 动作要从里面取那一行的歌曲 id。
    var contentNow: Content { contentRelay.value }

    // MARK: - 依赖与内置状态

    private let playManager: PlayManager
    private let contentRelay = BehaviorRelay<Content>(value: .empty)
    private let disposeBag = DisposeBag()

    init(playManager: PlayManager) {
        self.playManager = playManager
        content = contentRelay.asObservable()

        // 队列 ＋「真的在出声吗」→ 行。⚠️ 两样一起合：只订队列的话，暂停时那组声波停不下来。
        Observable.combineLatest(
            playManager.queueSnapshot,
            playManager.state.map(\.isActuallyPlaying).distinctUntilChanged()
        ) { snapshot, isPlaying in
            Self.content(from: snapshot, isPlaying: isPlaying)
        }
        .distinctUntilChanged()
        .subscribe(onNext: { [weak self] content in self?.contentRelay.accept(content) })
        .disposed(by: disposeBag)
    }

    // MARK: - 动作

    /// 点了第 `row` 行（怎么算见 `PlayManager.playQueueItem`）。
    func play(row: Int) {
        guard let trackID = trackID(at: row) else { return }
        playManager.playQueueItem(at: row, trackID: trackID)
    }

    /// × 掉第 `row` 行 —— 只移出队列，不碰曲库。
    func remove(row: Int) {
        guard let trackID = trackID(at: row) else { return }
        playManager.removeQueueItem(at: row, trackID: trackID)
    }

    private func trackID(at row: Int) -> Track.ID? {
        let rows = contentRelay.value.rows
        return rows.indices.contains(row) ? rows[row].trackID : nil
    }

    // MARK: - 翻译（纯逻辑）

    static func content(from snapshot: QueueSnapshot, isPlaying: Bool) -> Content {
        let rows = snapshot.tracks.enumerated().map { index, track in
            let isCurrent = index == snapshot.currentIndex
            return Row(
                trackID: track.id,
                title: track.title,
                isCurrent: isCurrent,
                isPlaying: isCurrent && isPlaying
            )
        }
        return Content(rows: rows, currentRow: snapshot.currentIndex)
    }

    /// 从 `old` 变成 `new`，表格该怎么动 —— 只看**歌曲 id 的排列**，样子的变化不算结构变化。
    ///
    /// ⚠️ 同一首歌出现两份时（"再听一遍"），删哪一份认出来的行号可能是相邻那一份 ——
    /// 两行长得一样，删掉哪一格画面上都是同一个结果。
    static func rowsChange(from old: [Track.ID], to new: [Track.ID]) -> RowsChange {
        if old == new { return .restyle }
        guard old.count == new.count + 1,
              let row = old.indices.first(where: { $0 == new.count || old[$0] != new[$0] })
        else { return .reload }

        var trimmed = old
        trimmed.remove(at: row)
        return trimmed == new ? .deleteRow(row) : .reload
    }
}

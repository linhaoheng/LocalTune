import Foundation
import RxRelay
import RxSwift

/// 「获取歌词」页的**状态与动作** —— 页面只订阅它、把用户动作交给它。
///
/// ## 它管什么
///
/// 「拿一个词去**用户导入的源**搜歌 → 摆出候选 → 挑一条 → 取词 → 交回编辑页」
/// 这一整条链全收在这里；页面只负责画。
///
/// ## 三种收尾必须分开
///
/// 「找到 / 没找到 / 连不上」是三件事，文案由 `LyricsFetchError` 给。
///
/// ## 线程
///
/// 全在主线程；网络在 `Task` 里 `await`，回来先过 `generation` 那道闸。
@MainActor
final class LyricsFetchViewModel {

    // MARK: - 推给页面的东西

    enum Phase: Equatable {
        /// 一个源都没有 —— 先去导入。
        case noSource
        /// 正在搜。
        case searching
        /// 搜到了这些候选（已按 `LyricsCandidateRankingPolicy` 排过）。
        case results([LyricsSourceCandidate])
        /// 没搜到 / 连不上。
        case failed(LyricsFetchError)
    }

    struct Snapshot: Equatable {
        var keyword: String
        var phase: Phase
        var downloadingIndex: Int?

        var results: [LyricsSourceCandidate] {
            guard case let .results(rows) = phase else { return [] }
            return rows
        }

        var isDownloading: Bool { downloadingIndex != nil }
    }

    struct Notice: Equatable {
        let text: String
        let style: HUD.Style
    }

    let snapshot: Observable<Snapshot>
    let notice: Observable<Notice>

    // MARK: - 依赖

    private let track: Track
    private let onFetched: (String) -> Void

    /// 当前使用的源；`nil` ＝ 还没导入。
    private var source: LyricsSourceClient?

    // MARK: - 内置状态

    private let snapshotRelay: BehaviorRelay<Snapshot>
    private let noticeRelay = PublishRelay<Notice>()
    private var current: Snapshot
    private var task: Task<Void, Never>?
    private var generation = 0

    // MARK: - 建立

    init(
        track: Track,
        source: LyricsSourceClient?,
        onFetched: @escaping (String) -> Void
    ) {
        self.track = track
        self.source = source
        self.onFetched = onFetched
        current = Snapshot(
            keyword: track.title.trimmingCharacters(in: .whitespacesAndNewlines),
            phase: source == nil ? .noSource : .searching,
            downloadingIndex: nil
        )
        snapshotRelay = BehaviorRelay(value: current)
        snapshot = snapshotRelay.asObservable()
        notice = noticeRelay.asObservable()
    }

    var now: Snapshot { current }

    /// 换源（导入 / 删除之后由页面调）。
    func setSource(_ newSource: LyricsSourceClient?) {
        source = newSource
        if newSource == nil {
            finishNoSource()
        } else {
            autoSearch()
        }
    }

    // MARK: - 动作 · 搜

    func autoSearch() {
        guard source != nil else {
            finishNoSource()
            return
        }
        let keywords = LyricsSearchQueryPolicy.candidates(title: track.title, artist: track.artist)
        startSearch(keywords.first ?? "", trying: keywords)
    }

    func search(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startSearch(trimmed, trying: [trimmed])
    }

    // MARK: - 动作 · 挑一条

    func pick(at index: Int) {
        let rows = current.results
        guard rows.indices.contains(index), !current.isDownloading else { return }
        let candidate = rows[index]

        var next = current
        next.downloadingIndex = index
        commit(next)

        let token = generation
        task = Task { [weak self] in
            await self?.runDownload(candidate: candidate, token: token)
        }
    }

    // MARK: - 私有 · 搜

    private func startSearch(_ keyword: String, trying keywords: [String]) {
        task?.cancel()
        generation += 1
        let token = generation

        var next = current
        next.keyword = keyword
        next.phase = .searching
        next.downloadingIndex = nil
        commit(next)

        task = Task { [weak self] in
            await self?.runSearch(keywords, token: token)
        }
    }

    private func runSearch(_ keywords: [String], token: Int) async {
        for keyword in keywords {
            let outcome = await searchOnce(keyword)
            guard token == generation else { return }
            switch outcome {
            case let .success(rows):
                apply(rows, keyword: keyword)
                return
            case let .failure(error):
                guard error == .notFound else {
                    finish(with: error)
                    return
                }
            }
        }
        finish(with: .notFound)
    }

    private func searchOnce(_ keyword: String) async -> Result<[LyricsSourceCandidate], LyricsFetchError> {
        guard let source else { return .failure(.unreachable) }
        let query = LyricsSourceQuery(
            keyword: keyword,
            title: track.title,
            artists: [track.artist],
            album: track.album,
            durationSeconds: track.durationMs.map { $0 / 1000 } ?? 0
        )
        do {
            return .success(try await source.search(query))
        } catch let error as LyricsSourceError {
            return .failure(error == .notFound ? .notFound : .unreachable)
        } catch {
            return .failure(.unreachable)
        }
    }

    private func apply(_ rows: [LyricsSourceCandidate], keyword: String) {
        guard !rows.isEmpty else {
            finish(with: .notFound)
            return
        }
        var next = current
        next.keyword = keyword
        next.phase = .results(
            LyricsCandidateRankingPolicy.ranked(
                rows,
                title: track.title,
                artists: [track.artist],
                durationSeconds: track.durationMs.map { Double($0) / 1000 }
            )
        )
        next.downloadingIndex = nil
        commit(next)
    }

    private func finish(with error: LyricsFetchError) {
        var next = current
        next.phase = .failed(error)
        next.downloadingIndex = nil
        commit(next)
    }

    private func finishNoSource() {
        var next = current
        next.phase = .noSource
        next.downloadingIndex = nil
        commit(next)
    }

    // MARK: - 私有 · 取词

    private func runDownload(candidate: LyricsSourceCandidate, token: Int) async {
        let outcome = await fetchBody(for: candidate)
        guard token == generation else { return }

        var next = current
        next.downloadingIndex = nil
        commit(next)

        switch outcome {
        case let .success(body):
            onFetched(Self.convertedToLRC(body))
        case let .failure(error):
            noticeRelay.accept(Notice(text: error.message, style: .error))
        }
    }

    /// 取词出口**一律转 LRC**（`歌词子系统设计.md` §5.2）。
    ///
    /// 源站给的是 KRC 布局、yrc、qrc 还是 TTML 都不管：先过探测链读成模型，再从
    /// **唯一那个写口**（`LyricsTextSerializer.serializeLRC`）写出去。这样交回编辑页的
    /// 永远是同一种写法 —— "能改、能写回"对每种源都成立，编辑页也不用知道词是哪来的。
    ///
    /// 读不出来就**原样交回**：那不是"转换失败"，是"我们还不认识这种写法"——
    /// 原文至少还能给人看见，比交一份空的强（交空的会被当成「没找到」）。
    private static func convertedToLRC(_ body: String) -> String {
        guard let outcome = LyricsParser.outcome(body) else { return body }
        return LyricsTextSerializer.serializeLRC(outcome.lines)
    }

    private func fetchBody(for candidate: LyricsSourceCandidate) async -> Result<String, LyricsFetchError> {
        guard let source else { return .failure(.unreachable) }
        do {
            let text = try await source.lyrics(for: candidate)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.notFound)
            }
            return .success(text)
        } catch let error as LyricsSourceError {
            return .failure(error == .notFound ? .notFound : .unreachable)
        } catch {
            return .failure(.unreachable)
        }
    }

    // MARK: - 私有 · 收口

    private func commit(_ next: Snapshot) {
        current = next
        snapshotRelay.accept(next)
    }
}

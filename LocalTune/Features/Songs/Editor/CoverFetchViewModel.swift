import Foundation
import RxRelay
import RxSwift
import UIKit

/// 「获取封面」页的**状态与动作** —— 页面只订阅它、把用户动作交给它。
///
/// ## 它管什么
///
/// 「拿一个词去几个源搜 → 合并摆候选 → 挑一条 → 取大图 → 交回去」这一整条链全收在这里；
/// 页面只负责画。
///
/// ## 🔴 它不认识编辑页的草稿
///
/// 挑中的图是**交回去**的（`onPicked` 那条口子）；进草稿、落盘、写文件都归编辑页
/// （`获取封面设计.md` §七）。所以「挑中的封面只进草稿、点保存才落盘」这条纪律
/// **自动成立** —— 这一页连"保存"这个词都不认识。
///
/// ## 三种收尾必须分开（§六）
///
/// | 态 | 在哪儿说 | 说什么 |
/// |---|---|---|
/// | 正在搜 | 页面正中（`phase = .searching`） | 「正在搜索…」（页面自己那两个字） |
/// | 没搜到 / 连不上 | 页面正中（`phase = .failed`） | 由 `CoverSearchError.message` 给 |
/// | 取大图失败 | 浮层一句话（`notice`） | 同上，**列表原样留着** |
///
/// 🔴 「连不上」**不是**「这首没封面」的证据 —— 两种的文案必须不一样
/// （`CoverSearchError` 里写着）。
///
/// ## 线程
///
/// **全在主线程**（整个类 `@MainActor`）：状态只由页面动作改；网络那几步在 `Task` 里 `await`，
/// 回来先过 `token` 那道闸，再写状态 —— 页面订阅到的快照永远在主线程上生成。
@MainActor
final class CoverFetchViewModel {

    // MARK: - 推给页面的东西

    /// 这一刻在干什么。三态收在这一处，页面不自己拼。
    enum Phase: Equatable {
        /// 正在搜。
        ///
        /// ⚠️ **没有"还没搜"这一态** —— 进页面就自动搜一次（§五），初值直接就是它。
        case searching
        /// 搜到了这些候选。
        case results([CoverCandidate])
        /// 没搜到 / 连不上。**文案由 `CoverSearchError` 给**，这里不另立一套。
        case failed(CoverSearchError)
    }

    /// 这一刻的样子 —— 页面重画全靠这一份（`Equatable`：内容没变就不用重画）。
    struct Snapshot: Equatable {

        /// 现在拿去搜的那个词，**也是搜索框该显示的那个**。
        ///
        /// 🔴 它跟"用户刚才敲的那串"不总相等：自动搜会回落（`歌名 艺人` → 歌名），
        /// 落到哪个词上就显示哪个 —— 不藏（用户得能看出结果是怎么来的）。
        var keyword: String

        /// 这一刻在干什么。
        var phase: Phase

        /// 正在取第几条的大图（`phase.results` 里的下标）；`nil` ＝ 没在取。
        var pickingIndex: Int?

        /// 这次**没问到**的源 —— 有候选时页面在列表末尾标一句。
        var unavailableSources: [CoverSourceKind]

        /// 列表那几行（非结果态 ⇒ 空）。
        var results: [CoverCandidate] {
            guard case let .results(rows) = phase else { return [] }
            return rows
        }

        /// 有一下正在取大图 —— 这时不再接第二次点击（一次只取一张）。
        var isPicking: Bool { pickingIndex != nil }
    }

    /// 要跟用户说的一句话（取大图那一步的收尾）。
    struct Notice: Equatable {
        let text: String
        let style: HUD.Style
    }

    /// 状态流。**每次改动推一份**。
    let snapshot: Observable<Snapshot>

    /// 一次性提示（取大图失败）。
    let notice: Observable<Notice>

    // MARK: - 依赖

    /// 本地这一首 —— 预填搜索词用。
    private let track: Track

    /// 封面这一摊的入口（并发问几个源 ＋ 取字节）。
    private let coordinator: CoverSearchCoordinator

    /// 拿到挑中的那张图之后往哪儿交 —— **由装配层给**（这一层不认识编辑页）。
    private let onPicked: (UIImage) -> Void

    // MARK: - 内置状态

    private let snapshotRelay: BehaviorRelay<Snapshot>
    private let noticeRelay = PublishRelay<Notice>()

    /// 现在的样子。**只由本页改**。
    private var current: Snapshot

    /// 正在跑的那一趟（搜索 / 取大图共用一处）。开新的一趟先取消旧的。
    private var task: Task<Void, Never>?

    /// 趟次号 —— 每开一趟 ＋1。`await` 回来先比对它，过期的一趟一个字都不许写。
    private var generation = 0

    /// 正在下的缩略图（URL → 那一趟）。
    ///
    /// ⚠️ **必须去重**：表格滚动时同一行会被反复要求出图，
    /// 不去重就会对着同一个 URL 起好几趟下载（每一趟都真的发请求）。
    private var thumbnailTasks: [URL: Task<UIImage?, Never>] = [:]

    // MARK: - 建立

    /// - Parameters:
    ///   - track: 要配封面的那首（预填搜索词）。
    ///   - coordinator: 封面这一摊的入口。
    ///   - onPicked: 挑中的那张图往哪儿交。
    init(
        track: Track,
        coordinator: CoverSearchCoordinator,
        onPicked: @escaping (UIImage) -> Void
    ) {
        self.track = track
        self.coordinator = coordinator
        self.onPicked = onPicked
        current = Snapshot(
            keyword: track.title.trimmingCharacters(in: .whitespacesAndNewlines),
            phase: .searching,
            pickingIndex: nil,
            unavailableSources: []
        )
        snapshotRelay = BehaviorRelay(value: current)
        snapshot = snapshotRelay.asObservable()
        notice = noticeRelay.asObservable()
    }

    /// 这一刻的样子（页面建控件时用一次）。
    var now: Snapshot { current }

    // MARK: - 动作 · 搜

    /// 进页面时自动搜一次 —— 按回落顺序（`歌名 艺人` → 歌名）逐个试。
    func autoSearch() {
        let keywords = CoverSearchQueryPolicy.candidates(title: track.title, artist: track.artist)
        startSearch(keywords.first ?? "", trying: keywords)
    }

    /// 用户按下搜索键 —— 就用他这一串。
    ///
    /// 🔴 **不回落**：回落是"自动搜"用来猜词的，不是他手打的意思。
    func search(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startSearch(trimmed, trying: [trimmed])
    }

    // MARK: - 动作 · 挑一条

    /// 挑了第 `index` 条 —— 取它的大图，交回去。
    ///
    /// ⚠️ 取的是**大图**（酷狗 480 档 / QQ 800×800），不是列表里那张缩略图（§五）。
    func pick(at index: Int) {
        let rows = current.results
        guard rows.indices.contains(index), !current.isPicking else { return }
        let candidate = rows[index]

        var next = current
        next.pickingIndex = index
        commit(next)

        let token = generation
        task = Task { [weak self] in
            await self?.runPick(candidate: candidate, token: token)
        }
    }

    // MARK: - 缩略图

    /// 列表里那一小格的图。
    ///
    /// ⚠️ **取不到就返回 `nil`，不报错、不弹提示** —— 图是缓存，
    /// 这一格画占位底即可，不配打断用户。
    func thumbnail(for candidate: CoverCandidate) async -> UIImage? {
        let url = candidate.thumbnailURL
        if let cached = CoverImageLoader.cached(for: url) { return cached }
        // 已经有一趟在下了就搭它的车（见 `thumbnailTasks` 那段）。
        if let running = thumbnailTasks[url] { return await running.value }

        let coordinator = self.coordinator
        let task = Task { () -> UIImage? in
            guard let data = try? await coordinator.thumbnailData(for: candidate) else { return nil }
            return CoverImageLoader.store(data, for: url)
        }
        thumbnailTasks[url] = task
        let image = await task.value
        thumbnailTasks[url] = nil
        return image
    }

    // MARK: - 私有 · 搜

    /// 起一趟搜索：先把界面切到"正在搜"，再让候选词逐个试过去。
    ///
    /// 🔴 **开新的一趟先把旧那趟取消**：用户改一个词连按两次搜索，旧那趟的结果回来时
    /// 已经过期 —— 取消它、并且 `generation` 也拦住它（两道，见 `runSearch`）。
    private func startSearch(_ keyword: String, trying keywords: [String]) {
        task?.cancel()
        generation += 1
        let token = generation

        var next = current
        next.keyword = keyword
        next.phase = .searching
        next.pickingIndex = nil
        next.unavailableSources = []
        commit(next)

        task = Task { [weak self] in
            await self?.runSearch(keywords, token: token)
        }
    }

    /// 候选词逐个试：有结果就收工；「这首没有」就换下一个词；「连不上」直接收工。
    ///
    /// 🔴 **每个 `await` 回来先看一眼 `token`**（宪法 §三·动作与状态 7）——
    /// 取消网络请求也是让 `await` 抛错回来，不先查过期，就会把**新那一趟**的
    /// "正在搜"盖成"连不上"（那是拿旧结果打新状态，正是那条禁的）。
    private func runSearch(_ keywords: [String], token: Int) async {
        for keyword in keywords {
            let outcome = await coordinator.search(keyword)
            guard token == generation else { return }
            switch outcome {
            case let .success(result):
                apply(result, keyword: keyword)
                return
            case let .failure(error):
                // 「没搜到」⇒ 换下一个词；其余（连不上）⇒ 到此为止（§六：两件事不能混）。
                guard error == .notFound else {
                    finish(with: error)
                    return
                }
            }
        }
        // 每个词都问过、都答"没有" ⇒ 就是没找到。
        finish(with: .notFound)
    }

    /// 搜到了：进列表。
    private func apply(_ result: CoverSearchCoordinator.Outcome, keyword: String) {
        // 协调器"一条都没有"时会给 `.failure`，这里再挡一次是防御：真收到空数组，
        // 界面就是"一片空白、什么都不说"——那正是「不许沉默」禁的。
        guard !result.candidates.isEmpty else {
            finish(with: .notFound)
            return
        }
        var next = current
        next.keyword = keyword
        next.phase = .results(result.candidates)
        next.pickingIndex = nil
        next.unavailableSources = result.unavailableSources
        commit(next)
    }

    /// 没搜到 / 连不上 —— 页面正中那句话的**出处**就是它带来的这个值。
    private func finish(with error: CoverSearchError) {
        var next = current
        next.phase = .failed(error)
        next.pickingIndex = nil
        next.unavailableSources = []
        commit(next)
    }

    // MARK: - 私有 · 取大图

    /// 取这一条的大图，然后交回去。
    private func runPick(candidate: CoverCandidate, token: Int) async {
        let outcome = await coverImage(for: candidate)
        guard token == generation else { return }

        var next = current
        next.pickingIndex = nil
        commit(next)

        switch outcome {
        case let .success(image):
            onPicked(image)
        case let .failure(error):
            // 列表原样留着，只报这一次动作的结果 —— 失败也要给一句人话（不许沉默）。
            noticeRelay.accept(Notice(text: error.message, style: .error))
        }
    }

    /// 大图字节 → `UIImage`（先查缓存 —— 同一张反复挑不必重下）。
    private func coverImage(for candidate: CoverCandidate) async -> Result<UIImage, CoverSearchError> {
        let url = candidate.coverURL
        if let cached = CoverImageLoader.cached(for: url) { return .success(cached) }
        do {
            let data = try await coordinator.coverData(for: candidate)
            // 解不出图 ⇒ 响应不成形 ⇒ 算「连不上」（**不是**"这首没封面"）。
            guard let image = CoverImageLoader.store(data, for: url) else {
                return .failure(.unreachable)
            }
            return .success(image)
        } catch let error as CoverSearchError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    // MARK: - 私有 · 收口

    /// 算出下一份并推出去。
    private func commit(_ next: Snapshot) {
        current = next
        snapshotRelay.accept(next)
    }
}

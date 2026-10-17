import Foundation
import RxRelay
import RxSwift

/// 「获取歌词」页的**状态与动作** —— 页面只订阅它、把用户动作交给它。
///
/// ## 它管什么
///
/// 「拿一个词去酷狗搜**歌** → 摆出候选 → 挑一条 → 用它的 `hash` 搜**词** →
/// 下 KRC → 解密 → 转成我们的正文形态」这一整条链全收在这里；页面只负责画。
///
/// ## 🔴 它不认识的东西
///
/// - **不碰编辑页的草稿**：转好的正文是**交回去**的（`onFetched` 那条口子）；
///   灌进工作层、保存都归编辑歌词页。
/// - **不落库、不写文件、不缓存**：每次现搜现下，库里一个字都不动。
///
/// ## 三种收尾必须分开
///
/// 「找到 / 没找到 / 连不上」是三件事，处理也不同：
///
/// | 态 | 在哪儿说 | 说什么 |
/// |---|---|---|
/// | 没找到 / 连不上（**搜**那一步） | 页面正中（`phase = .failed`） | 由 `LyricsFetchError.message` 给 |
/// | 没找到 / 连不上（**下**那一步） | 浮层一句话（`notice`） | 同上，**列表原样留着** |
///
/// 🔴 「连不上」**不是**「这首歌没词」的证据 —— 两种的文案必须不一样（`LyricsFetchError` 里写着）。
///
/// ## 线程
///
/// **全在主线程**（整个类 `@MainActor`）：状态只由页面动作改；网络那两步在 `Task` 里 `await`，
/// 回来先过 `token` 那道闸，再写状态 —— 页面订阅到的快照永远在主线程上生成。
@MainActor
final class LyricsFetchViewModel {

    // MARK: - 推给页面的东西

    /// 这一刻在干什么。三态收在这一处，页面不自己拼。
    enum Phase: Equatable {
        /// 正在搜。
        ///
        /// ⚠️ **没有"还没搜"这一态** —— 进页面就自动搜一次，
        /// 初值直接就是它。
        case searching
        /// 搜到了这些候选（已按 `LyricsCandidateRankingPolicy` 排过）。
        case results([LyricsSearchResult])
        /// 没搜到 / 连不上。**文案由 `LyricsFetchError` 给**，这里不另立一套。
        case failed(LyricsFetchError)
    }

    /// 这一刻的样子 —— 页面重画全靠这一份（`Equatable`：内容没变就不用重画）。
    struct Snapshot: Equatable {

        /// 现在拿去搜的那个词，**也是输入框该显示的那个**。
        ///
        /// 🔴 它跟"用户刚才敲的那串"不总相等：自动搜会回落（`歌名 艺人` → 歌名 → 歌名主干），
        /// 落到哪个词上就显示哪个 —— 不藏（用户得能看出结果是怎么来的）。
        var keyword: String

        /// 这一刻在干什么。
        var phase: Phase

        /// 正在下第几条（`phase.results` 里的下标）；`nil` ＝ 没在下。
        var downloadingIndex: Int?

        /// 列表那几行（非结果态 ⇒ 空）。
        var results: [LyricsSearchResult] {
            guard case let .results(rows) = phase else { return [] }
            return rows
        }

        /// 有一下正在下 —— 这时不再接第二次点击。
        var isDownloading: Bool { downloadingIndex != nil }
    }

    /// 要跟用户说的一句话（下载那一步的收尾）。
    struct Notice: Equatable {
        let text: String
        let style: HUD.Style
    }

    /// 状态流。**每次改动推一份**。
    let snapshot: Observable<Snapshot>

    /// 一次性提示（点了下不动、下失败）。
    let notice: Observable<Notice>

    // MARK: - 依赖

    /// 本地这一首 —— 预填词、给候选排序都用它。
    private let track: Track

    /// 取词客户端（搜 ＋ 下）。
    private let client: LyricsSearchClient

    /// 拿到转换好的正文之后往哪儿交 —— **由装配层给**（这一层不认识编辑页）。
    private let onFetched: (String) -> Void

    // MARK: - 内置状态

    private let snapshotRelay: BehaviorRelay<Snapshot>
    private let noticeRelay = PublishRelay<Notice>()

    /// 现在的样子。**只由本页改**。
    private var current: Snapshot

    /// 正在跑的那一趟（搜索 / 下载共用一处）。开新的一趟先取消旧的。
    private var task: Task<Void, Never>?

    /// 趟次号 —— 每开一趟 ＋1。`await` 回来先比对它，过期的一趟一个字都不许写。
    private var generation = 0

    // MARK: - 建立

    /// - Parameters:
    ///   - track: 要取词的那首（预填歌名、给候选排序）。
    ///   - client: 取词客户端。
    ///   - onFetched: 取回并转换好的正文往哪儿交。
    init(track: Track, client: LyricsSearchClient, onFetched: @escaping (String) -> Void) {
        self.track = track
        self.client = client
        self.onFetched = onFetched
        current = Snapshot(
            keyword: track.title.trimmingCharacters(in: .whitespacesAndNewlines),
            phase: .searching,
            downloadingIndex: nil
        )
        snapshotRelay = BehaviorRelay(value: current)
        snapshot = snapshotRelay.asObservable()
        notice = noticeRelay.asObservable()
    }

    /// 这一刻的样子（页面建控件时用一次）。
    var now: Snapshot { current }

    // MARK: - 动作 · 搜

    /// 进页面时自动搜一次 —— 按回落顺序（`歌名 艺人` → 歌名 → 歌名主干）逐个试。
    func autoSearch() {
        let keywords = LyricsSearchQueryPolicy.candidates(title: track.title, artist: track.artist)
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

    /// 挑了第 `index` 条 —— 用它的 `hash` 搜词、下 KRC、解密、转成我们的正文、交回去。
    func pick(at index: Int) {
        let rows = current.results
        guard rows.indices.contains(index), !current.isDownloading else { return }
        let candidate = rows[index]
        guard candidate.isDownloadable else {
            // 这一条取不到 `hash` ⇒ 下不了（列表里它是灰的）。**不许沉默**：
            // 点了没反应得说一句为什么，不然用户只会以为"这个 App 坏了"。
            noticeRelay.accept(Notice(text: "这一条取不到取词键，换一条再试", style: .info))
            return
        }
        var next = current
        next.downloadingIndex = index
        commit(next)

        let token = generation
        task = Task { [weak self] in
            await self?.runDownload(candidate: candidate, token: token)
        }
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
        next.downloadingIndex = nil
        commit(next)

        task = Task { [weak self] in
            await self?.runSearch(keywords, token: token)
        }
    }

    /// 候选词逐个试：有结果就收工；「这首歌没有」就换下一个词；「连不上」直接收工。
    ///
    /// 🔴 **每个 `await` 回来先看一眼 `token`**——
    /// 取消网络请求也是让 `await` 抛错回来，不先查过期，就会把**新那一趟**的
    /// "正在搜"盖成"连不上"（那是拿旧结果打新状态，正是那条禁的）。
    private func runSearch(_ keywords: [String], token: Int) async {
        for keyword in keywords {
            let outcome = await searchOnce(keyword)
            guard token == generation else { return }
            switch outcome {
            case let .success(rows):
                apply(rows, keyword: keyword)
                return
            case let .failure(error):
                // 「没找到」⇒ 换下一个词；其余（连不上）⇒ 到此为止（两件事不能混）。
                guard error == .notFound else {
                    finish(with: error)
                    return
                }
            }
        }
        // 每个词都问过、都答"没有" ⇒ 就是没找到。
        finish(with: .notFound)
    }

    /// 搜一次，把两种收尾收成一个值。
    ///
    /// ⚠️ 网络层抛出来的**别的**错（超时 / 取消 / 证书）一律算「连不上」——
    /// 对用户来说它们是同一件事，**但绝不能算成"没找到"**。
    private func searchOnce(_ keyword: String) async -> Result<[LyricsSearchResult], LyricsFetchError> {
        do {
            return .success(try await client.searchSongs(keyword))
        } catch let error as LyricsFetchError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    /// 搜到了：排完序进列表。
    ///
    /// 🔴 排序**只排不筛**：不像的候选也照摆，用户自己认版本。
    private func apply(_ rows: [LyricsSearchResult], keyword: String) {
        // 客户端"一条都没有"时会抛 `.notFound`，这里再挡一次是防御：真收到空数组，
        // 界面就是"一片空白、什么都不说"——那正是「不许沉默」禁的。
        guard !rows.isEmpty else {
            finish(with: .notFound)
            return
        }
        var next = current
        next.keyword = keyword
        // ⚠️ 艺人只传本地这一串：`Track.artist` 是**一个**字段（合唱时几个艺人写在
        // 同一串里），而相似度那边"一方含另一方"给 0.9 ⇒ 这样比已经够用，
        // 不为此再立一套"拆艺人"的规则。
        // 🔴 时长这一维：本机时长**可空** ⇒ 没有就传 `nil`，那一维自然"不参与"
        //（`durationScore` 会给所有人同一个中性分，等于不影响顺序）。
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

    /// 没搜到 / 连不上 —— 页面正中那句话的**出处**就是它带来的这个值。
    private func finish(with error: LyricsFetchError) {
        var next = current
        next.phase = .failed(error)
        next.downloadingIndex = nil
        commit(next)
    }

    // MARK: - 私有 · 取词（搜词 → 下载 → 解密 → 换算）

    /// 取这一条候选的词并转换，然后交回去。
    private func runDownload(candidate: LyricsSearchResult, token: Int) async {
        let outcome = await fetchBody(for: candidate)
        guard token == generation else { return }

        var next = current
        next.downloadingIndex = nil
        commit(next)

        switch outcome {
        case let .success(body):
            onFetched(body)
        case let .failure(error):
            // 列表原样留着，只报这一次动作的结果 —— 失败也要给一句人话（不许沉默）。
            noticeRelay.accept(Notice(text: error.message, style: .error))
        }
    }

    /// 🔴 「用 `hash` 搜词 → 取首条 → 下载 → 解密 → 换算」这四步。
    ///
    /// - **取首条、不再摆第二层列表**：`hash` 已经把范围锁在"这一版"上（实测首条就是原唱），
    ///   再摆一层只是多一步点击。
    /// - **歌名 ＋ 艺人取候选自己那份**：信息行判据要拿它去认"标题行 / 艺人署名行"，
    ///   候选的 `songname` / `singername` 比本地标签更贴这一版。
    /// - ⚠️ 转完**一个字符都不剩**（比如下到的是一份只有头部行的档）⇒ 算「这首歌没有」：
    ///   交一份空的回去，等于把用户歌词清空，那比报错更糟。
    private func fetchBody(for candidate: LyricsSearchResult) async -> Result<String, LyricsFetchError> {
        do {
            let lyricCandidates = try await client.searchLyricCandidates(
                keyword: candidate.title,
                hash: candidate.hash,
                durationMilliseconds: candidate.durationMs
            )
            guard let lyric = lyricCandidates.first else { return .failure(.notFound) }

            let encrypted = try await client.downloadEncrypted(id: lyric.id, accessKey: lyric.accessKey)
            // 解不出明文 ⇒ 响应不成形 ⇒ 算「连不上」（**不是**"这首歌没词"）。
            guard let plain = LyricsKRCDecrypter.decrypt(encrypted) else { return .failure(.unreachable) }

            let body = LyricsExternalFormatPolicy.body(
                fromKRC: plain, title: candidate.title, artists: candidate.artists
            )
            return body.isEmpty ? .failure(.notFound) : .success(body)
        } catch let error as LyricsFetchError {
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

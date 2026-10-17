import Foundation
import RxRelay
import RxSwift

/// 搜索框 → **命中的那些歌**：把连打收敛成一次、算在别的线程上、**词与命中成对**交出去。
///
/// ## 它不干什么
///
/// 🔴 **命中规则不在这儿** —— 只有 `LibraryStore.matchingTrackIDs` 一处知道。
/// 这个类型只做三件事：防抖、换线程、成对交付。三个页面（曲库 / 歌单详情 / 加歌）共用它，
/// 谁也不许再各写一套"内存里比几个字段"。
///
/// ## 为什么"成对"是硬要求
///
/// `Result` 里躺着的是**算出这一份用的那个词**和**这个词的命中**。若让"在不在搜"跟着
/// 输入框的原始字符走、而命中跟着防抖走，就会出现**框里写着「周杰」、列表按「周」筛**
/// （或者刚敲第一个字就被当成"搜了个空"、列表先空一下）——那是界面在撒谎，不是延迟。
/// ⇒ 一个值、一次推，界面拿到的每一份都自洽。
///
/// ## 线程
///
/// - **进来**：`accept` 在主线程上被调（搜索框的回调）。
/// - **算**：`matchingTrackIDs` 在 `scanScheduler` 上跑 —— `LibraryStore` 顶上写着
///   "同步查询方法谁调谁阻塞"，所以**不许在主线程上调它**。那条队列是**串行**的
///   （理由见属性上的注释：`flatMapLatest` 只丢结果、不取消活儿）。
/// - **出去**：`result` 在 `MainScheduler` 上推（订阅方是页面）。
/// - **状态**：只有 `resultRelay` 一个，只在主线程写；`scanScheduler` 上那一段不碰它。
final class LibrarySearch {

    /// 一份**自洽**的搜索态 —— 词 ＋ 它的命中。
    struct Result: Equatable {

        /// 算出这一份用的那个词。
        let query: String

        /// 这个词命中的歌；空词就是空集。
        let hitIDs: Set<Track.ID>

        /// 现在算不算"在搜"：**去空白之后还有没有东西**。
        ///
        /// ⚠️ 判据不是"搜索框里有没有字符"——敲了一串空格不算在搜。
        ///
        /// 🔴 **规则不写在这儿**，走 `LibraryStore.normalizedSearchQuery`：库那边判"空词不碰库"
        /// 用的是同一条。各写一遍（`trimmingCharacters(…)` 抄两处）的话，改一处忘一处就会出现
        /// **界面说"没在搜"、库却给了命中** —— 两边看着都对，谁也发现不了。
        var isSearching: Bool {
            !LibraryStore.normalizedSearchQuery(query).isEmpty
        }

        /// 把这一列里命中的挑出来（**顺序照旧** —— 排序是紧接着别人的事，这里不重排）。
        func matching(_ tracks: [Track]) -> [Track] {
            tracks.filter { hitIDs.contains($0.id) }
        }

        /// 没在搜的那一份（首屏、清空之后）。
        static let idle = Result(query: "", hitIDs: [])
    }

    /// 搜索这件事自己的参数 —— 不是版式数字，所以**不进 `AppMetrics`**。
    enum Policy {

        /// **非空词**连打收敛多久。照 primuse 的搜索防抖（`AppleMusicCatalogSearchPolicy.debounce`）。
        ///
        /// ⚠️ **只管"还在打字"** —— 清空搜索框**不走它**（见 `init` 里 `cleared` 那一路）：
        /// 点小叉、一下删空是"我不搜了"这个**已经说清的意图**，没有"停手"可等。
        /// 把清空也塞进防抖窗，等于用户说完之后界面还愣 250ms 才回到完整列表。
        static let debounce: RxTimeInterval = .milliseconds(250)
    }

    /// 界面的**唯一出口** —— 订它。
    ///
    /// ⚠️ 订阅当下就有值（`.idle`）：防抖那 250ms 里界面拿到的就是这一份。**必须如此** ——
    /// 让防抖窗口吊着首帧，首屏就是空列表（跟 `LibraryStore` 那条"首次回调是异步的"同一个坑）。
    var result: Observable<Result> { resultRelay.asObservable() }

    private let resultRelay = BehaviorRelay(value: Result.idle)

    /// 输入框的原始字符 —— 每敲一下进一格，防抖在**下游**做。
    private let queryRelay = BehaviorRelay(value: "")

    private let disposeBag = DisposeBag()

    /// 算在库那一边 —— 一条**串行**队列，不借主线程（同 `SongsViewModel.prefetchArtwork`
    /// 那条"读盘放到 `DispatchQueue.global`"：一句读库的活儿，不必从装配层借调度器）。
    ///
    /// 🔴 **必须串行，不能并发**：`flatMapLatest` 只保证"旧结果不投递"，**不保证"旧活儿不干"** ——
    /// RxSwift 不会去取消已经在跑的那个闭包。用并发队列的话，用户在防抖窗外连着改两次词，
    /// 两次全表扫**同时压同一个库**（结果新版覆盖旧版，活儿却叠着）。串行队列让重活排队，不叠加。
    private let scanScheduler = SerialDispatchQueueScheduler(
        qos: .userInitiated,
        internalSerialQueueName: "com.localmusic.search.scan"
    )

    init(library: LibraryStore) {
        // 先归一化、再分两路 —— 「什么算空词」只有 `LibraryStore.normalizedSearchQuery` 那一处。
        let normalized = queryRelay
            .map(LibraryStore.normalizedSearchQuery)
            // 归一化之后没变就不往下走（敲下空格、删掉空格 = 还是同一个词）。
            .distinctUntilChanged()

        // 🔴 **清空：不进防抖窗**。它不是一次"输入"，是"我不搜了"这个已经说清的意图 ——
        // 没有"停手"可等。等 250ms 才回到完整列表，就是让界面在用户说完之后还愣一下。
        let cleared = normalized
            .filter { $0.isEmpty }
            .map { _ in Result.idle }

        // 归一化后的词**都**进防抖窗，出来之后才丢掉空词。
        //
        // ⚠️ 空词也必须进来，就为了让"清空"能把**待发的上一个词顶掉**：`debounce` 等的是
        // "这段时间里没有新输入"，要是把空词挡在窗外，那「周」在 250ms 到点后照样会发出来 ——
        // 界面就卡在搜索结果上、搜索框却已经空了（**撒谎**）。空词发出来后在这里被丢掉，
        // 它自己不算一次搜索（`cleared` 那一路已经把 `.idle` 送出去了）。
        //
        // 只认最新那一次：防抖窗里连打，中间那些结果回来得比后一次晚，**必须丢**
        // `flatMapLatest` 新的词一到就退订上一份订阅。
        let typed = normalized
            .debounce(Policy.debounce, scheduler: MainScheduler.instance)
            .filter { !$0.isEmpty }
            .flatMapLatest { [scanScheduler] query in
                Self.scan(query, library: library, on: scanScheduler)
            }
            // 算在别的线程上，交回主线程（订阅方是页面）。
            .observe(on: MainScheduler.instance)

        // 两路合成一条出口。清空那一份是**同步**发出去的（就在 `accept` 的同一次调用栈里），
        // 所以它到界面的延迟是"下一帧"，不是"下一个防抖窗"。
        Observable.merge(cleared, typed)
            // 内容没变就不推 —— 否则首屏 250ms 后那份"空词 + 空命中"会把整张列表白重算一遍。
            .distinctUntilChanged()
            .subscribe(onNext: { [weak self] in self?.resultRelay.accept($0) })
            .disposed(by: disposeBag)
    }

    /// 搜索框里的字变了 —— 每敲一下都调，防抖在里头。
    func accept(_ text: String) {
        queryRelay.accept(text)
    }

    /// 算一份：**读库那一句在 `scheduler` 上跑**，算完贴着它自己那个词一起交回去。
    ///
    /// ⚠️ 用 `deferred` 而不是先算好再包：要的就是"订阅发生的那一刻才去读"——
    /// 这样 `subscribe(on:)` 换的就是**读这一句**所在的线程。
    private static func scan(
        _ query: String,
        library: LibraryStore,
        on scheduler: SchedulerType
    ) -> Observable<Result> {
        Observable.deferred {
            Observable.just(Result(query: query, hitIDs: library.matchingTrackIDs(for: query)))
        }
        .subscribe(on: scheduler)
    }
}

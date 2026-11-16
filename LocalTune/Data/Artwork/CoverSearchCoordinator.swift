import Foundation

/// 把几个封面源**合成一件事** —— 并发问 → 合并 → 去重 → 归一收尾。
///
/// ## 它管什么
///
/// | 事 | 怎么管 |
/// |---|---|
/// | 并发 | 一次搜索**同时**问所有源，等齐再出结果（不是串行等两次超时） |
/// | 合并 | 所有源的候选进同一张列表，**按源的装配顺序**排（酷狗在前） |
/// | 去重 | 按 `CoverCandidate.id`（源 ＋ 缩略图地址，即**同一张图**）—— **跨源不合并** |
/// | 归一 | 三个收尾收成两个：有候选 ⇒ 摆；都没搜到 ⇒ `.notFound`；**有源没问到** ⇒ `.unreachable` |
///
/// ## 🔴 「一个源挂了」不许拖垮整页
///
/// 两个源都是非官方接口（`获取封面设计.md` §九 第 1 条）—— 一个挂了，另一个照常出结果，
/// 只是把挂掉那个记进 `unavailableSources`，页面据此标一句。
///
/// ## 🔴 「都没搜到」与「有源没问到」是两件事
///
/// 两个源都真答"没有"才算「没搜到」；只要**有一个**源是"连不上"，
/// 就不能断言"这首没封面"（它可能只是没问到）⇒ 收尾归 `.unreachable`。
///
/// ## 顺序是**定**的
///
/// 并发完成顺序不确定，所以合并时按 `sources` 的装配顺序拼 ——
/// 不然同一首歌搜两次，列表顺序会跳。
///
/// ## 它不认识的东西
///
/// 不认识界面、不认识编辑页的草稿、不缓存（缓存是 `Core/UI/CoverImageLoader` 的事）——
/// 它只把"问几个源"这件事收成一次调用。
///
/// ## 线程
///
/// 无状态（只持几个源），`Sendable`，随便哪个线程调。
final class CoverSearchCoordinator: Sendable {

    /// 一次搜索的结果。
    struct Outcome: Sendable {

        /// 合并去重之后的候选（按源的装配顺序）。
        var candidates: [CoverCandidate]

        /// 这次**没问到**的源（连不上）—— 有候选时页面据此标一句。
        var unavailableSources: [CoverSourceKind]
    }

    private let sources: [any CoverSource]

    /// - Parameter sources: 装配顺序即列表顺序 —— 第一个源（酷狗）的候选排在最前。
    init(sources: [any CoverSource]) {
        self.sources = sources
    }

    // MARK: - 搜

    /// 一次搜到底：并发问所有源 → 合并 → 去重 → 归一。
    ///
    /// - Returns: `.success` **一定有候选**；`.failure` 是「都没搜到」或「有源没问到」。
    func search(_ keyword: String) async -> Result<Outcome, CoverSearchError> {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.notFound) }

        // 源数量可变（不是写死两个），所以用 `TaskGroup` 而不是 `async let`。
        //
        // ⚠️ 收集用的数组**声明在闭包里面**、靠返回值带出来：声明在外面再 `append`，
        // 等于让 `@Sendable` 闭包去改外面的可变变量 —— 并发检查会拦，也确实是错的写法。
        typealias Entry = (kind: CoverSourceKind, result: Result<[CoverCandidate], CoverSearchError>)
        let collected: [Entry] = await withTaskGroup(of: Entry.self) { group in
            for source in sources {
                group.addTask {
                    do {
                        return (source.kind, .success(try await source.search(trimmed)))
                    } catch let error as CoverSearchError {
                        return (source.kind, .failure(error))
                    } catch {
                        // ⚠️ 网络层抛出来的**别的**错（超时 / 取消 / 证书）一律算「连不上」——
                        // 对用户是同一件事，**但绝不能算成"没搜到"**。
                        return (source.kind, .failure(.unreachable))
                    }
                }
            }
            var entries: [Entry] = []
            for await item in group { entries.append(item) }
            return entries
        }

        // 先按源归堆，再按**装配顺序**拼 —— 见类 doc「顺序是定的」。
        var bySource: [CoverSourceKind: [CoverCandidate]] = [:]
        var unavailable = Set<CoverSourceKind>()
        for entry in collected {
            switch entry.result {
            case let .success(rows):
                // 🔴 同源内去重（源自己也会返回重复条目）—— 跨源**不合并**，
                // 理由写在 `CoverCandidate.id` 上。
                var deduped: [CoverCandidate] = []
                var seen = Set<String>()
                for row in rows where seen.insert(row.id).inserted { deduped.append(row) }
                bySource[entry.kind] = deduped
            case let .failure(error):
                // 「没搜到」不算没问到 —— 只有 `.unreachable` 才记一笔。
                if error == .unreachable { unavailable.insert(entry.kind) }
            }
        }

        var merged: [CoverCandidate] = []
        for source in sources { merged.append(contentsOf: bySource[source.kind] ?? []) }

        guard !merged.isEmpty else {
            // 🔴 只要**有一个源没问到**，就不能说"这首没封面"（§六）。
            return .failure(unavailable.isEmpty ? .notFound : .unreachable)
        }
        let ordered = sources.map(\.kind).filter { unavailable.contains($0) }
        return .success(Outcome(candidates: merged, unavailableSources: ordered))
    }

    // MARK: - 取图

    /// 取列表里那一小格的字节。
    func thumbnailData(for candidate: CoverCandidate) async throws -> Data {
        guard let source = source(for: candidate.source) else {
            // 走不到：候选只可能来自 `sources` 里的某个源。
            throw CoverSearchError.unreachable
        }
        return try await source.imageData(from: candidate.thumbnailURL)
    }

    /// 取挑中之后要的那张大图。
    func coverData(for candidate: CoverCandidate) async throws -> Data {
        guard let source = source(for: candidate.source) else {
            throw CoverSearchError.unreachable
        }
        return try await source.imageData(from: candidate.coverURL)
    }

    /// 这条候选是哪个源搜出来的。
    private func source(for kind: CoverSourceKind) -> (any CoverSource)? {
        sources.first { $0.kind == kind }
    }
}

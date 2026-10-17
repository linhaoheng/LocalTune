import Foundation

/// 会话写盘口：enqueue 最新一代，再同步 drain。落盘时机由装配层决定（disconnect / terminate）。
final class PlaybackSessionPersistenceCoordinator {
    private struct Pending {
        let generation: UInt64
        let request: PlaybackSessionPersistenceRequest
    }

    private let store: PlaybackSessionStore
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.localmusic.playback.session", qos: .utility)

    private var pending: Pending?
    private var acceptedGeneration: UInt64 = 0
    private var lastSuccessfulGeneration: UInt64?

    init(store: PlaybackSessionStore = PlaybackSessionStore()) {
        self.store = store
    }

    var url: URL { store.url }

    func load() -> PlaybackSessionSnapshot? { store.load() }

    /// O(1)，不碰磁盘。
    func enqueue(_ request: PlaybackSessionPersistenceRequest, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation >= acceptedGeneration else { return }
        acceptedGeneration = generation
        pending = Pending(generation: generation, request: request)
    }

    /// 同步尽量落盘。只由 disconnect / terminate 这两个「进程要没了」的时机调 ——
    /// 那时必须等写完再走，所以这里没有、也不需要「后台 drain」那条路。
    func drainSynchronously() {
        writeQueue.sync { drain() }
    }

    private func drain() {
        while let next = takePending() {
            apply(next)
        }
    }

    /// 落一项待写。写失败就吞掉 —— 理由见下面 `catch`。
    private func apply(_ next: Pending) {
        do {
            switch next.request {
            case .save(let snapshot):
                try store.save(snapshot)
            case .clear:
                try store.clear()
            }
            recordSuccess(generation: next.generation)
        } catch {
            // 敢吞：这是「进后台 / 终止时**尽力而为**的快照落盘」—— 写失败＝这次没记住
            // 「上次听到哪」，下次从空开始；不打断任何东西，也不该重试。
            // 推进 lastSuccessfulGeneration 那步在 `do` 块里、抛错就跳过，所以失败的这一代
            // 不会被当成「写过了」。
        }
    }

    /// 记下「这一代写成了」。只在 `apply` 的成功路径上调。
    private func recordSuccess(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if generation > (lastSuccessfulGeneration ?? 0) {
            lastSuccessfulGeneration = generation
        }
    }

    private func takePending() -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        let next = pending
        pending = nil
        return next
    }
}

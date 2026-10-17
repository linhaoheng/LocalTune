import AppIntents
import Foundation

/// Intent / 快捷指令 ↔ 主 App 服务的注入桥。
///
/// 系统 Intent 入口（`handlerFor` / `AppIntent.perform`）**没有** `AppServices` 的 init 缝，
/// 所以桥由 **App 的进程入口（`AppDelegate`）** 建一次并持有，再由它交给系统入口：
/// Siri 那条路走**构造注入**（`PlayMediaIntentHandler(bridge:)`），快捷指令那条路走**框架
/// 自己的依赖注入**（`AppDelegate` 里 `AppDependencyManager` 登记 → `AppIntent` /
/// `EntityQuery` 用 `@Dependency` 取）。**它不挂 `.shared`，也不是任何"全局取用点"。**
///
/// `perform` / 查询只调闭包；未装配 → 明确失败。桥 **不持**引擎、**不写**锁屏。
///
/// ## 线程
///
/// **不**标 `@MainActor`：装配层 `AppServices` 也不是 MainActor 类型，只约定主线程创建
/// （见 `AppServices` 文件头）。桥跟它同边界 —— 闭包由 `AppServices.init` 写入、由
/// Intent 入口（已在主线程 / `@MainActor` Task）调用；闭包里碰的是同线程的
/// `PlayManager` / `LibraryStore` 快照口。
///
/// 只有「装配完成没有」这一件事会**跨线程**被读（超时那一侧在别的线程上叫醒等待者），
/// 所以它单独用一把锁保护（见下）；本类据此声明 `@unchecked Sendable`。
final class LocalTuneIntentBridge: @unchecked Sendable {

    /// 冷启动有界等待（秒）。我们 `LibraryStore` 同步 `loadOnce`，通常远短于此时限 ——
    /// 主要罩住 Scene 尚未建好 `AppServices`、桥还没装配的竞态。
    static let readyTimeoutSeconds: TimeInterval = 8

    var allTracks: () -> [Track] = { [] }
    var allPlaylists: () -> [Playlist] = { [] }
    var tracksInPlaylist: (Playlist.ID) throws -> [Track] = { _ in [] }
    /// 一批歌的**内嵌歌词**（侧表 `TrackLyrics`）。🔴 拆表之后歌词不跟着 `Track` 来，
    /// Siri 那条路要造 `SongEntity`（带歌词字段）就得单独取一次 —— 走**批量**，别逐首查。
    var lyricsByTrackID: ([Track.ID]) throws -> [Track.ID: TrackLyrics] = { _ in [:] }
    var playlistByID: (Playlist.ID) throws -> Playlist? = { _ in nil }
    var currentSession: () -> MediaPlaySession = {
        MediaPlaySession(currentTrackID: nil, isPlaybackActive: false)
    }
    var playQueue: (_ tracks: [Track], _ start: Track) -> Void = { _, _ in }
    var ensurePlayingCurrent: () -> Void = {}
    var setPlaybackMode: (PlaybackMode) -> Void = { _ in }

    /// 装配完成的**信号**（一次）：等待者挂在 `readyWaiters`，`bootstrap` 完成时一次叫醒。
    /// 这三个字段只在 `readinessLock` 内读写。
    private let readinessLock = NSLock()
    private var isBootstrapped = false
    private var readyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init() {}

    func bootstrap(
        allTracks: @escaping () -> [Track],
        allPlaylists: @escaping () -> [Playlist],
        tracksInPlaylist: @escaping (Playlist.ID) throws -> [Track],
        lyricsByTrackID: @escaping ([Track.ID]) throws -> [Track.ID: TrackLyrics],
        playlistByID: @escaping (Playlist.ID) throws -> Playlist?,
        currentSession: @escaping () -> MediaPlaySession,
        playQueue: @escaping (_ tracks: [Track], _ start: Track) -> Void,
        ensurePlayingCurrent: @escaping () -> Void,
        setPlaybackMode: @escaping (PlaybackMode) -> Void
    ) {
        self.allTracks = allTracks
        self.allPlaylists = allPlaylists
        self.tracksInPlaylist = tracksInPlaylist
        self.lyricsByTrackID = lyricsByTrackID
        self.playlistByID = playlistByID
        self.currentSession = currentSession
        self.playQueue = playQueue
        self.ensurePlayingCurrent = ensurePlayingCurrent
        self.setPlaybackMode = setPlaybackMode
        markReady()
    }

    // MARK: - 装配完成的信号

    /// 等装配完成；**到点还没好就抛 `notReady`**。
    ///
    /// 🔴 系统入口拿到桥之后，**就绪判断只写这一句** —— 再写第二处就是同一个概念写两遍。
    func awaitReady() async throws {
        guard await waitUntilReady() else { throw IntentPlaybackError.notReady }
    }

    /// 等装配完成。已就绪立即返回；否则**等信号**（不是轮询），超时返回 `false`
    /// —— 调用方按失败处理，不假成功。
    private func waitUntilReady(
        timeoutSeconds: TimeInterval = LocalTuneIntentBridge.readyTimeoutSeconds
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            hold(continuation, timeoutSeconds: timeoutSeconds)
        }
    }

    /// 装配完成：置位并叫醒所有等待者。**只由 `bootstrap` 调。**
    private func markReady() {
        readinessLock.lock()
        isBootstrapped = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        readinessLock.unlock()
        for waiter in waiters.values { waiter.resume(returning: true) }
    }

    /// 挂上等待者；已就绪就直接放行。
    ///
    /// ⚠️ 写成**同步**函数：锁不许在 `async` 函数体里加（Swift 对"异步上下文里调 `NSLock`"
    /// 会给告警，Swift 6 里直接报错）。
    private func hold(
        _ continuation: CheckedContinuation<Bool, Never>,
        timeoutSeconds: TimeInterval
    ) {
        readinessLock.lock()
        if isBootstrapped {
            readinessLock.unlock()
            continuation.resume(returning: true)
            return
        }
        let token = UUID()
        readyWaiters[token] = continuation
        readinessLock.unlock()
        // 到点还没装配好 → 判超时。真被 `markReady` 抢先取走时，这一枪是空动作。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
            self?.expire(token)
        }
    }

    /// 超时：把还没被叫醒的等待者取回并放行（`false`）。
    private func expire(_ token: UUID) {
        readinessLock.lock()
        let waiter = readyWaiters.removeValue(forKey: token)
        readinessLock.unlock()
        waiter?.resume(returning: false)
    }

    // MARK: - 给 Policy 用的库快照

    func makeLibrary() throws -> MediaPlayLibrary {
        let tracks = allTracks().map {
            MediaPlayLibrary.Track(id: $0.id, title: $0.title, album: $0.album)
        }
        let playlists: [MediaPlayLibrary.Playlist] = try allPlaylists().map { list in
            let ids = try tracksInPlaylist(list.id).map(\.id)
            return MediaPlayLibrary.Playlist(id: list.id, name: list.name, trackIDs: ids)
        }
        return MediaPlayLibrary(tracks: tracks, playlists: playlists)
    }

    // MARK: - 造 Intent 实体

    /// 一批歌 → 一批**带歌词**的 `SongEntity`。
    ///
    /// 🔴 **唯一入口**：歌词在侧表（`TrackLyrics`），**不跟着 `Track` 来** ⇒ 造 Entity 必须
    /// **先批量取一次**歌词（一条 `IN`，别逐首 N+1）。`LocalTuneAppIntents.swift` 里有两处要
    /// 造 Entity（全库查询 / 「获取歌单中的歌曲」），各写一遍就是**同一个概念写两遍**。
    func songEntities(for tracks: [Track]) throws -> [SongEntity] {
        let lyrics = try lyricsByTrackID(tracks.map(\.id))
        return tracks.map { SongEntity($0, lyrics: lyrics[$0.id]) }
    }

    // MARK: - 执行 Policy 结果

    func apply(_ target: MediaPlayTarget) throws {
        switch target {
        case let .play(trackIDs, startID):
            let byID = tracksByID()
            let queue = trackIDs.compactMap { byID[$0] }
            guard let start = byID[startID], !queue.isEmpty else {
                throw IntentPlaybackError.emptyLibrary
            }
            playQueue(queue, start)
        case .ensurePlayingCurrent:
            ensurePlayingCurrent()
        case let .failure(failure):
            throw IntentPlaybackError(failure)
        }
    }

    /// 快捷指令「播放一批歌」：先落四档互斥模式，再起播。
    func playSongEntities(
        _ songs: [SongEntity],
        shuffled: Bool,
        repeatMode: ShortcutRepeatMode
    ) throws {
        setPlaybackMode(shortcutPlaybackMode(shuffled: shuffled, repeatMode: repeatMode))
        let byID = tracksByID()
        var ordered = songs.compactMap { byID[$0.id] }
        if shuffled {
            ordered.shuffle()
        }
        guard let start = ordered.first else { throw IntentPlaybackError.emptyLibrary }
        playQueue(ordered, start)
    }

    /// 库里的歌按 id 索引 —— `apply` 与 `playSongEntities` 都要用，**只写一处**。
    private func tracksByID() -> [Track.ID: Track] {
        Dictionary(uniqueKeysWithValues: allTracks().map { ($0.id, $0) })
    }
}

enum IntentPlaybackError: Error, CustomLocalizedStringResourceConvertible {
    case emptyLibrary
    case emptyPlaylist
    case missingPlaylist
    case notReady

    init(_ failure: MediaPlayFailure) {
        switch failure {
        case .emptyLibrary: self = .emptyLibrary
        case .emptyPlaylist: self = .emptyPlaylist
        case .missingPlaylist: self = .missingPlaylist
        case .notFound: self = .emptyLibrary
        }
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyLibrary: "资料库是空的"
        case .emptyPlaylist: "这个歌单还没有歌曲"
        case .missingPlaylist: "找不到这个歌单"
        case .notReady: "LocalTune 还没准备好"
        }
    }
}

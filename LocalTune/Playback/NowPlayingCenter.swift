import MediaPlayer

/// 锁屏封面的素材从哪儿来 —— **装配层（`App/AppArtwork.lockScreenArtwork`）给**。
///
/// 🔴 **为什么注入的是"动作"而不是"一张图"**：`Playback` 不碰 UI，
/// 而 `MPMediaItemArtwork` 里装的是 `UIImage`、还得按"屏幕倍数"去取。
/// 这两样都只有界面那一侧才知道 ⇒ 让装配层把「路径进、素材出」这个动作递进来，
/// 这边只管"什么时候要、要不要作数"。
///
/// ⚠️ 回调在**后台**回来（`AppArtwork` 那边把读盘放后台）：拿到之后自己回主线程再往上贴。
///
/// - Parameters:
///   - artworkPath: 封面文件名（`Track.artworkPath`）。
///   - completion: 读不到就给 `nil`（封面是缓存，没有它这首歌照样能用）。
typealias LockScreenArtworkLoader = (
    _ artworkPath: String, _ completion: @escaping (MPMediaItemArtwork?) -> Void
) -> Void

/// 锁屏 / 控制中心要的**一切**，一次给全。
///
/// 🔴 **为什么是「一次给全」、不是一个字段一个口子**：锁屏信息**分三处**拼
/// 于是「标题是新的、进度还是旧的」这种半截快照会被系统读走。
/// 收成一份之后，要么整份是新的、要么整份没发。
struct NowPlayingSnapshot: Equatable {

    var title: String
    var artist: String
    var album: String

    /// 封面的**文件名**（`Track.artworkPath`），不是图。
    ///
    /// ⚠️ 为什么给名字、不给 `UIImage`：读一张封面要解一次盘（哪怕有缩略图缓存，
    /// 第一次还是得解），而拼快照是在**主线程**上、状态一变就跑一遍 ——
    /// 把封面解码做在主线程上正是那个坑。
    /// 给名字，让真要图的那一层**到后台**去读。
    var artworkPath: String?

    /// 播到哪儿了（秒）。
    var elapsed: TimeInterval

    var duration: TimeInterval

    /// 播放速率（变速档翻出来的 `Float`）。
    /// **「暂停」不在这儿** —— 那是投影算出来的 `0`（见 `nowPlayingProjection`）。
    var rate: Float

    /// 播放会话是否活跃（装载也算）—— **按钮图态**认它，见 `nowPlayingProjection`。
    var isPlaybackActive: Bool

    /// **真的在出声吗**（装载中不算）—— **速率**认它，见 `nowPlayingProjection`。
    var isPlaying: Bool

    /// 当前曲收藏没有。锁屏那颗心用它，不另订库。
    var isFavorite: Bool

    /// 循环 / 随机脸从这儿投影，不在 Center 里猜。
    var playbackMode: PlaybackMode
}

extension NowPlayingSnapshot {

    /// 「现在这一份播放状态 ＋ 播到哪儿了 ＋ 锁屏文案 ⇒ 锁屏要的那份快照」—— 纯映射，不碰系统。
    ///
    /// 标题 / 艺人是装配层已经算好的**显示文案**（有同步行时标题是当前句），
    /// 不是库里的歌名。专辑仍原样搬 `Track`。
    ///
    /// ⚠️ `rate` 是变速档，不是「暂停」。暂停由 `nowPlayingProjection` 写成 `0`。
    init(
        playerState: PlayerState,
        position: TimeInterval,
        rate: Float,
        title: String,
        artist: String,
        isFavorite: Bool
    ) {
        let track = playerState.track
        self.title = title
        self.artist = artist
        self.album = track?.album ?? ""
        self.artworkPath = track?.artworkPath
        self.elapsed = position
        self.duration = playerState.duration
        self.rate = rate
        self.isPlaybackActive = playerState.isPlaybackActive
        self.isPlaying = playerState.isActuallyPlaying
        self.isFavorite = isFavorite
        self.playbackMode = playerState.playbackMode
    }
}

/// 锁屏 ＋ 控制中心 ＋ 耳机线控。🔴 **全工程只有这一个地方写 `MPNowPlayingInfoCenter`
/// 和 `MPRemoteCommandCenter`。**
///
/// 外面只管**给一份完整快照**（`update(_:)`）或者**清空**（`clear()`）——
/// 拼字典、去重、封面怎么读、命令怎么回，全在里面。
///
/// ## 谁调它
///
/// 装配层（`AppServices`）盯着播放状态、锁屏文案、收藏和跳进度，变了就调 `update(_:)`。
/// 它自己**不订阅任何流** —— 订阅是装配层的事，它只管「给我一份、我发出去」。
/// 收藏那一下写下走注入的 `LibraryStore`；`PlayManager` 仍然不认识库。
///
/// ## 线程
///
/// **只在主线程用**（状态流在主线程上推，系统那套也只许在主线程碰）——
/// 所以下面几个缓存字段都不需要锁。唯一离开主线程的是**读封面**那一趟
/// （读盘 ＋ 解码，见 `loadArtwork`），它回来时会先确认「现在要的还是同一张图」。
///
/// ## 进度为什么不自己推
///
/// 给系统写完 `playbackRate` 之后，**它自己按这个速率把进度条往前走** ——
/// 所以我们只在状态变了、锁屏文案变了、位置跳了、收藏或模式变了时带上当前位置，
/// 中间由系统自己走。按秒再推一遍是白花。
@MainActor
final class NowPlayingCenter {

    /// 上一次真的写进系统的那一份。
    ///
    /// ⚠️ 写成 struct 而不是元组：**元组有 `==` 但不符合 `Equatable`**，
    /// 没法直接拿去比（在 `AppServices` 那条流上栽过一次）。
    private struct Published: Equatable {
        var snapshot: NowPlayingSnapshot
        /// 当时有没有真的把封面带上 —— 封面是**后到**的，到了要重发一次。
        var hasArtwork: Bool
    }

    /// 锁屏上那几个键亮不亮 —— 每写一个属性都是一次跨进程调用，所以也去重。
    private struct CommandAvailability: Equatable {
        var play: Bool
        var pause: Bool
        var toggle: Bool
        var next: Bool
        var previous: Bool
        var changePosition: Bool
        var like: Bool
        var likeActive: Bool
        var repeatEnabled: Bool
        var shuffleEnabled: Bool
        var repeatFace: RemoteRepeatFace
        var shuffleFace: RemoteShuffleFace
    }

    /// 远程命令要落到哪儿 —— 装配层给。
    private let playManager: PlayManager

    /// 只给锁屏心写收藏。不订流。
    private let library: LibraryStore

    /// 锁屏封面的素材从哪儿来 —— 装配层给。
    private let lockScreenArtwork: LockScreenArtworkLoader

    /// 最后一次收到的快照（`nil` ＝ 已经清空）。
    private var current: NowPlayingSnapshot?

    /// 已经写进系统的那一份（用来去重）。
    private var published: Published?

    /// 已经解好、能随快照一起给出去的那张封面。
    ///
    /// ⚠️ 带着 `path`：**同一个槽位会换歌**，不带的话换歌那一瞬会把上一首的图贴给新歌。
    private var loadedArtwork: (path: String, artwork: MPMediaItemArtwork)?

    /// **最近一次发起读盘的那张图**的路径（不是"此刻正在读" —— 读失败它也不清）。
    ///
    /// 它的作用是**别重复发起**：状态一变就会走一遍 `publish()`，
    /// 而"还没解好"这个条件在那一瞬一直成立 —— 不记着就会对同一个文件连读好几次盘。
    /// 读不到也不清空（封面是缓存，**读不到就是没图**，不重试）。
    private var loadingArtworkPath: String?

    /// 已经写进系统的命令可用性。
    private var publishedCommands: CommandAvailability?

    /// 注册在系统单例上的那几个 target —— 存着是为了退的时候能摘干净（代码标准第 13 条）。
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []

    init(
        playManager: PlayManager,
        library: LibraryStore,
        lockScreenArtwork: @escaping LockScreenArtworkLoader
    ) {
        self.playManager = playManager
        self.library = library
        self.lockScreenArtwork = lockScreenArtwork
        setUpRemoteCommands()
    }

    deinit {
        for entry in commandTargets {
            entry.command.removeTarget(entry.target)
        }
    }

    // MARK: - 对外

    /// 把这一份快照写进锁屏 / 控制中心。**主线程调**。
    ///
    /// 和上一份一模一样就什么都不做。状态流偶尔会把同一份再推过来。
    func update(_ snapshot: NowPlayingSnapshot) {
        current = snapshot
        publish()
    }

    /// 什么都没有了（没装歌 / 当前那首被删了）—— 把锁屏那块整个撤掉。
    func clear() {
        current = nil
        published = nil
        loadedArtwork = nil
        loadingArtworkPath = nil
        let projection = nowPlayingProjection(hasTrack: false, isPlaybackActive: false, isPlaying: false)
        // 撤掉之后态势是「停」：不写这一下，图态会停在清空前的最后一帧。
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = mpPlaybackState(projection.playbackFace)
        applyCommandAvailability(
            hasTrack: false,
            projection: projection,
            isFavorite: false,
            playbackMode: .sequential
        )
    }

    // MARK: - 写进系统

    private func publish() {
        guard let snapshot = current else { return }

        let hasArtwork = artworkForCurrent != nil
        let next = Published(snapshot: snapshot, hasArtwork: hasArtwork)
        guard published != next else { return }
        published = next

        let projection = nowPlayingProjection(
            hasTrack: true,
            isPlaybackActive: snapshot.isPlaybackActive,
            isPlaying: snapshot.isPlaying,
            rate: snapshot.rate
        )
        applyCommandAvailability(
            hasTrack: true,
            projection: projection,
            isFavorite: snapshot.isFavorite,
            playbackMode: snapshot.playbackMode
        )

        let defaultRate = snapshot.rate.isFinite && snapshot.rate > 0 ? snapshot.rate : 1
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPMediaItemPropertyAlbumTitle: snapshot.album,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: projection.playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: defaultRate,
        ]
        if let artwork = artworkForCurrent {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        // 按钮图态**另报一份**：速率只管进度条自己走，图态在部分系统（iOS 16、自签安装）
        // 不会从速率倒推 —— 不报这一下，暂停后按钮就停在「暂停」。
        center.playbackState = mpPlaybackState(projection.playbackFace)

        // 封面还没解好（或者刚换歌）⇒ 到后台读一张，读到再补发一次。
        if let path = snapshot.artworkPath, !path.isEmpty,
           artworkForCurrent == nil, loadingArtworkPath != path {
            loadingArtworkPath = path
            loadArtwork(for: path)
        }
    }

    /// 现在能贴出去的那张封面 —— **只有它跟当前这首对得上时才算数**。
    private var artworkForCurrent: MPMediaItemArtwork? {
        guard let loaded = loadedArtwork, loaded.path == current?.artworkPath else { return nil }
        return loaded.artwork
    }

    private func applyCommandAvailability(
        hasTrack: Bool,
        projection: NowPlayingProjection,
        isFavorite: Bool,
        playbackMode: PlaybackMode
    ) {
        let faces = remotePlaybackFaces(for: playbackMode)
        let availability = CommandAvailability(
            play: projection.isPlayEnabled,
            pause: projection.isPauseEnabled,
            // 下一首 / 上一首 / 切一下：只要有歌就都亮 —— 队列里到底有没有下一首
            // 是 `PlayQueue` 的事（到头了它自己什么都不做），不该反映成"键按不动"。
            toggle: hasTrack,
            next: hasTrack,
            previous: hasTrack,
            changePosition: hasTrack,
            like: hasTrack,
            likeActive: hasTrack && isFavorite,
            repeatEnabled: hasTrack,
            shuffleEnabled: hasTrack,
            repeatFace: hasTrack ? faces.repeat : .off,
            shuffleFace: hasTrack ? faces.shuffle : .off
        )
        guard publishedCommands != availability else { return }
        publishedCommands = availability

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = availability.play
        center.pauseCommand.isEnabled = availability.pause
        center.togglePlayPauseCommand.isEnabled = availability.toggle
        center.nextTrackCommand.isEnabled = availability.next
        center.previousTrackCommand.isEnabled = availability.previous
        center.changePlaybackPositionCommand.isEnabled = availability.changePosition
        center.likeCommand.isEnabled = availability.like
        center.likeCommand.isActive = availability.likeActive
        center.changeRepeatModeCommand.isEnabled = availability.repeatEnabled
        center.changeShuffleModeCommand.isEnabled = availability.shuffleEnabled
        center.changeRepeatModeCommand.currentRepeatType = mpRepeatType(availability.repeatFace)
        center.changeShuffleModeCommand.currentShuffleType = mpShuffleType(availability.shuffleFace)
    }

    // MARK: - 封面

    /// 到后台去读一张封面。**读不到就是没图**——
    /// 不发图、不报错、也不重试：封面是缓存，没有它这首歌照样能用。
    ///
    /// ⚠️ 回来时要**再确认一次「现在要的还是这张图」**：读盘那几百毫秒里用户可能已经换歌了，
    /// 不认这一下就会把上一首的封面贴到新歌上。
    ///
    /// ⚠️ 注入的那个动作**不能捕获 `self`**：它做出来 `MPMediaItemArtwork` 归
    /// `MPNowPlayingInfoCenter` 持有、那个中心是系统单例 —— 捕获了就成环了
    /// （`PressScaleButton` 那边同一个道理）。所以那边包图时不留引用，这边只留 `weak`。
    private func loadArtwork(for path: String) {
        lockScreenArtwork(path) { [weak self] artwork in
            guard let artwork else { return }
            DispatchQueue.main.async {
                guard let self, self.current?.artworkPath == path else { return }
                self.loadedArtwork = (path, artwork)
                // 不用手动清 `published`：去重看的是「有没有带上封面」，
                // 这一份带图、上一份没带 ⇒ 天然不相等，会正常发出去。
                self.publish()
            }
        }
    }

    // MARK: - 远程命令

    /// 把命令接到系统上。判断在 `RemoteCommandPolicy`，动作走总管 / 曲库已经公开的口子。
    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand, as: .play)
        register(center.pauseCommand, as: .pause)
        register(center.togglePlayPauseCommand, as: .togglePlayPause)
        register(center.nextTrackCommand, as: .nextTrack)
        register(center.previousTrackCommand, as: .previousTrack)
        registerChangePlaybackPosition(center.changePlaybackPositionCommand)
        registerLike(center.likeCommand)
        registerRepeat(center.changeRepeatModeCommand)
        registerShuffle(center.changeShuffleModeCommand)
    }

    private func register(_ command: MPRemoteCommand, as remote: RemoteCommand) {
        let target = command.addTarget { [weak self] _ in
            (self?.handle(remote) ?? false) ? .success : .noActionableNowPlayingItem
        }
        commandTargets.append((command, target))
    }

    private func registerChangePlaybackPosition(_ command: MPRemoteCommand) {
        let target = command.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return (self?.handle(.changePlaybackPosition(event.positionTime)) ?? false)
                ? .success : .noActionableNowPlayingItem
        }
        commandTargets.append((command, target))
    }

    private func registerLike(_ command: MPRemoteCommand) {
        let target = command.addTarget { [weak self] event in
            guard let event = event as? MPFeedbackCommandEvent else { return .commandFailed }
            return (self?.handle(.like(wantsFavorite: !event.isNegative)) ?? false)
                ? .success : .noActionableNowPlayingItem
        }
        commandTargets.append((command, target))
    }

    private func registerRepeat(_ command: MPRemoteCommand) {
        let target = command.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            return (self?.handle(.changeRepeatMode(remoteRepeatFace(event.repeatType))) ?? false)
                ? .success : .noActionableNowPlayingItem
        }
        commandTargets.append((command, target))
    }

    private func registerShuffle(_ command: MPRemoteCommand) {
        let target = command.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            return (self?.handle(.changeShuffleMode(remoteShuffleFace(event.shuffleType))) ?? false)
                ? .success : .noActionableNowPlayingItem
        }
        commandTargets.append((command, target))
    }

    /// 系统转来一条命令。判断在 `RemoteCommandPolicy`；动作只调已经公开的口子。
    ///
    /// - Returns: 做过事 ＝ `true`；`false` 只有「什么都没装」。`.ignore` 也算做过事
    ///   （回 `false` 会让系统以为这个键坏了）。
    private func handle(_ command: RemoteCommand) -> Bool {
        switch remoteCommandAction(
            for: command,
            status: playManager.status,
            playbackMode: playManager.currentPlaybackMode
        ) {
        case .noActionableItem:
            return false
        case .ignore:
            return true
        case .togglePlayPause:
            playManager.togglePlayPause()
            return true
        case .next:
            playManager.playNext()
            return true
        case .previous:
            playManager.playPrevious()
            return true
        case .seek(let time):
            playManager.seek(to: time)
            return true
        case .setFavorite(let wantsFavorite):
            guard let id = playManager.currentTrack?.id else { return false }
            // 敢吞 `try?` 这一下：收藏写失败不该让这条**锁屏 / 耳机**远程命令算失败 ——
            // 命令已经被收到，这里也没有能回给系统的人话；界面上的收藏态会随收藏流自己回正。
            try? library.setFavorite(wantsFavorite, trackID: id)
            return true
        case .setPlaybackMode(let mode):
            if playManager.currentPlaybackMode != mode {
                playManager.setPlaybackMode(mode)
            }
            return true
        }
    }
}

private func remoteRepeatFace(_ type: MPRepeatType) -> RemoteRepeatFace {
    switch type {
    case .one: return .one
    case .all: return .all
    default: return .off
    }
}

private func remoteShuffleFace(_ type: MPShuffleType) -> RemoteShuffleFace {
    switch type {
    case .items, .collections: return .items
    default: return .off
    }
}

private func mpRepeatType(_ face: RemoteRepeatFace) -> MPRepeatType {
    switch face {
    case .off: return .off
    case .one: return .one
    case .all: return .all
    }
}

private func mpShuffleType(_ face: RemoteShuffleFace) -> MPShuffleType {
    switch face {
    case .off: return .off
    case .items: return .items
    }
}

/// 我们的「播放态」→ 系统那个私有枚举（`MPNowPlayingInfoCenter.playbackState`）。
///
/// ⚠️ 这条私有调用**成对**依赖打包脚本 ENT 里的
/// `com.apple.mediaremote.set-playback-state`（`bin/build_release_ios`）——
/// 少了那半，系统不认这一下。
private func mpPlaybackState(_ face: NowPlayingPlaybackFace) -> MPNowPlayingPlaybackState {
    switch face {
    case .playing: return .playing
    case .paused: return .paused
    case .stopped: return .stopped
    }
}

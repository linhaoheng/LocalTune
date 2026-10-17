import AppIntents
import Foundation

// MARK: - SongEntity

struct SongEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "音乐")
    static var defaultQuery = SongEntityQuery()

    var id: String

    @Property(title: "标题")
    var title: String

    @Property(title: "艺人")
    var artist: String

    @Property(title: "专辑")
    var album: String

    @Property(title: "专辑艺人")
    var albumArtist: String

    @Property(title: "类型")
    var genre: String

    @Property(title: "作曲者")
    var composer: String

    @Property(title: "名称")
    var fileName: String

    @Property(title: "文件路径")
    var filePath: String

    @Property(title: "添加日期")
    var dateAdded: Date

    @Property(title: "发布日期")
    var releaseDate: String

    @Property(title: "持续时间")
    var duration: TimeInterval

    @Property(title: "播放次数")
    var playCount: Int

    @Property(title: "音轨编号")
    var trackNumber: Int

    @Property(title: "光盘编号")
    var discNumber: Int

    @Property(title: "歌词")
    var lyrics: String

    @Property(title: "评论")
    var comment: String

    @Property(title: "有专辑插图")
    var hasArtwork: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artist)")
    }

    /// - Parameter lyrics: 这首歌的**内嵌歌词**（侧表 `TrackLyrics`）。`nil` ＝ 没有。
    ///   🔴 拆表之后它**不跟着 `Track` 来**，由调用方单独取。
    init(_ track: Track, lyrics: TrackLyrics?) {
        id = track.id
        title = track.title
        artist = track.artist
        album = track.album
        albumArtist = track.albumArtist ?? ""
        genre = track.genre ?? ""
        composer = track.composer ?? ""
        fileName = track.fileName
        filePath = MusicFileStore.resolve(relativePath: track.path).path
        dateAdded = track.dateAdded
        releaseDate = track.releaseDate ?? ""
        if let ms = track.durationMs, ms > 0 {
            duration = TimeInterval(ms) / 1000
        } else {
            duration = 0
        }
        playCount = track.playCount
        trackNumber = track.trackNumber ?? 0
        discNumber = track.discNumber ?? 0
        self.lyrics = LyricsSourcePolicy.text(for: track, lyrics: lyrics) ?? ""
        comment = track.comment ?? ""
        hasArtwork = track.artworkPath != nil
    }
}

/// 一个属性比较谓词（只映库字段，**不**读音频文件）。
struct SongPredicate {
    var matches: (SongEntity) -> Bool
}

struct SongEntityQuery: EntityStringQuery, EntityPropertyQuery {

    /// 主 App 的桥 —— 由 `AppDelegate` 在启动时登记进框架，这里**按框架的机制取**。
    @Dependency private var bridge: LocalTuneIntentBridge

    static var properties = QueryProperties {
        Property(\SongEntity.$title) {
            EqualToComparator { value in SongPredicate { Self.equal($0.title, value) } }
            ContainsComparator { value in SongPredicate { Self.contains($0.title, value) } }
        }
        Property(\SongEntity.$artist) {
            EqualToComparator { value in SongPredicate { Self.equal($0.artist, value) } }
            ContainsComparator { value in SongPredicate { Self.contains($0.artist, value) } }
        }
        Property(\SongEntity.$album) {
            EqualToComparator { value in SongPredicate { Self.equal($0.album, value) } }
            ContainsComparator { value in SongPredicate { Self.contains($0.album, value) } }
        }
        Property(\SongEntity.$albumArtist) {
            EqualToComparator { value in SongPredicate { Self.equal($0.albumArtist, value) } }
            ContainsComparator { value in SongPredicate { Self.contains($0.albumArtist, value) } }
        }
        Property(\SongEntity.$genre) {
            EqualToComparator { value in SongPredicate { Self.equal($0.genre, value) } }
            ContainsComparator { value in SongPredicate { Self.contains($0.genre, value) } }
        }
        Property(\SongEntity.$composer) {
            EqualToComparator { value in SongPredicate { Self.equal($0.composer, value) } }
            ContainsComparator { value in SongPredicate { Self.contains($0.composer, value) } }
        }
        Property(\SongEntity.$fileName) {
            EqualToComparator { value in SongPredicate { Self.equal($0.fileName, value) } }
            ContainsComparator { value in SongPredicate { Self.contains($0.fileName, value) } }
        }
        Property(\SongEntity.$filePath) {
            EqualToComparator { value in SongPredicate { Self.equal($0.filePath, value) } }
            ContainsComparator { value in SongPredicate { Self.contains($0.filePath, value) } }
        }
        Property(\SongEntity.$dateAdded) {
            EqualToComparator { value in SongPredicate { $0.dateAdded == value } }
            GreaterThanComparator { value in SongPredicate { $0.dateAdded > value } }
            LessThanComparator { value in SongPredicate { $0.dateAdded < value } }
        }
        Property(\SongEntity.$releaseDate) {
            EqualToComparator { value in SongPredicate { Self.equal($0.releaseDate, value) } }
            ContainsComparator { value in SongPredicate { Self.contains($0.releaseDate, value) } }
        }
        Property(\SongEntity.$duration) {
            EqualToComparator { value in SongPredicate { $0.duration == value } }
            GreaterThanComparator { value in SongPredicate { $0.duration > value } }
            LessThanComparator { value in SongPredicate { $0.duration < value } }
        }
        Property(\SongEntity.$playCount) {
            EqualToComparator { value in SongPredicate { $0.playCount == value } }
            GreaterThanComparator { value in SongPredicate { $0.playCount > value } }
            LessThanComparator { value in SongPredicate { $0.playCount < value } }
        }
        Property(\SongEntity.$trackNumber) {
            EqualToComparator { value in SongPredicate { $0.trackNumber == value } }
            GreaterThanComparator { value in SongPredicate { $0.trackNumber > value } }
            LessThanComparator { value in SongPredicate { $0.trackNumber < value } }
        }
        Property(\SongEntity.$discNumber) {
            EqualToComparator { value in SongPredicate { $0.discNumber == value } }
            GreaterThanComparator { value in SongPredicate { $0.discNumber > value } }
            LessThanComparator { value in SongPredicate { $0.discNumber < value } }
        }
        Property(\SongEntity.$lyrics) {
            EqualToComparator { value in SongPredicate { Self.equal($0.lyrics, value) } }
            ContainsComparator { value in SongPredicate { Self.contains($0.lyrics, value) } }
        }
        Property(\SongEntity.$comment) {
            EqualToComparator { value in SongPredicate { Self.equal($0.comment, value) } }
            ContainsComparator { value in SongPredicate { Self.contains($0.comment, value) } }
        }
        Property(\SongEntity.$hasArtwork) {
            EqualToComparator { value in SongPredicate { $0.hasArtwork == value } }
        }
    }

    static var sortingOptions = SortingOptions {
        SortableBy(\SongEntity.$title)
        SortableBy(\SongEntity.$artist)
        SortableBy(\SongEntity.$album)
        SortableBy(\SongEntity.$albumArtist)
        SortableBy(\SongEntity.$genre)
        SortableBy(\SongEntity.$fileName)
        SortableBy(\SongEntity.$dateAdded)
        SortableBy(\SongEntity.$duration)
        SortableBy(\SongEntity.$playCount)
        SortableBy(\SongEntity.$trackNumber)
    }

    @MainActor
    private func readySongs() async throws -> [SongEntity] {
        try await bridge.awaitReady()
        // 🔴 歌词在侧表（`TrackLyrics`）—— 跟 `Track` 分开取；「批量取歌词 ＋ 造 Entity」
        // 收在 `bridge.songEntities(for:)` 一处，别在这儿重写一遍。见 `歌词拆侧表设计.md`。
        return try bridge.songEntities(for: bridge.allTracks())
    }

    func entities(for identifiers: [String]) async throws -> [SongEntity] {
        let songs = try await readySongs()
        let wanted = Set(identifiers)
        return songs.filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SongEntity] {
        let songs = try await readySongs()
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return songs }
        return songs.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
    }

    func suggestedEntities() async throws -> [SongEntity] {
        try await readySongs()
    }

    func entities(
        matching comparators: [SongPredicate],
        mode: ComparatorMode,
        sortedBy: [Sort<SongEntity>],
        limit: Int?
    ) async throws -> [SongEntity] {
        var result = try await readySongs()
        if !comparators.isEmpty {
            result = result.filter { song in
                switch mode {
                case .and:
                    return comparators.allSatisfy { $0.matches(song) }
                case .or:
                    return comparators.contains { $0.matches(song) }
                @unknown default:
                    return comparators.allSatisfy { $0.matches(song) }
                }
            }
        }
        if !sortedBy.isEmpty {
            result.sort { lhs, rhs in
                for sort in sortedBy {
                    if let ordered = Self.isOrderedBefore(lhs, rhs, sort.by) {
                        return sort.order == .ascending ? ordered : !ordered
                    }
                }
                return false
            }
        }
        if let limit, limit > 0 {
            result = Array(result.prefix(limit))
        }
        return result
    }

    private static func equal(_ value: String, _ query: String) -> Bool {
        value.localizedCaseInsensitiveCompare(query) == .orderedSame
    }

    private static func contains(_ value: String, _ query: String) -> Bool {
        value.localizedCaseInsensitiveContains(query)
    }

    private static func isOrderedBefore(
        _ lhs: SongEntity,
        _ rhs: SongEntity,
        _ path: PartialKeyPath<SongEntity>
    ) -> Bool? {
        func text(_ keyPath: KeyPath<SongEntity, String>) -> Bool? {
            let result = lhs[keyPath: keyPath].localizedStandardCompare(rhs[keyPath: keyPath])
            return result == .orderedSame ? nil : result == .orderedAscending
        }
        if path == \SongEntity.title || path == \SongEntity.$title { return text(\.title) }
        if path == \SongEntity.artist || path == \SongEntity.$artist { return text(\.artist) }
        if path == \SongEntity.album || path == \SongEntity.$album { return text(\.album) }
        if path == \SongEntity.albumArtist || path == \SongEntity.$albumArtist { return text(\.albumArtist) }
        if path == \SongEntity.genre || path == \SongEntity.$genre { return text(\.genre) }
        if path == \SongEntity.fileName || path == \SongEntity.$fileName { return text(\.fileName) }
        if path == \SongEntity.dateAdded || path == \SongEntity.$dateAdded {
            if lhs.dateAdded == rhs.dateAdded { return nil }
            return lhs.dateAdded < rhs.dateAdded
        }
        if path == \SongEntity.duration || path == \SongEntity.$duration {
            if lhs.duration == rhs.duration { return nil }
            return lhs.duration < rhs.duration
        }
        if path == \SongEntity.playCount || path == \SongEntity.$playCount {
            if lhs.playCount == rhs.playCount { return nil }
            return lhs.playCount < rhs.playCount
        }
        if path == \SongEntity.trackNumber || path == \SongEntity.$trackNumber {
            if lhs.trackNumber == rhs.trackNumber { return nil }
            return lhs.trackNumber < rhs.trackNumber
        }
        return text(\.title)
    }
}

// MARK: - PlaylistEntity

struct PlaylistEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "歌单")
    static var defaultQuery = PlaylistEntityQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PlaylistEntityQuery: EntityStringQuery {

    /// 主 App 的桥 —— 由 `AppDelegate` 在启动时登记进框架，这里**按框架的机制取**。
    @Dependency private var bridge: LocalTuneIntentBridge

    @MainActor
    private func readyPlaylists() async throws -> [PlaylistEntity] {
        try await bridge.awaitReady()
        return bridge.allPlaylists().map { PlaylistEntity(id: $0.id, name: $0.name) }
    }

    func entities(for identifiers: [UUID]) async throws -> [PlaylistEntity] {
        let lists = try await readyPlaylists()
        let wanted = Set(identifiers)
        return lists.filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let lists = try await readyPlaylists()
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return lists }
        return lists.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        try await readyPlaylists()
    }
}

// MARK: - GetPlaylistSongs / PlaySongs

struct GetPlaylistSongsIntent: AppIntent {
    static var title: LocalizedStringResource = "获取播放列表中的歌曲"
    static var description = IntentDescription("取出歌单里的歌曲")

    /// 主 App 的桥 —— 由 `AppDelegate` 在启动时登记进框架，这里**按框架的机制取**。
    @Dependency private var bridge: LocalTuneIntentBridge

    @Parameter(title: "播放列表")
    var playlist: PlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("获取 \(\.$playlist) 中的歌曲")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SongEntity]> {
        try await bridge.awaitReady()
        guard try bridge.playlistByID(playlist.id) != nil else {
            throw IntentPlaybackError.missingPlaylist
        }
        let songs = try bridge.songEntities(for: bridge.tracksInPlaylist(playlist.id))
        return .result(value: songs)
    }
}

struct PlaySongsIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "播放音乐"
    static var description = IntentDescription("播放音乐")

    /// 主 App 的桥 —— 由 `AppDelegate` 在启动时登记进框架，这里**按框架的机制取**。
    @Dependency private var bridge: LocalTuneIntentBridge

    @Parameter(title: "音乐", inputConnectionBehavior: .connectToPreviousIntentResult)
    var songs: [SongEntity]?

    @Parameter(title: "随机播放")
    var shuffle: ShortcutShuffleMode

    @Parameter(title: "重复")
    var repeatMode: ShortcutRepeatMode

    static var parameterSummary: some ParameterSummary {
        Summary("播放 \(\.$songs)") {
            \.$shuffle
            \.$repeatMode
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await bridge.awaitReady()
        guard let songs, !songs.isEmpty else {
            throw IntentPlaybackError.emptyLibrary
        }
        try bridge.playSongEntities(
            songs,
            shuffled: shuffle == .songs,
            repeatMode: repeatMode
        )
        return .result()
    }
}

struct LocalTuneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaySongsIntent(),
            phrases: [
                "用\(.applicationName)播放音乐",
                "在\(.applicationName)播放歌曲"
            ]
        )
    }
}

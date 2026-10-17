import Foundation

/// Siri `INPlayMediaIntent` →「该播什么」的**纯判断**。
///
/// 🔴 **为什么归 `App/Intents/`（而不是 `Playback/Decisions/`）**：收进来的是 `MediaPlayRequest`
/// 等 **Siri 的词汇**，干的是把入口参数**翻成**播放域的值（`MediaPlayTarget`）—— 这是**入口翻译**，
/// 不是播放域的决策。消费者 `PlayMediaIntentHandling` 也在 App 层。
///
/// 🔴 **为什么独立**：匹配规则要单测；Handler / Bridge 只负责接线，不许把
/// `contains` / id / 续播缠在起播副作用里。
///
/// 收的请求 / 库快照 / 会话、吐的目标在同目录 `MediaPlayTypes.swift`。

/// 稳定 id 只认 id；无 id 再按 歌标题 → 歌单名 → 专辑名。
func mediaPlayTarget(
    request: MediaPlayRequest,
    library: MediaPlayLibrary,
    session: MediaPlaySession
) -> MediaPlayTarget {
    switch request {
    case let .mediaItem(kind, identifier, title):
        return targetForMediaItem(
            kind: kind,
            identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            library: library,
            session: session
        )
    case let .search(kind, name):
        return targetForNamed(
            kind: kind,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            library: library,
            session: session
        )
    case .bare:
        return targetForBare(library: library, session: session)
    }
}

// MARK: - 分支

private func targetForMediaItem(
    kind: MediaPlayRequest.ItemKind,
    identifier: String,
    title: String,
    library: MediaPlayLibrary,
    session: MediaPlaySession
) -> MediaPlayTarget {
    switch kind {
    case .playlist:
        if !identifier.isEmpty {
            guard let id = UUID(uuidString: identifier) else {
                return .failure(.missingPlaylist)
            }
            return playPlaylist(id: id, library: library)
        }
        return playPlaylist(named: title, library: library)
    case .album:
        let name = title.isEmpty ? identifier : title
        return playAlbum(named: name, library: library)
    case .song, .other:
        if !identifier.isEmpty {
            return playSong(id: identifier, library: library)
        }
        return targetForNamed(kind: .song, name: title, library: library, session: session)
    }
}

private func targetForNamed(
    kind: MediaPlayRequest.ItemKind,
    name: String,
    library: MediaPlayLibrary,
    session: MediaPlaySession
) -> MediaPlayTarget {
    if name.isEmpty {
        return targetForBare(library: library, session: session)
    }
    switch kind {
    case .playlist:
        return playPlaylist(named: name, library: library)
    case .album:
        return playAlbum(named: name, library: library)
    case .song, .other:
        // 优先级写死：歌标题 → 歌单名 → 专辑名。
        if let track = library.tracks.first(where: { contains($0.title, name) }) {
            return playAll(startingAt: track.id, library: library)
        }
        let playlistTarget = playPlaylist(named: name, library: library)
        if case .failure(.missingPlaylist) = playlistTarget {
            return playAlbum(named: name, library: library)
        }
        return playlistTarget
    }
}

private func targetForBare(
    library: MediaPlayLibrary,
    session: MediaPlaySession
) -> MediaPlayTarget {
    if session.currentTrackID != nil {
        return .ensurePlayingCurrent
    }
    guard let first = library.tracks.first else {
        return .failure(.emptyLibrary)
    }
    return playAll(startingAt: first.id, library: library)
}

// MARK: - 匹配

private func playSong(id: String, library: MediaPlayLibrary) -> MediaPlayTarget {
    guard library.tracks.contains(where: { $0.id == id }) else {
        return .failure(.notFound)
    }
    return playAll(startingAt: id, library: library)
}

private func playPlaylist(id: UUID, library: MediaPlayLibrary) -> MediaPlayTarget {
    guard let list = library.playlists.first(where: { $0.id == id }) else {
        return .failure(.missingPlaylist)
    }
    return playPlaylistContents(list)
}

private func playPlaylist(named name: String, library: MediaPlayLibrary) -> MediaPlayTarget {
    guard !name.isEmpty else { return .failure(.missingPlaylist) }
    guard let list = library.playlists.first(where: { contains($0.name, name) }) else {
        return .failure(.missingPlaylist)
    }
    return playPlaylistContents(list)
}

private func playPlaylistContents(_ list: MediaPlayLibrary.Playlist) -> MediaPlayTarget {
    guard let start = list.trackIDs.first else {
        return .failure(.emptyPlaylist)
    }
    return .play(trackIDs: list.trackIDs, startID: start)
}

private func playAlbum(named name: String, library: MediaPlayLibrary) -> MediaPlayTarget {
    guard !name.isEmpty else { return .failure(.notFound) }
    let matched = library.tracks.filter { contains($0.album, name) }
    guard let start = matched.first else {
        return .failure(.notFound)
    }
    return .play(trackIDs: matched.map(\.id), startID: start.id)
}

private func playAll(startingAt startID: String, library: MediaPlayLibrary) -> MediaPlayTarget {
    let ids = library.tracks.map(\.id)
    guard !ids.isEmpty else { return .failure(.emptyLibrary) }
    return .play(trackIDs: ids, startID: startID)
}

private func contains(_ value: String, _ query: String) -> Bool {
    value.localizedCaseInsensitiveContains(query)
}

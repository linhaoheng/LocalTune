import Foundation

/// 播放会话文件。Application Support，原子写。**不许**走 UserDefaults。
struct PlaybackSessionStore {
    let url: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        url = base
            .appendingPathComponent("LocalTune", isDirectory: true)
            .appendingPathComponent("playback-session.json")
    }

    init(url: URL) {
        self.url = url
    }

    func load() -> PlaybackSessionSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PlaybackSessionSnapshot.self, from: data)
        } catch {
            // 敢吞：文件在、但读不出或解不开（损坏 / 字段变了）⇒ 当作「没存过会话」，从空开始。
            // 后果有界：顶多丢一次「上次听到哪」，下次正常退出会重存一份把它覆盖。不重试、不打扰用户。
            return nil
        }
    }

    func save(_ snapshot: PlaybackSessionSnapshot) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

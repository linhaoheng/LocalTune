import Foundation

/// 自定义源的**文件存储**（照 primuse）：一源两文件。
///
/// ```
/// Application Support/LyricsSources/
///   <id>.json          主配置（干净，不含 secrets）
///   <id>.secrets.json  旁路（只本地，不导出、不进主配置）
/// ```
///
/// 配置是**文档**，不是查询对象 ⇒ 不进 GRDB、不用迁移。
final class LyricsSourceFileStore {

    enum StoreError: Error, Equatable {
        case invalidID
        case encodeFailed
    }

    private let directory: URL
    private let defaults: UserDefaults
    private let fileManager = FileManager.default

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? Self.defaultDirectory()
        self.defaults = defaults
    }

    /// 全部源（已把旁路 secrets 合回内存里的配置；主文件仍是干净的）。
    func loadAll() -> [LyricsSourceConfig] {
        ensureDirectory()
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".secrets.json") }
            .compactMap { name in
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      var config = try? JSONDecoder().decode(LyricsSourceConfig.self, from: data)
                else { return nil }
                config.secrets = secrets(for: config.id)
                return config
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - 出厂自带的源

    /// 把打包在 App 里的那几个源写进存储目录 —— **只种一次**。
    ///
    /// 🔴 种过之后它们就是**普通源**：能改、能删，删了不会再冒出来。
    /// 所以判据不能是「目录里有没有」—— 用户删光之后下次启动会全补回来，那就不叫能删了。
    /// 用 `UserDefaults` 里一个一次性标记。
    ///
    /// ⚠️ 磁盘上已有同 id 的（用户先自己导了一份）⇒ **不覆盖**。
    /// ⚠️ 一个都读不到（bundle 没挂上）⇒ **不记标记**，下次启动再试 ——
    /// 别把「没种上」记成「种过了」。
    func seedBuiltInsIfNeeded() {
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        let builtIns = Self.builtInConfigs()
        guard !builtIns.isEmpty else { return }
        ensureDirectory()
        for config in builtIns where !fileManager.fileExists(atPath: mainURL(config.id).path) {
            try? save(config)
        }
        defaults.set(true, forKey: Self.seededKey)
    }

    func save(_ config: LyricsSourceConfig) throws {
        guard LyricsSourceConfig.isSafeID(config.id) else { throw StoreError.invalidID }
        ensureDirectory()

        // 主配置里不会有 secrets —— 由 `LyricsSourceConfig.encode(to:)` 保证，这里不用再剥。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { throw StoreError.encodeFailed }
        try data.write(to: mainURL(config.id), options: [.atomic, .completeFileProtection])

        // 🔴 **没有 secrets 时不许删旧的**：重新导入一份主配置（正常就是干净的）
        //    不等于"这个源不需要密钥了" —— 删了，密文源从此只能报「连不上」。
        //    照 primuse 的 `persistAll`：只写，不主动删。
        if let secrets = config.secrets, !secrets.isEmpty {
            guard let secretsData = try? encoder.encode(secrets) else {
                throw StoreError.encodeFailed
            }
            try secretsData.write(
                to: secretsURL(config.id),
                options: [.atomic, .completeFileProtection]
            )
        }
    }

    func delete(id: String) throws {
        guard LyricsSourceConfig.isSafeID(id) else { throw StoreError.invalidID }
        try? fileManager.removeItem(at: mainURL(id))
        try? fileManager.removeItem(at: secretsURL(id))
    }

    /// 主配置的**文件原文**（不含旁路 secrets）。
    ///
    /// 编辑源时用它回填：走 `loadAll()` 再 encode 一遍，会把合回来的 secrets 写进主文件，
    /// 也会重排用户自己的排版。这里只读主文件那几个字节。
    func rawText(id: String) -> String? {
        guard LyricsSourceConfig.isSafeID(id),
              let data = try? Data(contentsOf: mainURL(id))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 旁路 secrets；没有 ⇒ `nil`。
    func secrets(for id: String) -> [String: String]? {
        guard LyricsSourceConfig.isSafeID(id),
              let data = try? Data(contentsOf: secretsURL(id)),
              let secrets = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return secrets
    }

    // MARK: - 私有

    /// 出厂源在 bundle 里的子目录名 —— 跟 `project.yml` 里那个 folder reference 对齐。
    private static let builtInDirectoryName = "LyricsSources"

    /// 「已经种过」的标记键。放这儿而不是 `AppSettings`：这是存储层自己的账，不是用户偏好。
    private static let seededKey = "lyricsSources.builtInsSeeded"

    /// bundle 里那几份配置 —— 解不出来、或自身校验不过的，不算。
    private static func builtInConfigs() -> [LyricsSourceConfig] {
        guard let urls = Bundle.main.urls(
            forResourcesWithExtension: "json",
            subdirectory: builtInDirectoryName
        ) else { return [] }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(LyricsSourceConfig.self, from: data),
                  config.issues.isEmpty
            else { return nil }
            return config
        }
    }

    private func mainURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json", isDirectory: false)
    }

    private func secretsURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).secrets.json", isDirectory: false)
    }

    private func ensureDirectory() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func defaultDirectory() -> URL {
        // iOS 上 applicationSupport 一定存在；取不到就退到临时目录（防御，不崩）。
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LyricsSources", isDirectory: true)
    }
}

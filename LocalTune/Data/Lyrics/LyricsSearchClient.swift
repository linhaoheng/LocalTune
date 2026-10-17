import Foundation

/// 酷狗歌词的取词客户端 —— **搜歌 · 搜词 · 下载**，就这三件事。
///
/// ## 🔴 三步，全部 HTTPS
///
/// | 步 | 接口 | 主键 |
/// |---|---|---|
/// | 搜歌 | `mobiles.kugou.com/api/v3/search/song` | 关键词 |
/// | 搜词 | `lyrics.kugou.com/search` | `hash` ＋ 时长 |
/// | 下载 | `lyrics.kugou.com/download` | `id` ＋ `accesskey` |
///
/// ⚠️ **搜歌域名是有意偏离**：网上流传最广的那条 `mobilecdn.kugou.com` **只有 HTTP**
/// （用它就得给 `Info.plist` 开 ATS 例外），我们改用 `mobiles` 那台（同一套 API，
/// 实测返回逐条一致）⇒ `Info.plist` 一个字不用动。
///
/// ## 🔴 它的边界划得很死
///
/// - **不解析** —— KRC → 我们正文形态归 `LyricsExternalFormatPolicy`（`Playback/Decisions`）；
/// - **不解密** —— KRC 密文 → 明文归 `LyricsKRCDecrypter`（同目录）；
/// - **不落库、不写文件** —— 灌工作层、保存都归编辑歌词页；
/// - **不碰界面** —— 这一层连 `UIKit` 都不 import。
///
/// ## 🔴 三种收尾必须分开
///
/// `找到` / `没找到` / `连不上` 是三件事，**不许合并**：把"连不上"当成"没找到"，
/// 一断网就会把有词的歌永久误当成无词。
///
/// | 情形 | 抛什么 |
/// |---|---|
/// | 搜到 / 下到 | 正常返回 |
/// | 服务器**明确说没有**（搜词 `candidates == []`） | `.notFound` |
/// | 超时 · 连不上 · `5xx` · 响应不成形 · `403` 限流 | `.unreachable` |
///
/// ⚠️ **不许拿"搜歌有没有结果"当「没找到」的判据**：它是真搜索引擎，实测乱词
/// （`zzz不存在zzz`）也回 10 条 ⇒ 判据只在**搜词**那一步。
///
/// ## 超时定 8 秒（沿旧）
///
/// 这不是后台任务，是**用户正看着的界面**：宁可快速失败给个提示，也不要长时间转圈。
final class LyricsSearchClient {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private static let timeout: TimeInterval = 8

    private static let userAgent = "LocalTune/iOS"

    // MARK: - 第一步 · 搜歌

    /// 拿一个词去搜歌。**成功判据 = `status == 1`**（⚠️ 不是 0；顶层 `errcode` 恒为 0，别拿它判）。
    ///
    /// 🔴 **展开 `group`**：顶层那条 ＋ 它的每个子版本**各占一条**。
    /// 子项与顶层**同名同艺人、只差 `hash` 与时长**很常见 ⇒ 列表里会出现"看着像重复"的相邻行，
    /// 那是它的原样行为，**不是 bug**。
    ///
    /// - Returns: 候选（含子版本；服务端顺序）。
    /// - Throws: `.notFound`（一条都没有）/ `.unreachable`（连不上或响应不成形）。
    func searchSongs(_ keyword: String) async throws -> [LyricsSearchResult] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LyricsFetchError.notFound }

        guard let url = Self.url(
            "https://mobiles.kugou.com/api/v3/search/song",
            [
                ("format", "json"), ("keyword", trimmed), ("page", "1"),
                ("pagesize", "20"), ("showtype", "1"),
            ]
        ) else { throw LyricsFetchError.unreachable }

        let data = try await send(url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["status"] as? NSNumber)?.intValue == 1,
              let payload = root["data"] as? [String: Any],
              let info = payload["info"] as? [[String: Any]]
        else { throw LyricsFetchError.unreachable }

        var results: [LyricsSearchResult] = []
        for item in info {
            if let top = LyricsSearchResult(json: item) { results.append(top) }
            if let group = item["group"] as? [[String: Any]] {
                for sub in group {
                    if let row = LyricsSearchResult(json: sub) { results.append(row) }
                }
            }
        }
        guard !results.isEmpty else { throw LyricsFetchError.notFound }
        return results
    }

    // MARK: - 第二步 · 搜词

    /// 按 `hash` ＋ **这条候选自带的时长**（毫秒）搜词。
    ///
    /// 🔴 **`hash` 必须带**：实测不带它（或只给 `duration`）会搜出**另一批**候选。
    /// ⚠️ 时长传的是**候选自带**的那个（搜歌给的秒 ×1000），**不是本机时长** ——
    /// 本机那个字段可空，候选自带则一定有；且实测 `269000` 与 `269792` 命中同一条，
    /// 不必精确到毫秒。
    ///
    /// - Returns: 候选（调用方取 `.first`，不再摆第二层列表）。
    /// - Throws: `.notFound`（`candidates == []`，是合法的"这首歌没词"）/
    ///   `.unreachable`（`status`/`errcode` 不是 200，或响应不成形）。
    func searchLyricCandidates(
        keyword: String, hash: String, durationMilliseconds: Int
    ) async throws -> [LyricsLyricCandidate] {
        guard let url = Self.url(
            "https://lyrics.kugou.com/search",
            [
                ("ver", "1"), ("man", "yes"), ("client", "pc"),
                ("keyword", keyword), ("duration", String(durationMilliseconds)), ("hash", hash),
            ]
        ) else { throw LyricsFetchError.unreachable }

        let data = try await send(url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["status"] as? NSNumber)?.intValue == 200,
              (root["errcode"] as? NSNumber)?.intValue == 200
        else { throw LyricsFetchError.unreachable }

        let rows = root["candidates"] as? [[String: Any]] ?? []
        let candidates = rows.compactMap(LyricsLyricCandidate.init(json:))
        guard !candidates.isEmpty else { throw LyricsFetchError.notFound }
        return candidates
    }

    // MARK: - 第三步 · 下载

    /// 按 `id` ＋ `accesskey` 下一份 **KRC 密文**（base64）。
    ///
    /// 🔴 **失败也包在 HTTP 200 里**：假 id / 错 accesskey ⇒ HTTP 200 ＋
    /// body `{"status":403,…}` ⇒ **必须读 JSON 的 `status`，不能只看 HTTP 码**。
    ///
    /// - Returns: `content`（base64 的 KRC 密文），交给 `LyricsKRCDecrypter` 解。
    /// - Throws: `.unreachable`（`status` 非 200 / `content` 空 / 连不上）。
    func downloadEncrypted(id: String, accessKey: String) async throws -> String {
        guard !id.isEmpty, !accessKey.isEmpty else { throw LyricsFetchError.unreachable }

        guard let url = Self.url(
            "https://lyrics.kugou.com/download",
            [
                ("ver", "1"), ("client", "pc"), ("id", id),
                ("accesskey", accessKey), ("fmt", "krc"), ("charset", "utf8"),
            ]
        ) else { throw LyricsFetchError.unreachable }

        let data = try await send(url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["status"] as? NSNumber)?.intValue == 200,
              let content = root["content"] as? String, !content.isEmpty
        else { throw LyricsFetchError.unreachable }
        return content
    }

    // MARK: - 私有

    /// 拼一个带查询串的 URL。**参数的编码交给 `URLComponents`**（歌名里常有空格 / 括号 / 中文）。
    private static func url(_ base: String, _ items: [(String, String)]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url
    }

    /// 发一个 `GET`。
    ///
    /// ⚠️ 连不上 / 超时 / 非 2xx 一律算 `.unreachable` —— 对用户是同一件事，
    /// **但绝不能算成"没找到"**。
    private func send(_ url: URL) async throws -> Data {
        var request = URLRequest(
            url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: Self.timeout
        )
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw LyricsFetchError.unreachable }
        return data
    }
}

// MARK: - 搜词候选

/// 搜词返回里的一条 —— 值，零行为。
///
/// ⚠️ **`krctype` 不是「有没有逐字」的开关**：实测 `krctype=1` 与 `=2` 的样本里**都带**字块
/// ⇒ **不许拿它过滤**。它随 `singer` / `song` 一并留着，
/// 只为排查时看得见，**不参与任何判断**。
struct LyricsLyricCandidate: Equatable {

    /// 下载的两把钥匙之一。
    let id: String

    /// 下载的两把钥匙之二。
    let accessKey: String

    /// 候选自带的时长（毫秒）。
    let durationMilliseconds: Int

    /// 官方标记（**不参与判断**）。
    let krcType: Int

    /// 回显的艺人 / 歌名（排查用）。
    let singer: String
    let song: String

    /// 读不出两把钥匙 ⇒ `nil`（这一条下不了，别摆出来骗一次点击）。
    init?(json: [String: Any]) {
        guard let id = Self.text(json["id"]), !id.isEmpty,
              let accessKey = Self.text(json["accesskey"]), !accessKey.isEmpty
        else { return nil }

        self.id = id
        self.accessKey = accessKey
        self.durationMilliseconds = (json["duration"] as? NSNumber)?.intValue ?? 0
        self.krcType = (json["krctype"] as? NSNumber)?.intValue ?? 0
        self.singer = Self.text(json["singer"]) ?? ""
        self.song = Self.text(json["song"]) ?? ""
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

/// 取词失败 —— 页面直接拿它当人话用（与 `PlaylistCoverError` 同一套做法）。
///
/// 🔴 **只有两种**，对应 §B.4 三态里除"找到"之外的两态。
/// 文案必须**不一样**：用户得能分清"这首歌真没有"和"我这会儿上不了网"。
enum LyricsFetchError: LocalizedError {

    /// 服务器明确说没有 —— 搜词 `candidates == []`。
    case notFound

    /// 连不上 / 超时 / `5xx` / `403` 限流 / 响应不成形。
    ///
    /// 🔴 语义上**不是**"这首歌没有词"的证据（`LookupOutcome` 那条纪律）——
    /// 所以文案只说网络，不许暗示"没这首歌的歌词"。
    case unreachable

    /// 人话 —— **非可选那一版**，给页面 / 浮层直接用。
    ///
    /// 页面里要是写成 `error.errorDescription ?? "获取失败"`，那个兜底字符串是**死代码**
    /// （这里永远给值），可它会让人以为"还有第三种没话说的收尾"。
    var message: String {
        switch self {
        case .notFound: return "没找到这首歌的歌词"
        case .unreachable: return "网络不可用，稍后再试"
        }
    }

    var errorDescription: String? { message }
}

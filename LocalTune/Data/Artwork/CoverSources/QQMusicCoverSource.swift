import Foundation

/// QQ音乐的封面源 —— **搜歌 ＋ 取图**。
///
/// ## 搜歌
///
/// `https://c.y.qq.com/soso/fcgi-bin/client_search_cp`，`format=json`。
/// 🔴 **要带 `Referer: https://y.qq.com/`**（实测不带会被挡）——
/// 这个头是**这个源自己的事**，所以它在这里带，不外漏给调用方。
///
/// ## 🔴 封面地址是**拼**出来的，回包里只给 `albummid`
///
/// ```
/// https://y.gtimg.cn/music/photo_new/T002R{size}x{size}M000{albummid}.jpg
/// ```
/// 实测（2026-10-14）：`R300x300` ⇒ 200 / 33,448 字节，`R800x800` ⇒ 200 / 183,730 字节，都是 JPEG。
/// ⚠️ `albummid` 为空 ⇒ 拼不出地址 ⇒ 这一条**不收**（摆出来也是点不动的）。
///
/// ## 年份来自 `pubtime`
///
/// 它是 **Unix 时间戳**（实测 `1059580800` ⇒ 2003 年），不是 `"2003"` 这样的字符串 ——
/// 得换算，不能直接摆上去。
///
/// ## 它不认识的东西
///
/// 不落盘 · 不缓存 · 不碰界面。
final class QQMusicCoverSource: CoverSource {

    let kind: CoverSourceKind = .qqMusic

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 超时定 8 秒 —— 同酷狗：用户正看着的界面，宁可快速失败。
    private static let timeout: TimeInterval = 8

    private static let userAgent = "LocalTune/iOS"

    /// 那边认这个来源 —— 不带会被挡（实测）。
    private static let referer = "https://y.qq.com/"

    /// 列表那一小格要的尺寸档。
    private static let thumbnailSize = 300

    /// 挑中之后要的尺寸档。
    private static let coverSize = 800

    // MARK: - 搜

    func search(_ keyword: String) async throws -> [CoverCandidate] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CoverSearchError.notFound }

        guard let url = Self.url(
            "https://c.y.qq.com/soso/fcgi-bin/client_search_cp",
            [
                ("format", "json"), ("p", "1"), ("n", "20"), ("w", trimmed),
            ]
        ) else { throw CoverSearchError.unreachable }

        let data = try await send(url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let song = payload["song"] as? [String: Any],
              let list = song["list"] as? [[String: Any]]
        else { throw CoverSearchError.unreachable }

        var results: [CoverCandidate] = []
        var seen = Set<String>()
        for item in list {
            guard let candidate = Self.candidate(from: item) else { continue }
            // 🔴 同源内去重（同一个 `albummid` 的同名曲会出现多次）—— 跨源不合并。
            guard seen.insert(candidate.id).inserted else { continue }
            results.append(candidate)
        }
        guard !results.isEmpty else { throw CoverSearchError.notFound }
        return results
    }

    // MARK: - 取图

    func imageData(from url: URL) async throws -> Data {
        try await send(url)
    }

    // MARK: - 私有 · 读一条

    /// 搜歌返回里的一条（`data.song.list[]` 的一条）→ 候选。
    private static func candidate(from item: [String: Any]) -> CoverCandidate? {
        guard let title = text(item["songname"]), !title.isEmpty else { return nil }
        guard let albumMid = text(item["albummid"]), !albumMid.isEmpty else { return nil }
        guard let thumbnail = coverURL(albumMid: albumMid, size: thumbnailSize),
              let cover = coverURL(albumMid: albumMid, size: coverSize)
        else { return nil }

        let singers = (item["singer"] as? [[String: Any]])?
            .compactMap { text($0["name"]) }
            .filter { !$0.isEmpty } ?? []

        return CoverCandidate(
            source: .qqMusic,
            title: title,
            artist: singers.joined(separator: "、"),
            album: text(item["albumname"]) ?? "",
            year: year(fromUnixSeconds: item["pubtime"]),
            thumbnailURL: thumbnail,
            coverURL: cover
        )
    }

    /// 拼封面地址 —— 尺寸直接写进文件名（`T002R300x300M000…`）。
    private static func coverURL(albumMid: String, size: Int) -> URL? {
        URL(string: "https://y.gtimg.cn/music/photo_new/T002R\(size)x\(size)M000\(albumMid).jpg")
    }

    /// `pubtime`（Unix 秒）→ 年份。
    ///
    /// ⚠️ **固定按 UTC 算**：回包里存的就是 UTC 秒，跟着本机时区走会在跨年那几个小时差一年
    /// （实测 `1059580800` 按 UTC 是 2003-07-31，按东八区也是 2003，但边界上就不一定了）。
    private static func year(fromUnixSeconds value: Any?) -> Int? {
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.component(.year, from: Date(timeIntervalSince1970: seconds))
    }

    // MARK: - 私有 · 网络

    /// 拼一个带查询串的 URL。**参数的编码交给 `URLComponents`**（歌名里常有空格 / 括号 / 中文）。
    private static func url(_ base: String, _ items: [(String, String)]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url
    }

    /// 发一个 `GET`（带上那边要的 `Referer`）。
    private func send(_ url: URL) async throws -> Data {
        var request = URLRequest(
            url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: Self.timeout
        )
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.referer, forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw CoverSearchError.unreachable }
        return data
    }

    /// 把回包里的值读成字符串（数字也认）。
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

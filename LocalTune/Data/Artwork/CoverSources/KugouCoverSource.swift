import Foundation

/// 酷狗的封面源 —— **搜歌 ＋ 取图**，就这两件事。
///
/// ## 搜歌：跟取词那边**同一个接口**，但各写一份
///
/// `https://mobiles.kugou.com/api/v3/search/song`，成功判据 `status == 1`。
/// ⚠️ 域名是**有意偏离**网上流传最广的那条 `mobilecdn.kugou.com`（那台只有 HTTP，
/// 用它就得给 `Info.plist` 开 ATS 例外）—— 这里用 `mobiles.kugou.com`，全 HTTPS
/// ⇒ `Info.plist` 一个字不用动。
///
/// ## 🔴 封面在 `trans_param.union_cover`，而且里面**字面写着 `{size}`**
///
/// 实测（2026-10-14）：
/// ```
/// http://imge.kugou.com/stdmusic/{size}/20230920/20230920142503632013.jpg
/// ```
/// ⇒ 把 `{size}` 换成 `240` / `480` 就行，**不用猜尺寸段在第几段**。
/// （实测 `240` ⇒ 200 / 29,970 字节，`480` ⇒ 200 / 97,730 字节，都是 JPEG。）
///
/// ## 🔴 必须挡掉「歌手头像」
///
/// 同一个字段里，**没有专辑信息**的那些条目给的是**歌手头像**：
/// ```
/// http://singerimg.kugou.com/uploadpic/softhead/{size}/20260324/….jpg
/// ```
/// 拿它当封面存下去，用户看到的就是一张头像 —— 所以 `host` 是 `singerimg.kugou.com`、
/// 或路径里有 `softhead` 的，一律**不收**（这一条是实测撞出来的，不是假想）。
///
/// ## 它不认识的东西
///
/// 不解析年份（**那边回包里没有这个字段**，不编）· 不落盘 · 不缓存 · 不碰界面。
final class KugouCoverSource: CoverSource {

    let kind: CoverSourceKind = .kugou

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 超时定 8 秒（沿旧）：这不是后台任务，是**用户正看着的界面** ——
    /// 宁可快速失败给个提示，也不要长时间转圈。
    private static let timeout: TimeInterval = 8

    private static let userAgent = "LocalTune/iOS"

    /// 列表那一小格要的尺寸档。
    private static let thumbnailSize = 240

    /// 挑中之后要的尺寸档。
    private static let coverSize = 480

    // MARK: - 搜

    func search(_ keyword: String) async throws -> [CoverCandidate] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CoverSearchError.notFound }

        guard let url = Self.url(
            "https://mobiles.kugou.com/api/v3/search/song",
            [
                ("format", "json"), ("keyword", trimmed), ("page", "1"),
                ("pagesize", "20"), ("showtype", "1"),
            ]
        ) else { throw CoverSearchError.unreachable }

        let data = try await send(url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["status"] as? NSNumber)?.intValue == 1,
              let payload = root["data"] as? [String: Any],
              let info = payload["info"] as? [[String: Any]]
        else { throw CoverSearchError.unreachable }

        var results: [CoverCandidate] = []
        var seen = Set<String>()
        for item in info {
            // ⚠️ 读不出图 / 歌名 / 是歌手头像的条目**直接跳过**，不摆一条点了没用的行。
            guard let candidate = Self.candidate(from: item) else { continue }
            // 🔴 **同一个源自己**会返回重复条目（同一首的多个版本各占一条）⇒ 按 `id` 收一遍。
            // （跨源不合并 —— 见 `CoverCandidate.id` 上那段。）
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

    /// 搜歌返回里的一条（`data.info[]` 的一条）→ 候选。
    ///
    /// 读不出**歌名**或**封面** ⇒ `nil`（宁可不显示，也不显示一条点不动的）。
    private static func candidate(from item: [String: Any]) -> CoverCandidate? {
        guard let title = text(item["songname"]), !title.isEmpty else { return nil }

        guard let trans = item["trans_param"] as? [String: Any],
              let raw = text(trans["union_cover"]), !raw.isEmpty,
              !isArtistHeadshot(raw)
        else { return nil }

        guard let thumbnail = coverURL(raw, size: thumbnailSize),
              let cover = coverURL(raw, size: coverSize)
        else { return nil }

        return CoverCandidate(
            source: .kugou,
            title: title,
            // 酷狗用 `、` 分隔合唱艺人 —— 原样留着，显示时就是那个样子，不必拆了再拼。
            artist: text(item["singername"]) ?? "",
            album: text(item["album_name"]) ?? "",
            // ⚠️ 酷狗搜索回包里**没有年份**这一项 ⇒ 老老实实 `nil`，不拿别的字段凑。
            year: nil,
            thumbnailURL: thumbnail,
            coverURL: cover
        )
    }

    /// 这一串 `union_cover` 是不是**歌手头像**。
    ///
    /// 判据两条（都是实测见过的形态，不是猜）：
    /// - `host` 是 `singerimg.kugou.com`（专辑封面在 `imge.kugou.com`）；
    /// - 路径里有 `/softhead/`（"soft head" ＝ 艺人头像那套命名）。
    private static func isArtistHeadshot(_ raw: String) -> Bool {
        raw.contains("singerimg.kugou.com") || raw.contains("/softhead/")
    }

    /// 把回包里那份模板填成真地址。
    ///
    /// 🔴 **必须换成 `https`**：明文 `http` 会被 ATS 直接挡掉，而这两个域实测都支持 https。
    private static func coverURL(_ raw: String, size: Int) -> URL? {
        let filled = raw.replacingOccurrences(of: "{size}", with: String(size))
        let secured = filled.replacingOccurrences(of: "http://", with: "https://")
        guard secured.hasPrefix("https://") else { return nil }
        return URL(string: secured)
    }

    // MARK: - 私有 · 网络

    /// 拼一个带查询串的 URL。**参数的编码交给 `URLComponents`**（歌名里常有空格 / 括号 / 中文）。
    private static func url(_ base: String, _ items: [(String, String)]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url
    }

    /// 发一个 `GET`。
    ///
    /// ⚠️ 连不上 / 超时 / 非 2xx 一律算 `.unreachable` —— 对用户是同一件事，
    /// **但绝不能算成"没搜到"**。
    private func send(_ url: URL) async throws -> Data {
        var request = URLRequest(
            url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: Self.timeout
        )
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

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

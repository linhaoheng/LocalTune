import Foundation

/// 源客户端的错误 —— 与取词页的「找到 / 没找到 / 连不上」三分对齐。
enum LyricsSourceError: Error, Equatable {
    case notFound
    case unreachable
}

/// 一次取词请求要带上的曲目信息。
struct LyricsSourceQuery {
    let keyword: String
    let title: String
    let artists: [String]
    let album: String
    let durationSeconds: Int
}

/// 跑一个用户导入的源：搜歌 / 取词 —— **执行链照 primuse**：
///
/// - 两个端点各发一次请求，响应交给该端点的 `script`，按固定键取值；
/// - 取词脚本可以返回 `_fetchEncryptedLyrics`，此时按 `secrets` 里的
///   `lyricsFetchUrl` / `lyricsContentField` / `lyricsMagicHex` / `lyricsXorKeyHex`
///   去拉密文（最多 5 个候选，取解出来最长的那份）。
///
/// 只认 **HTTPS**、只打用户配置里的 host；不绕 TLS、不跟随到 http。
///
/// ## 三态怎么分
///
/// - 脚本抛异常 / 请求发不出去 / 超时 / 非 2xx / 解码失败 ⇒ `unreachable`；
/// - 服务器明确说没有（脚本返回 `null` / 空候选 / 空正文）⇒ `notFound`。
final class LyricsSourceClient {

    private let config: LyricsSourceConfig
    private let session: URLSession
    private let limiter = RateLimiter()

    /// 响应体上限（字节）—— 与 primuse 同档（它的源会返回整份列表/大 JSON）。
    private static let searchMaxBytes = 5 * 1024 * 1024
    private static let lyricsMaxBytes = 5 * 1024 * 1024
    /// 搜歌一次要几条（`{{limit}}`）。
    private static let searchLimit = 20
    /// 密文歌词最多试几个候选。
    private static let encryptedCandidateLimit = 5
    /// 少于等于这个行数算「残缺版」，继续试下一个候选。
    private static let fragmentLineCount = 4

    /// 全进程共用的 session。
    ///
    /// 🔴 **不能每次打开取词页都新建一条**：那等于把 DNS / TCP / TLS 全部重来，
    /// 每次开页都冷启动（备份那版用 `URLSession.shared` 正是为了复用）。
    /// `ephemeral` 只把缓存放内存，不落磁盘；缓存策略交给服务端（`useProtocolCachePolicy`），
    /// 同一份搜索 / 同一份歌词再点一次直接命中。
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpAdditionalHeaders = ["User-Agent": "LocalTune/iOS"]
        return URLSession(configuration: configuration)
    }()

    init(config: LyricsSourceConfig, session: URLSession? = nil) {
        self.config = config
        self.session = session ?? Self.sharedSession
    }

    // MARK: - 搜歌 / 取词

    func search(_ query: LyricsSourceQuery) async throws -> [LyricsSourceCandidate] {
        guard let endpoint = config.search else { throw LyricsSourceError.unreachable }
        let values = [
            "query": query.keyword,
            "limit": String(Self.searchLimit),
            "artist": query.artists.joined(separator: "、"),
            "album": query.album,
        ]
        let result = try await runScript(
            endpoint,
            values: values,
            maxBytes: Self.searchMaxBytes,
            externalId: nil
        )
        let candidates = LyricsSourceMappingPolicy.candidates(from: result ?? [Any]())
        guard !candidates.isEmpty else { throw LyricsSourceError.notFound }
        return candidates
    }

    func lyrics(for candidate: LyricsSourceCandidate) async throws -> String {
        guard let endpoint = config.lyrics else { throw LyricsSourceError.unreachable }
        let result = try await runScript(
            endpoint,
            values: ["id": candidate.id],
            maxBytes: Self.lyricsMaxBytes,
            externalId: candidate.id
        )
        let raw: String
        switch LyricsSourceMappingPolicy.payload(from: result ?? [String: Any]()) {
        case let .text(text):
            raw = text
        case let .encrypted(vars):
            raw = try await encryptedText(vars: vars)
        case nil:
            throw LyricsSourceError.notFound
        }
        // 🔴 **清洗在 `checked` 之前**：词表配错把整份删光时，这里会按「没找到」报错，
        //    不会往库里存一份空歌词。明文 / 密文两条路都在这一处过规则。
        return try checked(LyricsRuleEngine.apply(config.rules, to: raw))
    }

    // MARK: - 密文歌词

    /// 脚本说「去下载」之后的那一步：模板变量全来自脚本的 `vars`，密钥全来自 `secrets`。
    ///
    /// 单条失败（404 / 字段缺 / 解不开）跳过，换下一个候选；**全都失败**才算「连不上」——
    /// 脚本只有在确实找到候选时才返回这个标记，到这一步再失败就不是「这首歌没词」了。
    private func encryptedText(vars: [[String: String]]) async throws -> String {
        guard let secrets = config.secrets,
              let template = secrets["lyricsFetchUrl"], !template.isEmpty,
              let contentField = secrets["lyricsContentField"], !contentField.isEmpty,
              let magicHex = secrets["lyricsMagicHex"], !magicHex.isEmpty,
              let xorKeyHex = secrets["lyricsXorKeyHex"], !xorKeyHex.isEmpty else {
            throw LyricsSourceError.unreachable
        }

        var best: String?
        for candidate in vars.prefix(Self.encryptedCandidateLimit) {
            let text = try await encryptedCandidate(
                candidate,
                template: template,
                contentField: contentField,
                magicHex: magicHex,
                xorKeyHex: xorKeyHex
            )
            guard let text else { continue }
            if text.count > (best?.count ?? 0) { best = text }
            // 多候选是为了躲「4 行残缺版」（primuse 的原话）。已经超过 4 行就收工 ——
            // 5 个候选串行下载在真机上就是好几秒，正常源第一次就够。
            if nonEmptyLineCount(of: text) > Self.fragmentLineCount { break }
        }
        guard let best else { throw LyricsSourceError.unreachable }
        // 不在这儿 `checked` —— 调用方 `lyrics(for:)` 统一做「清洗 → 判空」。
        return best
    }

    private func encryptedCandidate(
        _ vars: [String: String],
        template: String,
        contentField: String,
        magicHex: String,
        xorKeyHex: String
    ) async throws -> String? {
        await limiter.wait(milliseconds: config.rateLimit ?? 300)

        let rendered = LyricsSourceTemplatePolicy.renderURL(template, values: vars)
        guard let url = URL(string: rendered),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              LyricsSourceHostPolicy.isAllowed(host) else {
            throw LyricsSourceError.unreachable
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        applyHeaders(to: &request, endpoint: nil)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LyricsSourceError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw LyricsSourceError.unreachable }
        // 这一条没内容 ≠ 连不上：404 也算"这条没有"，交给下一个候选。
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw LyricsSourceError.unreachable }
        guard data.count <= Self.lyricsMaxBytes else { throw LyricsSourceError.unreachable }
        guard LyricsSourceHostPolicy.isAllowedURL(http.url) else { throw LyricsSourceError.unreachable }

        // 解析失败 / 字段缺 = 这一条没内容，交给下一个候选；全都没才判「连不上」。
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json[contentField] as? String else { return nil }
        return LyricsBinaryDecoder.decode(base64: content, magicHex: magicHex, xorKeyHex: xorKeyHex)
    }

    /// 正文空 ⇒ 服务器没给东西，算「没找到」。
    private func checked(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LyricsSourceError.notFound
        }
        return text
    }

    // MARK: - 请求

    /// 发一次请求 → 交给端点脚本。脚本缺 / 不是 UTF-8 / 抛异常 ⇒ 连不上。
    private func runScript(
        _ endpoint: LyricsSourceConfig.Endpoint,
        values: [String: String],
        maxBytes: Int,
        externalId: String?
    ) async throws -> Any? {
        let data = try await fetchData(endpoint, values: values, maxBytes: maxBytes)
        guard let script = endpoint.script, !script.isEmpty else { throw LyricsSourceError.unreachable }
        guard let text = String(data: data, encoding: .utf8) else { throw LyricsSourceError.unreachable }
        do {
            return try LyricsSourceScriptRunner.run(
                script: script,
                responseText: text,
                secrets: config.secrets,
                externalId: externalId,
                gateKey: config.id
            )
        } catch {
            throw LyricsSourceError.unreachable
        }
    }

    private func fetchData(
        _ endpoint: LyricsSourceConfig.Endpoint,
        values: [String: String],
        maxBytes: Int
    ) async throws -> Data {
        await limiter.wait(milliseconds: config.rateLimit ?? 300)

        let request: URLRequest
        do {
            request = try makeRequest(endpoint, values: values)
        } catch {
            throw LyricsSourceError.unreachable
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LyricsSourceError.unreachable
        }

        guard let http = response as? HTTPURLResponse else { throw LyricsSourceError.unreachable }
        if http.statusCode == 404 { throw LyricsSourceError.notFound }
        guard (200..<300).contains(http.statusCode) else { throw LyricsSourceError.unreachable }
        guard data.count <= maxBytes else { throw LyricsSourceError.unreachable }
        guard LyricsSourceHostPolicy.isAllowedURL(http.url) else { throw LyricsSourceError.unreachable }
        return data
    }

    private func makeRequest(
        _ endpoint: LyricsSourceConfig.Endpoint,
        values: [String: String]
    ) throws -> URLRequest {
        let rendered = LyricsSourceTemplatePolicy.renderURL(endpoint.url, values: values)
        guard let url = URL(string: rendered),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              LyricsSourceHostPolicy.isAllowed(host) else {
            throw LyricsSourceError.unreachable
        }

        let method = endpoint.method.uppercased()
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if method == "GET", let params = endpoint.params {
            var items = components?.queryItems ?? []
            for (key, value) in params {
                items.append(URLQueryItem(
                    name: key,
                    value: LyricsSourceTemplatePolicy.renderPlain(value, values: values)
                ))
            }
            components?.queryItems = items
        }
        guard let finalURL = components?.url else { throw LyricsSourceError.unreachable }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.timeoutInterval = 8
        if method == "POST" {
            if let body = try body(for: endpoint, values: values) {
                request.httpBody = body
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        }
        applyHeaders(to: &request, endpoint: endpoint)
        return request
    }

    /// POST 体：`bodyTemplate` 优先（按 JSON 字符串转义），否则把 `params` 拼成 JSON 对象。
    private func body(
        for endpoint: LyricsSourceConfig.Endpoint,
        values: [String: String]
    ) throws -> Data? {
        if let template = endpoint.bodyTemplate {
            return LyricsSourceTemplatePolicy.renderJSON(template, values: values)
                .data(using: .utf8)
        }
        guard let params = endpoint.params, !params.isEmpty else { return nil }
        var rendered: [String: String] = [:]
        for (key, value) in params {
            rendered[key] = LyricsSourceTemplatePolicy.renderPlain(value, values: values)
        }
        do {
            return try JSONSerialization.data(withJSONObject: rendered)
        } catch {
            throw LyricsSourceError.unreachable
        }
    }

    private func applyHeaders(
        to request: inout URLRequest,
        endpoint: LyricsSourceConfig.Endpoint?
    ) {
        for (field, value) in config.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        for (field, value) in endpoint?.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let cookie = config.cookie, !cookie.isEmpty,
           request.value(forHTTPHeaderField: "Cookie") == nil {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
    }
}

/// 拒绝 `localhost` / `.local` / 私有地址字面量（防 SSRF）。
///
/// ⚠️ 不做 DNS 解析后的二次校验 —— 域名解析到内网仍可能绕过；这是 v1 的已知边界。
enum LyricsSourceHostPolicy {

    /// 重定向之后**协议和主机都要再查一遍** —— 只查协议挡不住「https 302 到内网 https」。
    static func isAllowedURL(_ url: URL?) -> Bool {
        guard let url else { return true }
        guard url.scheme?.lowercased() == "https",
              let host = url.host else { return false }
        return isAllowed(host)
    }

    static func isAllowed(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".local") { return false }
        // 只有 IPv6 才做前缀判断；不带冒号的 `fc2.com` / `fdroid.org` 是正常域名。
        if lower.contains(":"),
           lower == "::1" || lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd") {
            return false
        }

        let parts = lower.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        let first = parts[0]
        let second = parts[1]
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 168 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 198 && (18...19).contains(second) { return false }
        return true
    }
}

/// 非空行数 —— 只用来判「这份密文歌词像不像残缺版」。
private func nonEmptyLineCount(of text: String) -> Int {
    text
        .components(separatedBy: .newlines)
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .count
}

/// 同一个源的两次请求之间至少隔 `rateLimit` 毫秒。
private actor RateLimiter {
    private var nextAllowed: Date = .distantPast

    func wait(milliseconds: Int) async {
        guard milliseconds > 0 else { return }
        let now = Date()
        let target = max(now, nextAllowed)
        nextAllowed = target.addingTimeInterval(Double(milliseconds) / 1000)
        let delay = min(target.timeIntervalSince(now), 60)
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}

import Foundation

/// 导入前预览的那一份摘要 —— **纯数据，不画界面**。
///
/// 字段一项对一项照 primuse 的 `ScraperImportSummary`：源 / 配置 / 能力 / 请求 /
/// 网络域名 / 四个"它会做什么"的开关 / 警告。
///
/// 🔴 放在 `Data/` 不放在页面里：这是**算出来的事实**（哪几个主机、带不带密钥、会发什么请求），
/// 页面只负责摆。摆法要改时不该碰这里，这里要改时也不该碰页面。
struct LyricsSourceImportSummary {

    /// 「源」：从哪个地址下回来的，或者「粘贴的 JSON」。
    let sourceDescription: String

    /// 「配置」：`名称 (id)`。
    let configLine: String

    /// 「能力」：`lyrics、lyricsWordLevel`。
    let capabilitiesLine: String

    /// 「请求」：`2 个端点，GET, POST`。
    let requestsLine: String

    /// 「网络域名」：配置会连到的主机，**排序后**给（照 primuse 的 `.sorted()`）。
    let domains: [String]

    /// 带没带全局请求头 / Cookie / 密钥 / JavaScript —— 四个勾。
    let includesHeaders: Bool
    let includesCookie: Bool
    let includesSecrets: Bool
    let includesJavaScript: Bool

    /// 橘黄色那几行：这个源"能做到、但用户可能没料到"的事。
    let warnings: [String]
}

extension LyricsSourceImportSummary {

    /// - Parameter sourceHost: 配置是从哪个地址下回来的；**粘贴**进来的给 `nil`。
    init(config: LyricsSourceConfig, sourceHost: String?) {
        sourceDescription = sourceHost ?? "粘贴的 JSON"
        configLine = "\(config.name) (\(config.id))"
        capabilitiesLine = config.capabilities.isEmpty
            ? "未知"
            : config.capabilities.joined(separator: "、")

        let endpoints = [config.search, config.lyrics].compactMap { $0 }
        // 🔴 **方法名先去重再排**（照 primuse 的 `Array(Set(methods)).sorted()`）：
        // 两个端点都是 GET 时写 `GET`，不是 `GET, GET` —— 这里说的是"会发哪几种请求"，
        // 不是"每个端点各发什么"。端点数另算。
        let methods = Set(endpoints.map { $0.method.uppercased() }).sorted()
        requestsLine = endpoints.isEmpty
            ? "无"
            : "\(endpoints.count) 个端点，\(methods.joined(separator: ", "))"

        // 域名不只从 `url` 来：脚本和请求体里**写死的地址**一样会连出去
        // —— 三处都扫（照 primuse 的 `hosts(in:)`）。
        var found: Set<String> = []
        for endpoint in endpoints {
            for text in [endpoint.url, endpoint.bodyTemplate ?? "", endpoint.script ?? ""] {
                for host in Self.hosts(in: text) { found.insert(host) }
            }
        }
        domains = found.sorted()

        includesHeaders = !(config.headers?.isEmpty ?? true)
            || endpoints.contains { !($0.headers?.isEmpty ?? true) }
        includesCookie = !(config.cookie?.isEmpty ?? true)
            || Self.headersContainCookie(config.headers)
            || endpoints.contains { Self.headersContainCookie($0.headers) }
        includesSecrets = !(config.secrets?.isEmpty ?? true)
        includesJavaScript = endpoints.contains { !($0.script ?? "").isEmpty }

        // 🔴 顺序照 primuse：没域名 → Cookie / 自定义请求头（二选一）→ 密钥 → 非 GET → 脚本过大。
        var notes: [String] = []
        if found.isEmpty {
            notes.append("未检测到固定的网络域名。该歌词源可能在 JavaScript 中动态生成 URL。")
        }
        if includesCookie {
            notes.append("此配置包含 Cookie 数据。请仅导入来自可信来源的配置。")
        } else if includesHeaders {
            notes.append("此配置会添加自定义请求头。")
        }
        if includesSecrets {
            notes.append("此配置包含本地密钥。它们将被单独存储，不会作为公开配置 JSON 同步。")
        }
        if methods.contains(where: { $0 != "GET" }) {
            notes.append("此歌词源可发送非 GET 请求。")
        }
        if endpoints.contains(where: { ($0.script ?? "").count > LyricsSourceConfig.maxScriptLength }) {
            notes.append("一个或多个脚本超出运行时大小限制，可能无法运行。")
        }
        warnings = notes
    }

    // MARK: - 私有

    /// 从一段文本里扫出所有 `http(s)://` 的主机（照 primuse 的正则）。
    private static func hosts(in text: String) -> [String] {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"(?i)\bhttps?://[^\s"'<>)}\]]+"#)
        else { return [] }
        let source = text as NSString
        return regex
            .matches(in: text, range: NSRange(location: 0, length: source.length))
            .compactMap { match in
                let raw = source.substring(with: match.range)
                guard let host = URL(string: raw)?.host, !host.isEmpty else { return nil }
                return host.lowercased()
            }
    }

    /// 请求头里有没有 `Cookie` 这一项（大小写不敏感）—— 有就等于带 Cookie。
    private static func headersContainCookie(_ headers: [String: String]?) -> Bool {
        guard let headers else { return false }
        return headers.keys.contains { $0.caseInsensitiveCompare("cookie") == .orderedSame }
    }
}

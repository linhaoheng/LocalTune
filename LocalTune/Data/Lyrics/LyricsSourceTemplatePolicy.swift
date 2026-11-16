import Foundation

/// 把 `{{键}}` / `{{键[序号]}}` 换成值 —— **纯函数**（照 primuse 的模板约定）。
///
/// - `{{键}}`：整体替换；
/// - `{{键[序号]}}`：把值按 `|` 切开取第 N 段（0 起，越界给空串）——
///   有些源的 `externalId` 是 `hash|albumId|歌名|歌手|时长` 拼的，靠它精确取字段；
/// - 同一处模板三种转义：URL、JSON 体、原样。
enum LyricsSourceTemplatePolicy {

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// URL 模板（路径 / 查询串）：只留 RFC 3986 非保留字符。
    static func renderURL(_ template: String, values: [String: String]) -> String {
        applying(template, values: values) { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
    }

    /// JSON 体模板：按 JSON 字符串内容转义（外面那对引号由配置自己写）。
    static func renderJSON(_ template: String, values: [String: String]) -> String {
        applying(template, values: values) { jsonEscaped($0) }
    }

    /// 参数值 / 头里的模板：原样替换，编码交给下游（`URLComponents` / `JSONSerialization`）。
    static func renderPlain(_ template: String, values: [String: String]) -> String {
        applying(template, values: values) { $0 }
    }

    // MARK: - 私有

    /// 先处理带序号的，再处理整体的 —— 顺序照 primuse（带序号的模板里还嵌着整体占位）。
    private static func applying(
        _ template: String,
        values: [String: String],
        transform: (String) -> String
    ) -> String {
        var result = template
        if let regex = try? NSRegularExpression(pattern: #"\{\{(\w+)\[(\d+)\]\}\}"#) {
            // 替换值本身可能又长得像占位符（例如某个 id 就叫 `{{id[0]}}`），加迭代上限防死循环。
            var iterations = 0
            while iterations < 256 {
                iterations += 1
                let text = result as NSString
                let range = NSRange(location: 0, length: text.length)
                guard let match = regex.firstMatch(in: result, range: range),
                      match.numberOfRanges >= 3 else { break }
                let key = text.substring(with: match.range(at: 1))
                let index = Int(text.substring(with: match.range(at: 2))) ?? 0
                let parts = (values[key] ?? "")
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map(String.init)
                let value = parts.indices.contains(index) ? parts[index] : ""
                result = text.replacingCharacters(in: match.range, with: transform(value))
            }
        }
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: transform(value))
        }
        return result
    }

    /// `String` 的 JSON 编码不会失败；万一失败只交空串，由调用方按"这个变量没值"处理。
    private static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else { return "" }
        return String(encoded.dropFirst().dropLast())
    }
}

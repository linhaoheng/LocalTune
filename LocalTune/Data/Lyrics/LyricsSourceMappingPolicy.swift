import Foundation

/// 一个候选（搜歌结果里的一条）—— 与具体站点无关。
struct LyricsSourceCandidate: Equatable {
    let id: String
    let title: String
    let artists: [String]
    let album: String
    let durationSeconds: Int

    /// 列表副行：`艺人 · 专辑 · 时长`（缺哪个省哪个）。
    var subtitle: String {
        var parts: [String] = []
        let joined = artists.filter { !$0.isEmpty }.joined(separator: "、")
        if !joined.isEmpty { parts.append(joined) }
        if !album.isEmpty { parts.append(album) }
        if durationSeconds > 0 {
            parts.append(String(format: "%d:%02d", durationSeconds / 60, durationSeconds % 60))
        }
        return parts.joined(separator: " · ")
    }
}

/// 一次取词的产物：要么直接给正文，要么给"去下载密文"的变量。
enum LyricsSourcePayload: Equatable {
    case text(String)
    /// 每项是一组模板变量（来自脚本的 `vars`）；客户端按 `secrets` 里的 URL 去拉密文。
    case encrypted([[String: String]])
}

/// 脚本返回值 → 我们的值。**键名照 primuse**，不另立一套。
///
/// - 搜歌：数组，元素取 `id` / `title` / `artist` / `album` / `durationMs`；
/// - 取词：对象，取 `wordLevelLrc` / `lrcContent` / `plainText`，
///   或者用 `_fetchEncryptedLyrics: true` ＋ `vars` 走密文下载。
enum LyricsSourceMappingPolicy {

    /// 搜歌脚本的返回值 → 候选列表；`id` / `title` 缺一的那条跳过。
    static func candidates(from value: Any) -> [LyricsSourceCandidate] {
        guard let items = value as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            guard let id = string(item["id"]),
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let title = string(item["title"]),
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }

            let milliseconds = number(item["durationMs"]) ?? 0
            return LyricsSourceCandidate(
                id: id,
                title: title,
                artists: artists(from: item["artist"]),
                album: string(item["album"]) ?? "",
                durationSeconds: milliseconds > 0
                    ? Int((Double(milliseconds) / TimeUnit.millisecondsPerSecond).rounded())
                    : 0
            )
        }
    }

    /// 取词脚本的返回值 → 正文 / 密文变量；`nil` ＝ 脚本说「这次没有」。
    static func payload(from value: Any) -> LyricsSourcePayload? {
        guard let dictionary = value as? [String: Any] else { return nil }

        if let flag = dictionary["_fetchEncryptedLyrics"] as? Bool, flag {
            guard let list = encryptedVars(from: dictionary["vars"]), !list.isEmpty else {
                return nil
            }
            return .encrypted(list)
        }

        for key in ["wordLevelLrc", "lrcContent", "plainText"] {
            guard let text = string(dictionary[key]),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return .text(text)
        }
        return nil
    }

    // MARK: - 私有

    private static func encryptedVars(from raw: Any?) -> [[String: String]]? {
        if let list = raw as? [[String: Any]] {
            return list.map { entry in
                var vars: [String: String] = [:]
                for (key, value) in entry {
                    vars[key] = string(value) ?? ""
                }
                return vars
            }
        }
        if let single = raw as? [String: Any] {
            var vars: [String: String] = [:]
            for (key, value) in single {
                vars[key] = string(value) ?? ""
            }
            return [vars]
        }
        return nil
    }

    /// 只认字符串和数字 —— 服务端把 id 写成数字很常见。
    private static func string(_ raw: Any?) -> String? {
        switch raw {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func number(_ raw: Any?) -> Int? {
        switch raw {
        case let number as NSNumber:
            return number.intValue
        case let text as String:
            return Int(text)
        default:
            return nil
        }
    }

    private static func artists(from raw: Any?) -> [String] {
        if let list = raw as? [String] {
            return list.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        guard let text = raw as? String else { return [] }
        return text
            .split { $0 == "、" || $0 == "," || $0 == "/" || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

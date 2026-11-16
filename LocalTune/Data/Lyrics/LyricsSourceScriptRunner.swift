import CryptoKit
import Foundation
import JavaScriptCore

/// 跑配置里的 `script` —— **契约照 primuse**：
///
/// - 全局：`responseText`（原文）、`response`（解析后的 JSON）、`externalId`、
///   `secrets`、`log`、`nativeResolver.xorMd5UrlHash`、`nativeCoverUrl`；
/// - 脚本被包成 `(function(){ … })()` 求值，**要显式 `return`**（最后一个表达式不自动返回）；
/// - 返回 `undefined/null` ⇒ `nil`；**抛异常 / 语法错 ⇒ `RunError.failed`**。
///
/// ⚠️ 只做数据变换：不暴露网络 / 文件 API；限长 200KB、限时 4s（同 primuse）。
/// 同一个源同时只跑一条脚本；超时后**隔离它**，后续请求直接 `busy`（JSC 没有中断 API）。
enum LyricsSourceScriptRunner {

    enum RunError: Error, Equatable {
        case tooLong
        case timedOut
        /// 这个源已经有一条脚本在跑（或超时后被隔离）。
        case busy
        case failed
    }

    static let timeout: TimeInterval = 4

    /// 每个源同时只允许一条脚本；超时后**隔离它**，后续请求快速失败。
    ///
    /// 🔴 JavaScriptCore 没有可用的中断 API：超时只能「不等了」，那条线程还在转。
    /// 不隔离的话，用户每点一次重试就多烧一个核（primuse 的 `ScriptExecutionGate` 同理）。
    private static let gate = Gate()

    static func run(
        script: String,
        responseText: String,
        secrets: [String: String]?,
        externalId: String?,
        gateKey: String? = nil
    ) throws -> Any? {
        guard script.count <= LyricsSourceConfig.maxScriptLength else { throw RunError.tooLong }
        if let gateKey, !gate.begin(gateKey) { throw RunError.busy }

        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.set(Result {
                try evaluate(
                    script: script,
                    responseText: responseText,
                    secrets: secrets,
                    externalId: externalId
                )
            })
            semaphore.signal()
        }
        thread.stackSize = 4 * 1024 * 1024
        thread.name = "LocalTune.LyricsSourceScript"
        thread.start()

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            if let gateKey { gate.quarantine(gateKey) }
            throw RunError.timedOut
        }
        if let gateKey { gate.finish(gateKey) }
        guard let result = box.result else { throw RunError.failed }
        return try result.get()
    }

    // MARK: - 私有

    private static func evaluate(
        script: String,
        responseText: String,
        secrets: [String: String]?,
        externalId: String?
    ) throws -> Any? {
        guard let context = JSContext() else { throw RunError.failed }

        // 🔴 异常要**变成错误往外抛**，不能被吞掉。
        //    设了 handler 之后 `evaluateScript` 只返回 `undefined`（不是 nil），
        //    若这里不记这笔账，脚本的「连不上」会被兜成空对象 ⇒ 误报「没找到」。
        let exceptions = ExceptionFlag()
        context.exceptionHandler = { _, _ in exceptions.raise() }

        let log: @convention(block) (String) -> Void = { _ in }
        context.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(responseText, forKeyedSubscript: "responseText" as NSString)
        if let secrets, !secrets.isEmpty {
            context.setObject(secrets, forKeyedSubscript: "secrets" as NSString)
        }
        installNativeResolvers(in: context, secrets: secrets)
        if let externalId {
            context.setObject(externalId, forKeyedSubscript: "externalId" as NSString)
        }

        var parsed = jsonObject(from: Data(responseText.utf8))
        if let externalId, var dictionary = parsed as? [String: Any] {
            dictionary["_externalId"] = externalId
            parsed = dictionary
        }
        context.setObject(parsed ?? [String: Any](), forKeyedSubscript: "response" as NSString)

        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrapped = trimmed.hasPrefix("(") ? script : "(function() { \(script) })()"
        guard let value = context.evaluateScript(wrapped) else { throw RunError.failed }
        if exceptions.raised { throw RunError.failed }
        if value.isUndefined || value.isNull { return nil }
        return value.toObject()
    }

    // MARK: - JS 侧助手

    /// `nativeResolver.xorMd5UrlHash` / `nativeCoverUrl` —— 与 primuse 同名的两个助手。
    ///
    /// 它们只做通用算法（XOR → MD5 → URL-safe base64 → 套模板），
    /// 平台常量（seed / 模板）全由配置的 `secrets` 注入。
    private static func installNativeResolvers(in context: JSContext, secrets: [String: String]?) {
        context.evaluateScript("var nativeResolver = nativeResolver || {};")

        let xorMd5: @convention(block) (Any?, Any?, Any?) -> String? = { input, seedHex, template in
            guard let input = stringValue(input),
                  let seedHex = stringValue(seedHex),
                  let template = stringValue(template) else { return nil }
            return md5URLHash(input: input, seedHex: seedHex, template: template)
        }
        context.objectForKeyedSubscript("nativeResolver")?
            .setObject(xorMd5, forKeyedSubscript: "xorMd5UrlHash" as NSString)

        // 编辑 / 封面用不上，但 pri 的脚本会调它；缺 secrets 时返回 null 让脚本自己回退。
        let seedHex = secrets?["coverSeedHex"] ?? ""
        let template = secrets?["coverUrlTemplate"] ?? ""
        let cover: @convention(block) (Any?) -> String? = { id in
            guard let id = stringValue(id) else { return nil }
            return md5URLHash(input: id, seedHex: seedHex, template: template)
        }
        context.setObject(cover, forKeyedSubscript: "nativeCoverUrl" as NSString)
    }

    private static func md5URLHash(input: String, seedHex: String, template: String) -> String? {
        guard !input.isEmpty,
              !template.isEmpty,
              let key = HexBytes.decode(seedHex),
              !key.isEmpty else { return nil }

        var mixed = Array(input.utf8)
        for index in mixed.indices {
            mixed[index] ^= key[index % key.count]
        }
        let digest = Insecure.MD5.hash(data: Data(mixed))
        let hash = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return template
            .replacingOccurrences(of: "{{hash}}", with: hash)
            .replacingOccurrences(of: "{{id}}", with: input)
    }

    /// 合法 JSON 直接解析；不合法时照 primuse 的顺序修一遍：剥 JSONP → 单引号换双引号 → `&nbsp;` 换空格。
    ///
    /// 修复只影响注入给脚本的 `response`；`responseText` 永远是原文。
    private static func jsonObject(from data: Data) -> Any? {
        // 解析失败不是错误 —— 下游脚本还有 `responseText` 可用。
        if let value = try? JSONSerialization.jsonObject(with: data) {
            return value
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.firstIndex(of: "("),
           let close = trimmed.lastIndex(of: ")"),
           open < close {
            let callback = trimmed[trimmed.startIndex..<open]
            if !callback.isEmpty,
               callback.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                trimmed = String(trimmed[trimmed.index(after: open)..<close])
            }
        }
        let repaired = trimmed
            .replacingOccurrences(of: "'", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return try? JSONSerialization.jsonObject(with: Data(repaired.utf8))
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return text.isEmpty ? nil : text
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    /// 源级闸：`running` 防重入，`quarantined` 记住"这条源的脚本已经卡死过"。
    ///
    /// 隔离是**会话级**的（进程重启就清空）—— 与 primuse 一致。
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var running: Set<String> = []
        private var quarantined: Set<String> = []

        func begin(_ key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !quarantined.contains(key), !running.contains(key) else { return false }
            running.insert(key)
            return true
        }

        func finish(_ key: String) {
            lock.lock()
            running.remove(key)
            lock.unlock()
        }

        func quarantine(_ key: String) {
            lock.lock()
            quarantined.insert(key)
            lock.unlock()
        }
    }

    /// 脚本线程上置位、同一个线程上读 —— 不需要锁。
    private final class ExceptionFlag: @unchecked Sendable {
        private(set) var raised = false

        func raise() {
            raised = true
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<Any?, Error>?

        func set(_ value: Result<Any?, Error>) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var result: Result<Any?, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}

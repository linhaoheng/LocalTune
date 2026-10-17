import Foundation

/// 把 `ImportResult` 的四个数**变成给人看的文字**。
///
/// ⚠️ **为什么放在数据层、不放在浮层里**：这些只是**拼字符串**，不碰任何界面控件
/// （不碰字体、颜色、`UILabel`）—— 跟 `Track+Display.swift` 是同一条边界。
/// 哪天它要管"这行字用什么字号、什么颜色"了，就必须搬去界面层。
extension ImportResult {

    /// 浮层主行：「已导入 N 首」（跟跑进度时那句话同一个出处）。
    var hudMessage: String { ImportProgress.hudMessage(imported: imported) }

    /// 浮层副行：**非零**的那几块，用 ` · ` 连起来；都是 0 就返回 `nil`（整行不出现）。
    ///
    /// ⚠️ 这是规格定死的**朴素版**：**每块各自为 0 就不出现、
    /// 全都为 0 整行不出现**。这一行的本分是报「**没进库的那些**」，
    /// 一份都没漏的时候它本来就无话可说，空着是对的。
    ///
    /// ⚠️ 映射表里这一行有三块（已在库 / 重复跳过 / 失败）。
    var hudDetail: String? {
        var parts: [String] = []
        if alreadyInLibrary > 0 { parts.append("已在库 \(alreadyInLibrary) 首") }
        if duplicateSkipped > 0 { parts.append("重复跳过 \(duplicateSkipped) 首") }
        if failed > 0 { parts.append("失败 \(failed) 首") }
        if unreadableFolders > 0 { parts.append("\(unreadableFolders) 个文件夹没读进去") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 浮层第三行（小字）：**第一条**失败的原因；拿得到系统原文就附在括号里。
    ///
    /// 只报第一条 —— 浮层就显示得下这一行，把 19 条都列出来没人看
    /// （`ImportResult.firstFailure` 那边同一条理由）。
    ///
    /// ⚠️ 没有失败、但有读不进去的文件夹时，改成报那个文件夹 —— 否则上面那行
    /// 只说「3 个文件夹没读进去」，用户不知道是哪个，也无从去查。
    var hudNote: String? {
        if let firstFailure {
            let head = "\(firstFailure.fileName)：\(firstFailure.reason.label)"
            guard let detail = firstFailure.detail, !detail.isEmpty else { return head }
            return "\(head)（\(detail)）"
        }
        guard let firstUnreadableFolder else { return nil }
        return "\(firstUnreadableFolder)：文件夹读不进去，里面的歌没扫到"
    }
}

import Foundation

/// 汉字 → 拼音、以及拼音首字母 —— 搜索索引要用的**两个键**。
///
/// ## 为什么不用第三方拼音词表
///
/// 系统自带这个能力：`CFStringTransform` 的 `kCFStringTransformMandarinLatin`
/// 把汉字转成带声调的拼音（`周杰伦` → `zhōu jié lún`），再用
/// `kCFStringTransformStripCombiningMarks` 把声调符号剥掉 ⇒ `zhou jie lun`。
/// 词表是几 MB 的东西，这里一行调用就够了。
///
/// 原文里的 ASCII / 数字**原样保留**，所以「Beyond 海阔天空」⇒「beyond hai kuo tian kong」——
/// 中英混着写的歌名也能按拼音命中。
///
/// 做法取自开源项目 **primuse** 的 `PrimuseKit/Sources/PrimuseKit/Models/PinyinTransformer.swift`；
/// 差别只有一处：我们把「全拼」「连写全拼」「首字母缩写」**三个形式一起**交出去（见 `searchKeys`），
/// 因为中文用户三种打法都常见（`zhou jie lun` / `zhoujielun` / `zjl`）。
enum PinyinTransformer {

    /// 全拼：每个汉字一个音节、用空格分开，**全部小写**。
    ///
    /// **纯 ASCII / 纯数字的输入返回 `nil`** —— 那种情况下拼音和原文一模一样
    /// （`Hello` 的拼音还是 `Hello`），往索引里再塞一份只是白占地方、还会干扰排序。
    ///
    /// ⚠️ **只给写库算索引键用**。搜索框里的汉字不要再过这一遍 ——
    /// 转完拿去撞索引，「周」会命中「州」。
    static func pinyin(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let buffer = NSMutableString(string: trimmed)
        guard CFStringTransform(buffer, nil, kCFStringTransformMandarinLatin, false) else {
            return nil
        }
        // 剥声调符号这一步挡不住失败（返回 `false` 只说明没做任何转换），所以结果不接 ——
        // 真剥不掉的话下面的"和原文一样就返回 nil"那条还会把它兜住。
        _ = CFStringTransform(buffer, nil, kCFStringTransformStripCombiningMarks, false)
        let result = (buffer as String).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if result == trimmed.lowercased() { return nil }
        return result.isEmpty ? nil : result
    }

    /// 一个字段存进索引的**全部搜索键**：`全拼 连写全拼 首字母`，用空格连起来。
    ///
    /// 三样都是**同一个字段的函数**，FTS5 又按空格切词，所以装成一列就够 ——
    /// 分成三列只是多两列、多两次同步，换不来别的好处。
    ///
    /// 为什么三个都要（少哪个都会有人搜不出来）：
    /// - `zhou jie lun` ⇒ 打字时按音节分开的（也支持只打一半，FTS5 前缀匹配）；
    /// - `zhoujielun` ⇒ 一气呵成连着打的，最顺手的一种；
    /// - `zjl` ⇒ 只打首字母。
    ///
    /// 没有拼音价值的输入（纯 ASCII）返回 `nil`：原文本来就整段进了索引，不用重复塞。
    static func searchKeys(_ input: String) -> String? {
        guard let full = pinyin(input) else { return nil }

        var keys = [full]
        let squashed = full.replacingOccurrences(of: " ", with: "")
        if squashed != full { keys.append(squashed) }

        let acronym = acronym(fromFullPinyin: full)
        if let acronym, acronym != squashed, !keys.contains(acronym) {
            keys.append(acronym)
        }
        return keys.joined(separator: " ")
    }

    /// 从**已经转好的全拼**里取首字母缩写：「周杰伦」⇒`zjl`。
    ///
    /// ⚠️ 收的是"已经转好的全拼"而不是原字符串：这样调用方转一次就够，
    /// 不用为了取缩写把同一句话再转一遍（`CFStringTransform` 一次要过一遍整串）。
    ///
    /// ⚠️ 里面保留空格（每个音节一个字母），FTS5 按空格切词 —— 所以中英混着的歌名
    /// 「Beyond 海阔天空」出来是 `bhktk` 一个 token，不拆。
    private static func acronym(fromFullPinyin full: String) -> String? {
        let acronym = full
            .split(separator: " ")
            .compactMap { $0.first.map(String.init) }
            .joined()
        return acronym.isEmpty ? nil : acronym
    }
}

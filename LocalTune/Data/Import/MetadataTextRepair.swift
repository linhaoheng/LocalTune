import Foundation

/// 标签文本的**编码修复** —— 从音频标签里读出来的文字，是不是「被解错了」。
///
/// ## 要治的是哪两种乱码
///
/// 1. **单字节误读** —— GBK / Big5 / Shift_JIS / EUC-KR 的字节被当成 ISO-8859-1 或
///    Windows-1252 解出，结果是一串扩展拉丁字符（`¹ý»ð`、`â€™`）；
/// 2. **多字节互串** —— UTF-8 的字节被当成 GBK / Big5 解出，汉字变成另一组汉字
///    （常夹着生僻字和繁体字），这种一个扩展拉丁字符都没有。
///
/// ## 修法
///
/// 把当前字符串**按"错误编码"编回字节**，再**按"真实编码"重解**，取合理度评分最高、
/// 且显著优于原文的那个候选。
///
/// 两道门槛防"把好的改成坏的"：
/// - 目标是 **UTF-8** 时结构自校验很强（GBK/Big5 的尾字节常落在 `0x40…0x7E`，
///   而 UTF-8 的续字节必须是 `0x80…0xBF`，正常中文标签几乎不可能碰巧是合法 UTF-8）
///   ⇒ 这类候选只要**小分差**；
/// - 没有自校验的组合（**GBK ↔ Big5**）要求**大得多的分差**，而且必须**真的减少了生僻字**。
///
/// ## 🔴 为什么必须是自动的
///
/// 用户**不可能知道哪个文件的标签坏了** —— 他看到的只是乱码，不知道那是"可以修的"。
/// 「点一下修复」这个按钮等于**没有入口**。所以它挂在读标签那一处自动跑（见 `MetadataReader.read`）。
///
/// ## 一处**删掉**了的东西
///
/// 参考实现里还有「列出所有重解方案、让用户看预览自己挑」的手动模式 —— 我们**不做**：
/// 那需要一整个界面，而现在没有那个界面，写了就是死代码。
///
/// 做法与阈值取自开源项目 **primuse** 的 `PrimuseKit/Sources/PrimuseKit/Metadata/TextEncodingRepair.swift`；
/// 我们**只留**「拿到一个字符串、判断它坏没坏、能不能修好」这一半 ——
/// 它读原始字节的那一半（按 ID3 声明字节自己解码）我们用不上：标签是 SFBAudioEngine 解好给我们的，
/// 我们手上只有字符串（见 `MetadataReader`）。
enum MetadataTextRepair {

    // MARK: - 对外的两个

    /// 修复后的文本。**没有可信候选时返回 `nil`，调用方应当保留原文。**
    ///
    /// ⚠️ 返回 `nil` 是常态：**绝大多数标签都是好的**，这里只是个便宜的自检。
    static func repaired(_ text: String) -> String? {
        // 有一种坏法是**结构性**的、可以无损还原：写标签的工具按 UTF-16LE 写了带 BOM 的字节，
        // 而解码那一侧把每两个字节当成大端读 —— 结果是开头出现 `U+FFFE`、
        // 后面每个码元都字节颠倒（`￾䐀椀猀挀漀`）。这不是"猜"，所以放在暴力搜索之前。
        if let repaired = byteSwappedUTF16Candidate(for: text) {
            return repaired
        }
        guard looksCorrupted(text) else { return nil }

        let originalScore = plausibility(text)
        let originalRareHan = rareHanCount(in: text)
        var best: (text: String, score: Int)?

        for rewrite in rewrites {
            guard let candidate = rewrite.apply(to: text) else { continue }
            guard candidate != text else { continue }

            let score = plausibility(candidate)
            let margin = rewrite.selfValidating ? selfValidatingMargin : ambiguousMargin
            guard score >= originalScore + margin else { continue }

            // 没有结构自校验的组合（GBK↔Big5）必须**真的减少生僻字**，
            // 否则只是把一组汉字换成另一组同样可疑的汉字。
            if rewrite.requiresRareHanReduction {
                guard rareHanCount(in: candidate) < originalRareHan else { continue }
            }

            if let current = best {
                if score > current.score { best = (candidate, score) }
            } else {
                best = (candidate, score)
            }
        }

        return best?.text
    }

    /// 这段文本**值不值得**进上面那套流程 —— 一个便宜的粗筛，真正的把关在分差上。
    ///
    /// ⚠️ 它必须便宜：扫描大库时**每个标题**都要过一遍。
    private static func looksCorrupted(_ text: String) -> Bool {
        var scan = ArtifactScan()
        for scalar in text.unicodeScalars {
            scan.consume(scalar)
        }
        return scan.verdict
    }

    /// 扫一趟标量攒出来的「像不像乱码」证据。**纯值类型** —— 能单独喂字符串断言。
    private struct ArtifactScan {
        private var artifactRun = 0     // 连续 Latin-1 乱码字节（0x80…0xFF）
        private var markerRun = 0       // 连续 CP1252 标记（€ ™ “ ” …）
        private var hasArtifactRun = false
        private var hasBoundary = false // 撞见 U+FFFE / U+FFFF（结构性坏）
        private var han = 0
        private var rareHan = 0

        mutating func consume(_ scalar: Unicode.Scalar) {
            let value = scalar.value
            if value == 0xFFFE || value == 0xFFFF {
                hasBoundary = true
                return
            }
            consumeArtifact(value: value)
            consumeHan(scalar, value: value)
        }

        /// 真乱码保留的是**连续**的原始字节（`Ã©`、`â€™`）；正常西文标题里的 é / ð / ö
        /// 一般被 ASCII 字符隔开。按"连续簇"判断，既能放过多重音符号的名字（Björk / Mylène），
        /// 又能覆盖 CP1252 把 0x80…0x9F 映射成 € ™ “ ” 的那种典型乱码。
        private mutating func consumeArtifact(value: UInt32) {
            let isLatin1 = (0x80...0xFF).contains(value)
            let isMarker = MetadataTextRepair.cp1252MarkerScalars.contains(value)
            guard isLatin1 || isMarker else {
                artifactRun = 0
                markerRun = 0
                return
            }
            artifactRun += isLatin1 ? 1 : 0
            markerRun += isMarker ? 1 : 0
            if artifactRun >= 2 || (artifactRun >= 1 && markerRun >= 2) {
                hasArtifactRun = true
            }
        }

        private mutating func consumeHan(_ scalar: Unicode.Scalar, value: UInt32) {
            guard MetadataTextRepair.isHan(value) else { return }
            han += 1
            if !MetadataTextRepair.isCommonHan(scalar) { rareHan += 1 }
        }

        /// 结论。
        ///
        /// - 撞见结构性坏（`U+FFFE`）或连续乱码簇 ⇒ 坏；
        /// - 否则按生僻字粗筛：汉字被当成另一套汉字解出来时，结果**几乎必然夹带生僻字**。
        ///   只看"有汉字"会让每个正常中文标题都跑满整个候选矩阵，所以先按生僻字粗筛 ——
        ///   代价是"全是常用字的乱码"会被漏掉，但**漏修远好过误改**。
        var verdict: Bool {
            if hasBoundary || hasArtifactRun { return true }
            return han >= 2 && rareHan >= 1
        }
    }

    // MARK: - 字节序颠倒的 UTF-16（结构性修复）

    /// 开头的 `U+FFFE` ＋ 每个 UTF-16 码元字节颠倒 ⇒ 换回来就是原文。
    ///
    /// ⚠️ 要求**换回来之后码元一个不少**（`String(decoding:)` 遇到坏代理对会静默替换成
    /// `U+FFFD`，那样就说明丢了数据）—— 这一条保证我们**不会凭空编字**。
    private static func byteSwappedUTF16Candidate(for text: String) -> String? {
        let original = Array(text.utf16)
        guard original.first == 0xFFFE, original.count > 1 else { return nil }

        let restored = original.map(\.byteSwapped)
        guard restored.first == 0xFEFF else { return nil }
        let payload = Array(restored.dropFirst())
        let candidate = String(decoding: payload, as: UTF16.self)

        guard Array(candidate.utf16) == payload,
              !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !candidate.unicodeScalars.contains(where: {
                  $0.value == 0xFFFD
                      || $0.value == 0xFFFE
                      || $0.value == 0xFFFF
                      || isDisallowedControl($0.value)
              }) else {
            return nil
        }
        return candidate
    }

    // MARK: - 编码

    private static func cfEncoding(_ raw: UInt32) -> String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(raw))
        )
    }

    /// 中文圈最可能出现的三种"真实编码"（除了 UTF-8）。
    private static let gb18030 = cfEncoding(0x0632)
    private static let big5 = cfEncoding(0x0A03)
    private static let eucKR = cfEncoding(0x0940)

    /// 按指定编码把字符串编回字节；编不出来（有字符不在这个编码里）就返回 `nil`。
    ///
    /// ⚠️ 走 CoreFoundation 的 `CFStringCreateExternalRepresentation`（`allowLossyConversion = 0`）
    /// 而不是 `String.data(using:)`：后者默认**允许有损**，会把编不出来的字符悄悄替换掉 ——
    /// 那样"编回去的字节"就不是原来的字节了，重解出来的是垃圾。
    ///
    /// ⚠️ 先把 UTF-16 码元**复制成一份 CFString 再转**：直接拿 Swift 字符串的存储去转，
    /// 多个线程同时转时桥接层可能崩（扫描是 4 路并发的）。
    private static func losslessEncodedData(_ text: String, using encoding: String.Encoding) -> Data? {
        let cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }

        let codeUnits = Array(text.utf16)
        guard let ownedString = codeUnits.withUnsafeBufferPointer({ buffer in
            CFStringCreateWithCharacters(kCFAllocatorDefault, buffer.baseAddress, buffer.count)
        }),
            let encoded = CFStringCreateExternalRepresentation(
                kCFAllocatorDefault, ownedString, cfEncoding, 0
            ) else {
            return nil
        }
        return encoded as Data
    }

    // MARK: - 候选矩阵

    /// 目标编码是 UTF-8 时结构自校验很强 ⇒ 小分差就够。
    private static let selfValidatingMargin = 4
    /// 没有自校验的组合（GBK↔Big5）⇒ 要大分差，还得真的减少生僻字。
    private static let ambiguousMargin = 24

    /// 一次「按错误编码编回字节、按真实编码重解」。
    private struct Rewrite {

        /// 当前这串字是被这个编码**错误地**解出来的。
        let source: String.Encoding
        /// 这些字节**真实的**编码。
        let target: String.Encoding
        /// 目标编码有没有结构自校验（只有 UTF-8 有）。
        let selfValidating: Bool
        /// 只有 GBK↔Big5 这一对没有结构信号。别的目标（Shift_JIS / EUC-KR）不能因为
        /// "解出来没有汉字"就被否决 —— 它们的正确结果本来就没有汉字。
        let requiresRareHanReduction: Bool

        func apply(to text: String) -> String? {
            guard let bytes = encodedBytes(of: text), bytes.count >= 2 else { return nil }
            guard let decoded = String(data: bytes, encoding: target) else { return nil }

            let cleaned = decoded.replacingOccurrences(of: "\0", with: "")
            guard !cleaned.isEmpty else { return nil }
            // 解出来带替换字符或者控制字符 ⇒ 这一解是错的，别拿它去比分数。
            guard !cleaned.unicodeScalars.contains(where: {
                $0.value == 0xFFFD || MetadataTextRepair.isDisallowedControl($0.value)
            }) else {
                return nil
            }
            return cleaned
        }

        private func encodedBytes(of text: String) -> Data? {
            guard let bytes = MetadataTextRepair.losslessEncodedData(text, using: source) else {
                return nil
            }
            guard source == MetadataTextRepair.gb18030 else { return bytes }

            // GB18030 能编码**全部** Unicode（用 4 字节序列），所以它当"错误编码"时永远不会失败。
            // 只有当每个字符都落在 1/2 字节的传统 GBK 区间、编出来的字节数正好对得上时，
            // 这些字节才可能真是当初被误读的那一批。
            let expected = text.unicodeScalars.reduce(0) { total, scalar in
                total + (scalar.value < 0x80 ? 1 : 2)
            }
            return bytes.count == expected ? bytes : nil
        }
    }

    private static let rewrites: [Rewrite] = {
        var list: [Rewrite] = []
        let trueEncodings: [String.Encoding] = [.utf8, gb18030, big5, .shiftJIS, eucKR]

        // 单字节误读：字节被当成 latin1 / CP1252 逐字节映射成了字符。
        for source in [String.Encoding.isoLatin1, .windowsCP1252] {
            for target in trueEncodings {
                list.append(Rewrite(
                    source: source, target: target,
                    selfValidating: target == .utf8, requiresRareHanReduction: false
                ))
            }
        }

        // 多字节互串：UTF-8 字节被当成 GBK / Big5 解出（汉字 → 另一组汉字）。
        list.append(Rewrite(source: gb18030, target: .utf8, selfValidating: true, requiresRareHanReduction: false))
        list.append(Rewrite(source: big5, target: .utf8, selfValidating: true, requiresRareHanReduction: false))

        // GBK 与 Big5 互串：没有自校验，只能靠大分差 + 生僻字必须减少来把关。
        list.append(Rewrite(source: gb18030, target: big5, selfValidating: false, requiresRareHanReduction: true))
        list.append(Rewrite(source: big5, target: gb18030, selfValidating: false, requiresRareHanReduction: true))

        return list
    }()

    // MARK: - 合理度评分

    /// 这段文字"**像不像人写的标签**"。分数只用来比较**同一个字段**的不同解码候选。
    private static func plausibility(_ text: String) -> Int {
        var score = 0
        var hangulCount = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if isHangul(value) { hangulCount += 1 }

            if value == 0xFFFD {
                score -= 40
            } else if isDisallowedControl(value) {
                score -= 25
            } else if isHan(value) {
                score += isCommonHan(scalar) ? 6 : -8
            } else if isHalfwidthKana(value) {
                // 半角片假名是合法的旧编码结果，但它的信号比全角假名/谚文弱：
                // 让它压在真正的汉字/谚文之下，同时还能救回"整条标题都是半角片假名"的那种。
                score += 2
            } else if isKanaOrHangul(value) {
                score += 6
            } else if isCJKPunctuationOrFullwidth(value) {
                score += 2
            } else if cp1252MarkerScalars.contains(value) {
                score -= 4
            } else if (0xA1...0xFF).contains(value) {
                score -= 3
            } else if value < 0x80 {
                score += 1
            }
            // 其余文字（西里尔、希腊、emoji…）按中性处理，不加不减。
        }
        // 够长的谚文结果是 EUC-KR 的有力旁证；但**一个**碰巧的谚文字不能压过一条短中文。
        if hangulCount >= 3 && hangulCount * 2 >= text.unicodeScalars.count {
            score += 2
        }
        return score
    }

    private static func rareHanCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            count + (isHan(scalar.value) && !isCommonHan(scalar) ? 1 : 0)
        }
    }

    /// 这个汉字是不是常用字：落不落进 GB2312 的一/二级字库，或者 Big5 的常用/次常用区
    /// —— 两边取并集，简体库和繁体库都不会被误判成生僻字。乱码产生的汉字串通常大量落在外面。
    private static func isCommonHan(_ scalar: Unicode.Scalar) -> Bool {
        commonHanScalars.contains(scalar.value)
    }

    /// 常用字表：一次性把两个字库展开成集合，之后全是查表。
    ///
    /// ⚠️ 不能每个字都去现场编码一次 —— 扫描大库时每个标题都要跑一遍打分，那样太慢。
    private static let commonHanScalars: Set<UInt32> = {
        var scalars = Set<UInt32>()
        scalars.reserveCapacity(20000)

        func insert(_ bytes: [UInt8], encoding: String.Encoding) {
            guard let text = String(data: Data(bytes), encoding: encoding),
                  text.unicodeScalars.count == 1,
                  let scalar = text.unicodeScalars.first,
                  isHan(scalar.value) else {
                return
            }
            scalars.insert(scalar.value)
        }

        // GB2312 一级 B0A1…D7F9 与二级 D8A0…F7FE
        for lead in 0xB0...0xF7 {
            for trail in 0xA1...0xFE {
                insert([UInt8(lead), UInt8(trail)], encoding: gb18030)
            }
        }

        // Big5 常用 A440…C67E 与次常用 C940…F9D5
        let big5Trails = Array(0x40...0x7E) + Array(0xA1...0xFE)
        for lead in Array(0xA4...0xC6) + Array(0xC9...0xF9) {
            for trail in big5Trails {
                insert([UInt8(lead), UInt8(trail)], encoding: big5)
            }
        }

        return scalars
    }()

    // MARK: - 文字分类

    private static func isHan(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
            || (0x2A700...0x2B73F).contains(value)
            || (0x2B740...0x2B81F).contains(value)
            || (0x2B820...0x2CEAF).contains(value)
    }

    /// 假名与谚文。
    ///
    /// ⚠️ 必须认它们：只认汉字的话，一条**纯假名**的日文标题算出来是 0 个 CJK 字符，
    /// 正确解码反而会因为"没有改善"被否决。
    private static func isKanaOrHangul(_ value: UInt32) -> Bool {
        (0x3040...0x309F).contains(value)        // 平假名
            || (0x30A0...0x30FF).contains(value)  // 片假名
            || (0x31F0...0x31FF).contains(value)  // 片假名音标扩展
            || isHalfwidthKana(value)
            || isHangul(value)
    }

    private static func isHalfwidthKana(_ value: UInt32) -> Bool {
        (0xFF66...0xFF9F).contains(value)
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        (0xAC00...0xD7A3).contains(value)        // 谚文音节
            || (0x1100...0x11FF).contains(value)  // 谚文字母
            || (0x3130...0x318F).contains(value)  // 谚文兼容字母
    }

    private static func isCJKPunctuationOrFullwidth(_ value: UInt32) -> Bool {
        (0x3000...0x303F).contains(value) || (0xFF01...0xFF60).contains(value)
    }

    private static func isDisallowedControl(_ value: UInt32) -> Bool {
        // 制表 / 换行 / 回车在歌词这类字段里是合法的，其余控制字符都当"解错了"的证据。
        if value == 0x09 || value == 0x0A || value == 0x0D { return false }
        return value < 0x20 || (0x7F...0x9F).contains(value)
    }

    /// Windows-1252 在 `0x80…0x9F` 区映射出来的那些码位。
    ///
    /// ⚠️ 这一区**必须算进来**：最典型的乱码 `â€™` 里，只有 `â` 落在 `U+00A1…U+00FF`，
    /// 光数那一区凑不够阈值，整条粗筛就漏了。
    private static let cp1252MarkerScalars: Set<UInt32> = [
        0x20AC, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6,
        0x2030, 0x0160, 0x2039, 0x0152, 0x017D, 0x2018, 0x2019, 0x201C,
        0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A,
        0x0153, 0x017E, 0x0178,
    ]
}

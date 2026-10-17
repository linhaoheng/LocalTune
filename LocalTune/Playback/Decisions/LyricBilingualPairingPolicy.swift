import Foundation

/// 「同一时间戳上的相邻行，是不是原文 + 译文？」—— 是就把附属行并进主行。
///
/// **为什么非要它**：双语 LRC 把原文和译文写成**同一个时间戳的两行**。不并的话，
/// 界面上就是一句原文、一句译文各占一行；而且两行时间戳相同，高亮会落到**后一条**
/// （译文）上，原文的逐字扫光和点按都跟着失效。
///
/// 抄的是 **primuse** `LyricBilingualPairingPolicy`
/// （`PrimuseKit/Sources/PrimuseKit/LyricTranslationGroupingPolicy.swift:1067`），
/// **门槛值一个不改** —— 这套判据是保守型：误配会真的吞掉一行内容，漏配只是多显示
/// 一行。所以宁可漏，不可错。
enum LyricBilingualPairingPolicy {

    /// 并的时候最多「一句原文 + 两条附属」。
    ///
    /// 三行共用一个时间戳在外语歌里很常见（原文 / 注音 / 译文）；再来第四条第五条，
    /// 更可能是多声部叠唱 —— 吞掉任何一行都会真的丢内容。
    private static let maximumRowCount = 3

    /// 同一时间戳的容差。解析出来的本来就是秒值，2ms 足够吃掉浮点误差。
    private static let timestampTolerance: TimeInterval = 0.002

    static func pair(_ lines: [LyricsLine]) -> [LyricsLine] {
        // 连 4 行都没有，谈不上"整篇结构"，不动。
        guard lines.count >= 4 else { return lines }

        let clusters = adjacentTimestampClusters(in: lines)

        // 只有**同一时间戳上重复出现**的行才有"是不是双语"的歧义。单独成行的歌词
        // 不进分母 —— 否则一首中文歌里只夹了几句外语和它们的译文时，比例永远达不到
        // 门槛，那几句的原文就一直高亮不了。
        var repeatedClusterCounts: [Int: Int] = [:]
        for cluster in clusters where cluster.count >= 2
            && cluster.contains(where: { isPairableSource(lines[$0]) }) {
            repeatedClusterCounts[cluster.count, default: 0] += 1
        }

        let candidates = clusters.compactMap { makeCandidate(cluster: $0, in: lines) }

        // 行数相同的候选各自投票：一份文档里既可能整篇是「原文 + 译文」，也可能整篇
        // 是「原文 + 注音 + 译文」，两种结构分开计票才不会互相拉低比例。
        var accepted: [PairCandidate] = []
        for (rowCount, group) in Dictionary(grouping: candidates, by: \.rowCount) {
            accepted.append(contentsOf: dominantCandidates(
                in: group,
                repeatedClusterCount: repeatedClusterCounts[rowCount] ?? group.count
            ))
        }
        guard !accepted.isEmpty else { return lines }

        let candidateBySourceIndex = Dictionary(
            uniqueKeysWithValues: accepted.map { ($0.sourceIndex, $0) }
        )
        let absorbedIndexes = Set(accepted.flatMap(\.companionIndexes))

        return lines.enumerated().compactMap { index, line in
            guard !absorbedIndexes.contains(index) else { return nil }
            guard let candidate = candidateBySourceIndex[index] else { return line }

            // 文件里的先后顺序就是作者想要的阅读顺序：注音写在译文前面就先显示注音。
            // 这里**不猜**哪一条是注音、哪一条是翻译，只把第一条当首选译文。
            let companions = candidate.companionIndexes.map { lines[$0].text }
            var sourceLine = line
            sourceLine.manualTranslation = companions.first
            sourceLine.alternateTranslations = Array(companions.dropFirst())
            return sourceLine
        }
    }

    // MARK: - 候选

    private static func makeCandidate(cluster: [Int], in lines: [LyricsLine]) -> PairCandidate? {
        guard cluster.count >= 2, cluster.count <= maximumRowCount else { return nil }

        let sourceIndex = cluster[0]
        let source = lines[sourceIndex]
        // 原文**允许自带逐字**：不少工具把逐字原文和整行译文写成同一个时间戳的相邻
        // 两行。要是把带音节的原文排除在配对之外，译文就会留成独立一行，高亮落到译文上。
        guard isPairableSource(source),
              !appearsSpeakerAttributed(source.text),
              source.manualTranslation == nil,
              source.alternateTranslations.isEmpty,
              let sourceFamily = dominantScript(in: source.text) else {
            return nil
        }

        var companionFamilies: [ScriptFamily] = []
        var companionTexts: [String] = []
        for companionIndex in cluster.dropFirst() {
            let companion = lines[companionIndex]
            // 译文那一侧**不放宽到逐字**：两行都带音节时更可能是双声部或对唱。
            guard isOrdinarySynchronizedLine(companion),
                  !appearsSpeakerAttributed(companion.text),
                  companion.manualTranslation == nil,
                  companion.alternateTranslations.isEmpty,
                  let family = dominantScript(in: companion.text),
                  family != sourceFamily else {
                return nil
            }
            companionFamilies.append(family)
            companionTexts.append(normalized(companion.text))
        }

        return PairCandidate(
            sourceIndex: sourceIndex,
            companionIndexes: Array(cluster.dropFirst()),
            orientation: Orientation(source: sourceFamily, companions: companionFamilies),
            sourceText: normalized(source.text),
            companionTexts: companionTexts
        )
    }

    private static func dominantCandidates(
        in candidates: [PairCandidate],
        repeatedClusterCount: Int
    ) -> [PairCandidate] {
        guard candidates.count >= 2 else { return [] }

        var countByOrientation: [Orientation: Int] = [:]
        for candidate in candidates {
            countByOrientation[candidate.orientation, default: 0] += 1
        }
        guard let highestCount = countByOrientation.values.max(), highestCount >= 2 else {
            return []
        }
        let dominantOrientations = countByOrientation.compactMap { orientation, count in
            count == highestCount ? orientation : nil
        }
        // 🔴 整篇方向必须唯一：中英混排、方向来回颠倒 → 整体放弃。
        guard dominantOrientations.count == 1,
              let dominantOrientation = dominantOrientations.first else {
            return []
        }

        let dominant = candidates.filter { $0.orientation == dominantOrientation }

        // 整段重复的副歌分不出「译文」和「同一句唱了两遍」，所以原文和每一条附属
        // 都要至少出现两种不同文本。
        let companionTextsAreVaried = dominantOrientation.companions.indices.allSatisfy { slot in
            Set(dominant.map { $0.companionTexts[slot] }).count >= 2
        }
        guard Set(dominant.map(\.sourceText)).count >= 2,
              companionTextsAreVaried,
              dominant.count * 5 >= candidates.count * 4,        // ≈ 4/5，分母是全部候选
              dominant.count * 5 >= repeatedClusterCount * 3 else {  // ≈ 3/5，分母是重复簇数
            return []
        }
        return dominant
    }

    private struct PairCandidate {
        var sourceIndex: Int
        var companionIndexes: [Int]
        var orientation: Orientation
        var sourceText: String
        var companionTexts: [String]

        var rowCount: Int { companionIndexes.count + 1 }
    }

    private struct Orientation: Hashable {
        var source: ScriptFamily
        var companions: [ScriptFamily]
    }

    private enum ScriptFamily: Hashable {
        case latin
        case han
        case japanese
        case hangul
        case arabic
        case hebrew
        case cyrillic
        case devanagari
        case thai
    }

    // MARK: - 分簇与判据

    /// 把**连续且时间戳相同**的行归成一簇。
    private static func adjacentTimestampClusters(in lines: [LyricsLine]) -> [[Int]] {
        var result: [[Int]] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            var cluster = [index]
            var next = lines.index(after: index)
            while next < lines.endIndex,
                  lines[index].isSynchronized,
                  lines[next].isSynchronized,
                  abs(lines[next].timestamp - lines[index].timestamp) <= timestampTolerance {
                cluster.append(next)
                next = lines.index(after: next)
            }
            result.append(cluster)
            index = next
        }
        return result
    }

    /// 能当**原文**的行：可以带逐字时间轴，但必须是有时间戳、有正文的行。
    private static func isPairableSource(_ line: LyricsLine) -> Bool {
        line.isSynchronized && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 能当**译文（附属行）**的行：必须是纯行级 —— 带逐字的两行更像双声部/对唱。
    private static func isOrdinarySynchronizedLine(_ line: LyricsLine) -> Bool {
        line.isSynchronized
            && line.syllables?.isEmpty != false
            && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 对唱标记 —— `(男)` `女：` `Chorus:` 这种。它们是**角色**，不是译文。
    private static func appearsSpeakerAttributed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if ["(", "（", "[", "【", "<", "〈"].contains(where: trimmed.hasPrefix) {
            return true
        }

        guard let separator = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return false
        }
        let prefix = trimmed[..<separator]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !prefix.isEmpty, prefix.count <= 16 else { return false }
        if prefix.count == 1 { return true }

        let compact = prefix.filter { $0.isLetter || $0.isNumber }
        let speakerLabels: Set<String> = [
            "male", "female", "man", "woman", "boy", "girl", "singer",
            "lead", "backing", "chorus", "duet", "vocal", "voice",
            "男", "女", "主唱", "副唱", "合唱", "和声", "独唱", "对唱",
        ]
        return speakerLabels.contains(compact)
    }

    // MARK: - 这一行"是什么文字"

    /// 这一行是哪个文字家族，够不够纯。
    ///
    /// 要求：字母数 ≥ 2、最高那族 ≥ 2、且占比 ≥ 70%。不够纯就返回 `nil` ——
    /// 中英各半那种混排行不算数，免得拿它当判据。
    private static func dominantScript(in text: String) -> ScriptFamily? {
        var total = 0
        var counts: [ScriptFamily: Int] = [:]
        var hanCount = 0
        var kanaCount = 0

        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            total += 1
            guard let family = scriptFamily(for: scalar.value) else { continue }
            switch family {
            case .han:
                hanCount += 1
            case .japanese:
                kanaCount += 1
            default:
                counts[family, default: 0] += 1
            }
        }

        // 日文里既有汉字又有假名：只要有假名，整行按日文算。
        if kanaCount > 0 {
            counts[.japanese] = hanCount + kanaCount
        } else if hanCount > 0 {
            counts[.han] = hanCount
        }

        guard total >= 2,
              let highest = counts.values.max(),
              highest >= 2,
              Double(highest) / Double(total) >= 0.7 else {
            return nil
        }
        let dominant = counts.compactMap { family, count in count == highest ? family : nil }
        guard dominant.count == 1 else { return nil }
        return dominant.first
    }

    /// 码位 → 文字家族。只列歌里真会出现的九族。
    private static func scriptFamily(for value: UInt32) -> ScriptFamily? {
        switch value {
        case 0x0041...0x005A, 0x0061...0x007A,
             0x00C0...0x024F, 0x1E00...0x1EFF,
             0xAB30...0xAB6F, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .latin
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x3134F:
            return .han
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
            return .japanese
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
             0xAC00...0xD7AF, 0xD7B0...0xD7FF:
            return .hangul
        case 0x0600...0x06FF, 0x0750...0x077F, 0x0870...0x089F,
             0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .arabic
        case 0x0590...0x05FF, 0xFB1D...0xFB4F:
            return .hebrew
        case 0x0400...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        case 0x0900...0x097F, 0xA8E0...0xA8FF:
            return .devanagari
        case 0x0E00...0x0E7F:
            return .thai
        default:
            return nil
        }
    }
}

import Foundation

/// `Track` 的**音质判定与呈现** —— 从已经存进库的字段算出档位、拼出给人看的两段文字。
///
/// 🔴 **纯函数、不重读文件**：输入只有 `format` / `sampleRate` / `bitDepth` / `bitRate` /
/// `path`，全部是**导入那一刻**就读进库的。
/// ⚠️ 反面做法是「每次显示都重开一次文件现算」（`init?(track:)` 那种）——
/// 那是把 IO 放在「进页面 / 滚一行」这个当口上。
///
/// 🔴 **主信号是引擎报的 `format`，扩展名只兜底**：无损是**编码**的属性、不是容器的 ——
/// `.m4a` 能装 AAC 也能装 ALAC，`.oga` 能装 Vorbis 也能装 FLAC，光看后缀必错。
///
/// 🔴 **格式名表列全 + 整串精确匹配**：名字是从引擎源码里逐个抄下来的（每个 `*File.mm` 里
/// 给 `SFBAudioPropertiesKeyFormatName` 赋的那个串），是个**闭集合** ⇒ 一律**整串相等**
/// 比对就够，不用 `contains` 子串。
///
/// ⚠️ 表里列的是**引擎的原名**（`Apple Lossless`），不是显示名 —— 常见做法是把
/// `Apple Lossless` 就地改写成 `ALAC` 再拿去判定（那张表里两个名字都列了）；
/// 我们**把这两件事分开**：判定吃引擎原名，
/// 只有**显示**那一处才换（见下面 `audioQualityFormatName`）。
///
/// 出处与取舍的完整记录：`docs/参考/功能-参考项目映射.md` §3「音质徽章」。
extension Track {

    // MARK: - 判定

    /// 这首歌的音质档位。
    ///
    /// **永远有答案**（不返回 `nil`）：认不出来就按有损算 —— 徽章不能开天窗。
    var audioQualityLevel: AudioQualityLevel {
        switch encodingKind {
        case .dsd:
            // DSD 并入最高档（去掉独立的 DSD 档）。
            return .hr

        case .lossless:
            // 🔴 高解析度那条线：**采样率 ≥ 88.2 kHz 或位深 ≥ 24 bit**。
            // 出处 primuse（`PrimuseKit/Sources/PrimuseKit/Models/AudioQuality.swift:44-48`），
            // 定「按 primuse」。文档原写「≥ 96 kHz **且** 位深 > 23」——已作废。
            // ⚠️ 两处都变了：门槛降了（96k → 88.2k、> 23 → ≥ 24）、**「且」变「或」**。
            // 一个 24 bit / 44.1 kHz 的 FLAC：按旧线是 SQ，按新线是 **HR**。
            let isHighResolution = (sampleRate ?? 0) >= 88_200 || (bitDepth ?? 0) >= 24
            return isHighResolution ? .hr : .sq

        case .lossy:
            // 「高码率有损」那条线：320 kbps。
            // ⚠️ 单位就是 kbps（库里存的就是它）—— 别再按 KiB/秒 换算一遍，那会大 8 倍
            //（`raw * 8.192` 那个换算就是这么错的：320 kbps 会显示成 2621）。
            return (bitRate ?? 0) >= 320 ? .hq : .sd
        }
    }

    // MARK: - 呈现

    /// 拿来**显示**的格式名 —— 引擎报什么就写什么，只把用户认不出的那一个换成通用写法。
    ///
    /// ⚠️ `Apple Lossless` → `ALAC`：引擎报的是这个名字，但用户（标签里、别处播放器上）
    /// 见到的都是 `ALAC`。**只有显示这一处换** —— 上面那张判定表用的仍是引擎的原名。
    ///
    /// ⚠️ **不转大写**：引擎报的 `MP3` / `FLAC` / `AAC` 本来就是用户认得的写法，
    /// 一转大写 `Ogg Vorbis` 会变成 `OGG VORBIS`、`Apple Lossless` 会变成 `APPLE LOSSLESS`。
    var audioQualityFormatName: String? {
        guard let format, !format.isEmpty else { return nil }
        return format == "Apple Lossless" ? "ALAC" : format
    }

    /// **列表行**那一小枚：格式名 ＋ 档位；格式名读不到就是 `nil`（这一枚整个不画）。
    ///
    /// ⚠️ 档位**永远有答案**，所以「这一枚要不要画」由**格式名在不在**决定 ——
    /// 两者捆在 `AudioQualityTag` 里一起给出去，外面不用自己判。
    var audioQualityTag: AudioQualityTag? {
        guard let name = audioQualityFormatName else { return nil }
        return AudioQualityTag(format: name, level: audioQualityLevel)
    }

    /// **播放页**那一条：说明文字 ＋ 档位；什么都读不到就是 `nil`。
    ///
    /// 文字怎么拼：格式名和"参数"两段，中间 `" · "`（`AudioQuality.playingText` 那一套）；
    /// 参数那一项按编码分三种写法 ——
    ///
    /// | 编码 | 参数那一项 | 整条的例子 |
    /// |---|---|---|
    /// | 无损（位深、采样率都有） | `16bit/44.1kHz` | `FLAC · 16bit/44.1kHz` |
    /// | 无损（缺位深，有码率） | `1000kbps/44.1kHz` | `FLAC · 1000kbps/44.1kHz` |
    /// | 有损（有码率） | `320kbps/44.1kHz` | `MP3 · 320kbps/44.1kHz` |
    /// | DSD | `DSD` | `DSD Stream · DSD` |
    ///
    /// 🔴 **位深和采样率是"一项"**（`16bit/44.1kHz`，中间 `/`、**两边无空格**）——
    /// 这是最容易写错的一处：按字段个数拼成 `44.1 kHz · 16 bit · 1000 kbps` 就和这一行的口径对不上。
    ///
    /// ⚠️ 参数那一项**缺谁就少谁**，不占位：有损但读不到码率 ⇒ 只剩格式名（`MP3`）；
    /// 无损但位深、码率都没有 ⇒ 同样只剩格式名。
    var audioQualityLine: AudioQualityLine? {
        var parts: [String] = []
        if let name = audioQualityFormatName { parts.append(name) }

        switch encodingKind {
        case .dsd:
            // DSD 那一档**恒定**写这两个字（它读不到 DSD 的"码率"）。
            parts.append("DSD")

        case .lossless:
            if let bits = bitDepth, bits > 0, let rate = sampleRate, rate > 0 {
                parts.append("\(bits)bit/\(Self.sampleRateText(rate))")
            } else if let kbps = bitRate, kbps > 0 {
                parts.append(Self.bitRateText(kbps, sampleRate: sampleRate))
            }

        case .lossy:
            if let kbps = bitRate, kbps > 0 {
                parts.append(Self.bitRateText(kbps, sampleRate: sampleRate))
            }
        }

        guard !parts.isEmpty else { return nil }
        return AudioQualityLine(text: parts.joined(separator: " · "), level: audioQualityLevel)
    }

    // MARK: - 判定层（三档）

    /// 编码类型 —— 判定层的三档，收敛到档位层的四档（上面那个 `audioQualityLevel`）。
    ///
    /// ⚠️ **不对外**：外面要的是「哪一档」，不是「哪种编码」。真有一天别处也要它，再提上去。
    private enum EncodingKind {
        case dsd
        case lossless
        case lossy
    }

    /// 引擎报的格式名 → 编码类型。
    ///
    /// ⚠️ **有损那一组是「说全」，不是「必需」**：认不出来的名字照样按有损兜底（见下面），
    /// 列在这儿是为了让这张表**自己说全** —— 读的人不用再去推「没列出来的算什么」。
    private static let encodingKinds: [String: EncodingKind] = [
        // DSD（2）
        "DSD Stream": .dsd,
        "DSD Interchange": .dsd,

        // 无损（9）
        "FLAC": .lossless,
        "Ogg FLAC": .lossless,
        "Apple Lossless": .lossless,
        "Monkey's Audio": .lossless,
        "WavPack": .lossless,
        "True Audio": .lossless,
        "Shorten": .lossless,
        "WAVE": .lossless,
        "AIFF": .lossless,

        // 有损（16）
        "MP3": .lossy,
        "MPEG-1 Layer I": .lossy,
        "MPEG-1 Layer II": .lossy,
        "MPEG-1 Layer III": .lossy,
        "MPEG-2 Layer I": .lossy,
        "MPEG-2 Layer II": .lossy,
        "MPEG-2 Layer III": .lossy,
        "MPEG-2.5 Layer I": .lossy,
        "MPEG-2.5 Layer II": .lossy,
        "MPEG-2.5 Layer III": .lossy,
        "AAC": .lossy,
        "Ogg Vorbis": .lossy,
        "Ogg Opus": .lossy,
        "Ogg Speex": .lossy,
        "Musepack": .lossy,
        "MP4": .lossy,
    ]

    /// 扩展名兜底 —— **只列无损和 DSD 那些**，剩下的（含所有有损名）落到最后那个 `.lossy`。
    ///
    /// ⚠️ 名单是从**引擎真正能读的扩展名**里挑的（每个 `*File.mm` 的 `supportedPathExtensions`，
    /// 逐个核过）。引擎能进库的一共这 20 个：
    /// `flac` · `oga` · `dsf` · `dff` · `aiff` · `aif` · `wav` · `wave` · `m4a` · `m4r` ·
    /// `mp4` · `mp3` · `ape` · `wv` · `tta` · `shn` · `mpc` · `ogg` · `opus` · `spx`。
    /// ⇒ `alac` / `tak` / `au` / `caf` **不列**：引擎根本没有对应的读取类，进都进不来
    ///（`AudioFileTypes.swift` 顶上那条写了 —— `caf` / `aac` 属于「假支持」），列进来就是假条目。
    private static let losslessExtensions: Set<String> = [
        "flac", "aiff", "aif", "wav", "wave", "ape", "wv", "tta", "shn",
    ]

    private static let dsdExtensions: Set<String> = ["dsf", "dff"]

    /// 先看引擎报的格式名，名字没有 / 不在表里（引擎升级、出了新格式）再看后缀，最后按有损兜底。
    private var encodingKind: EncodingKind {
        if let format, let kind = Self.encodingKinds[format] { return kind }

        // ⚠️ `.m4a` / `.m4r` / `.mp4` / `.oga` **有意不在这两张名单里**：它们能装两种编码，
        // 看后缀判不出来 —— 那种文件只能靠格式名（`Apple Lossless` / `AAC` / `Ogg FLAC` /
        // `Ogg Vorbis`）分辨。名字也认不出时按有损算：有损的常见得多。
        let fileExtension = (path as NSString).pathExtension.lowercased()
        if Self.dsdExtensions.contains(fileExtension) { return .dsd }
        if Self.losslessExtensions.contains(fileExtension) { return .lossless }
        return .lossy
    }

    // MARK: - 文字（私有）

    /// 码率那一项：`320kbps/44.1kHz`；采样率读不到就只剩 `320kbps`。
    ///
    /// ⚠️ `kbps` 和数字之间**没有空格**、`/` 两边也**没有空格**。
    private static func bitRateText(_ kbps: Int, sampleRate: Int?) -> String {
        guard let rate = sampleRate, rate > 0 else { return "\(kbps)kbps" }
        return "\(kbps)kbps/\(sampleRateText(rate))"
    }

    /// 采样率：**整数千赫就不写小数**（48000 → `48kHz`），带零头才写一位（44100 → `44.1kHz`）；
    /// 不到 1000 Hz 直接写赫兹（`800Hz`）。
    ///
    /// ⚠️ 小数那一位用的是 `%.1f`（四舍五入），**不是截断**。
    /// 所以 22.05 kHz 这种会显示成 `22.1kHz`。
    /// 这是规格的一部分、不是算错；常见档（44.1 / 48 / 88.2 / 96 / 176.4 / 192）不受影响。
    private static func sampleRateText(_ hertz: Int) -> String {
        guard hertz >= 1000 else { return "\(hertz)Hz" }
        let kHz = Double(hertz) / 1000
        guard kHz != kHz.rounded(.towardZero) else { return "\(Int(kHz))kHz" }
        return String(format: "%.1fkHz", kHz)
    }
}

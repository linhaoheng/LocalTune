import Foundation
import SFBAudioEngine

/// 从一个音频文件里**读出来的东西**。
///
/// 它**不是 `Track`** —— `Track` 还带着 id / 相对路径 / 导入时间 / 内容指纹那些"归我们管"的东西，
/// 而这里只有「文件自己说他是什么」。导入时把两边拼起来，才是一首完整的歌。
struct AudioMetadata: Equatable, Sendable {

    // 标签
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist: String?
    var composer: String?
    var genre: String?
    var comment: String?
    /// 原样存标签里写的东西（`"2019"` / `"2019-05-01"` 都行），不切分、不转换。
    var releaseDate: String?

    // 编号
    var trackNumber: Int?
    var totalTracks: Int?
    var discNumber: Int?
    var totalDiscs: Int?

    // 时长与音质
    var durationMs: Int?
    var bitRate: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?
    var format: String?

    // 歌词与封面（封面是**原始二进制**，还没压缩、也还没落盘）
    var lyrics: String?
    var artworkData: Data?
}

/// 读标签 / 时长 / 音质 / 封面。
///
/// ⚠️ **别照着 `.swift` 文件名猜 API 名字**。这个库是 ObjC 写的、给 Swift 起了新名字：
/// 库里 `SFBAudioFile.h` 第 61 行写着 `NS_SWIFT_NAME(AudioFile)` ——
/// 所以 Swift 里叫 `AudioFile`（不是 `SFBAudioFile`），
/// `SFBAudioProperties.swift` 这个文件名对应的类型叫 `AudioProperties`。
///
/// ⚠️ **读标签本身就是校验**：引擎打不开会直接抛错。所以这一步排在「拷进沙盒」**之前** ——
/// 打不开的文件压根不该拷进来。
///
/// ## 🔴 这里是**全工程唯一**读标签的地方，所以文字编码修复挂在这一处
///
/// 标签声明写错的文件（声明一种编码、实际是另一种）解出来是乱码，而**没有任何一步会发现它坏了**
/// —— 乱码会进库、进列表、进搜索，永远错下去。用户**不可能知道哪个文件的标签坏了**
/// （他看到的只是乱码，不知道那是"可以修的"），所以这件事必须**自动**做，
/// 而且**只做一次、做在一个地方**：落在 `read` 里，两条导入路（打开文件 / 扫描）自动一起覆盖。
///
/// ⚠️ **别把它散出去**：入口一旦散在好几个文件里，就得每一处各调一次修复 ——
/// 迟早漏一处（见 `MetadataTextRepair`）。
enum MetadataReader {

    static func read(_ url: URL) throws -> AudioMetadata {
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let metadata = file.metadata
        let properties = file.properties

        var result = AudioMetadata()

        // 没有标题就拿文件名顶上 —— 列表上总得有东西能显示。
        result.title = repaired(metadata.title) ?? url.deletingPathExtension().lastPathComponent
        result.artist = repaired(metadata.artist) ?? ""
        result.album = repaired(metadata.albumTitle) ?? ""
        result.albumArtist = repaired(metadata.albumArtist)
        result.composer = repaired(metadata.composer)
        result.genre = repaired(metadata.genre)
        result.comment = repaired(metadata.comment)
        result.releaseDate = metadata.releaseDate
        result.trackNumber = metadata.trackNumber
        result.totalTracks = metadata.trackTotal
        result.discNumber = metadata.discNumber
        result.totalDiscs = metadata.discTotal
        result.lyrics = repaired(metadata.lyrics)

        if let duration = properties.duration, duration > 0 {
            result.durationMs = Int((duration * 1000).rounded())
        }
        if let sampleRate = properties.sampleRate, sampleRate > 0 {
            result.sampleRate = Int(sampleRate.rounded())
        }
        if let channels = properties.channelCount {
            result.channels = Int(channels)
        }
        if let bitDepth = properties.bitDepth, bitDepth > 0 {
            result.bitDepth = bitDepth
        }

        // ⚠️ 引擎给的码率**就是 kbps**（它直通解码库那个接口，单位是 kb/s），
        // 库里存的也是 kbps —— 原样收下，不做任何换算。
        // 别按「KiB / 秒」去理解它：照 KiB/秒 先 ×1024×8 再 ÷1000，显示出来的码率会大 8 倍。
        if let bitrate = properties.bitrate, bitrate > 0 {
            result.bitRate = Int(bitrate.rounded())
        } else if let duration = properties.duration, duration > 0,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            // 引擎没报码率时才估一个：文件大小 ÷ 时长 = 平均码率。
            //
            // ⚠️ 敢吞 `try?` 这一下：读不出文件大小就**不估**（码率留空）——
            // 这只是"引擎没报"时的兜底，拿不到大小宁可不写，也不写一个凭空的数。
            result.bitRate = Int((Double(size) * 8 / duration / 1000).rounded())
        }

        result.format = properties.formatName

        // 多图文件可能把封底排在前面 —— 优先挑标了「正面封面」的那张，没有再退回第一张。
        // 库里自带「按类型取」的接口（`attachedPictures(ofType:)`），不用自己遍历。
        result.artworkData = metadata.attachedPictures(ofType: .frontCover).first?.imageData
            ?? metadata.attachedPictures.first?.imageData

        return result
    }

    // MARK: - 文字编码修复

    /// 修一修再交出去；**修不动就原样**。
    ///
    /// `MetadataTextRepair.repaired` 只在"有可信候选"时才给东西，绝大多数标签它返回 `nil`，
    /// 所以这一层是"原样通过"。空字符串不进流程（没什么可修的，也省一次自检）。
    private static func repaired(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return text }
        return MetadataTextRepair.repaired(text) ?? text
    }
}

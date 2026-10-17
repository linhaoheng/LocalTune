import Foundation
import SFBAudioEngine

/// 写回音频文件里的标签 —— **全工程唯一**碰 `writeMetadata` 的地方。
///
/// 对照 primuse 的 `EmbeddedMetadataWriter` 做法：
/// - **只写改过的字段**（`changedFields`）—— 库行可能落后于文件，未改字段用空值盖回去会丢真标签；
/// - **MP3 年份**写成完整 ISO8601（SFB 对「只有年」的字符串会静默丢掉）；
/// - 写完**回读校验**改过的字段。
///
/// ⚠️ 支持的格式：`mp3` / `flac` / `m4a`。别的格式抛 `unsupportedFormat`，给人话提示。
enum MetadataWriter {

    /// 哪一栏被改过 —— 没列进集合的字段，文件里原来写什么就留什么。
    enum Field: Hashable {
        case title
        case artist
        case album
        case albumArtist
        case composer
        case genre
        case lyrics
        case releaseDate
        case comment
        case discNumber
        case discTotal
        case trackNumber
        case trackTotal
        case cover
    }

    /// 一次写回要落到文件上的内容。
    ///
    /// 字段值本身可以是空（表示「清掉」）；**会不会写这一栏**只看 `changedFields`。
    struct Edits: Equatable {
        var title: String = ""
        var artist: String = ""
        var album: String = ""
        var albumArtist: String?
        var composer: String?
        var genre: String?
        var lyrics: String?
        var releaseDate: String?
        var comment: String?
        var discNumber: Int?
        var discTotal: Int?
        var trackNumber: Int?
        var trackTotal: Int?
        /// 新封面的原始字节；`nil` 且 `changedFields` 不含 `.cover` = 不动封面。
        var coverData: Data?
        var changedFields: Set<Field>
    }

    enum WriteError: LocalizedError {
        case unsupportedFormat(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return "这种格式（.\(ext)）写不进标签"
            case .verificationFailed(let field):
                return "写完再读，「\(field)」对不上 —— 文件可能没保存成功"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .unsupportedFormat:
                return "换一首 MP3、FLAC 或 M4A 再试；或者只改库里的显示名（这一步还没做）。"
            case .verificationFailed:
                return "文件可能被占用或只读。关掉别的 App 再试一次。"
            }
        }
    }

    private static let supportedExtensions: Set<String> = ["mp3", "flac", "m4a"]

    /// 把 `edits` 写进文件，并回读校验改过的字段。
    static func write(_ edits: Edits, to fileURL: URL) throws {
        let fileExtension = fileURL.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw WriteError.unsupportedFormat(fileExtension.isEmpty ? "未知" : fileExtension)
        }

        let audioFile = try AudioFile(readingPropertiesAndMetadataFrom: fileURL)
        let metadata = audioFile.metadata

        if edits.writes(.title) { metadata.title = edits.title }
        if edits.writes(.artist) { metadata.artist = emptyToNil(edits.artist) }
        if edits.writes(.album) { metadata.albumTitle = emptyToNil(edits.album) }
        if edits.writes(.albumArtist) { metadata.albumArtist = emptyToNil(edits.albumArtist) }
        if edits.writes(.composer) { metadata.composer = emptyToNil(edits.composer) }
        if edits.writes(.genre) { metadata.genre = emptyToNil(edits.genre) }
        if edits.writes(.lyrics) { metadata.lyrics = emptyToNil(edits.lyrics) }
        if edits.writes(.comment) { metadata.comment = emptyToNil(edits.comment) }
        if edits.writes(.releaseDate) {
            metadata.releaseDate = normalizedReleaseDate(edits.releaseDate, fileExtension: fileExtension)
        }
        if edits.writes(.discNumber) { metadata.discNumber = edits.discNumber }
        if edits.writes(.discTotal) { metadata.discTotal = edits.discTotal }
        if edits.writes(.trackNumber) { metadata.trackNumber = edits.trackNumber }
        if edits.writes(.trackTotal) { metadata.trackTotal = edits.trackTotal }

        if edits.writes(.cover), let coverData = edits.coverData {
            if fileExtension == "m4a" {
                // MP4 `covr` 不保留 ID3/FLAC 那种「正面封面」角色 —— 整清再挂。
                metadata.removeAllAttachedPictures()
            } else {
                metadata.removeAttachedPicturesOfType(.frontCover)
            }
            metadata.attachPicture(AttachedPicture(imageData: coverData, type: .frontCover))
        }

        try audioFile.writeMetadata()

        let verified = try AudioFile(readingPropertiesAndMetadataFrom: fileURL).metadata
        try verify(edits, readBack: verified, fileExtension: fileExtension)
    }

    // MARK: - 私有

    private static func emptyToNil(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private static func emptyToNil(_ value: String) -> String? {
        emptyToNil(Optional(value))
    }

    /// MP3 的年份：只有四位年时写成完整 ISO8601，否则 SFB 会静默丢掉（primuse 注释原话）。
    /// FLAC / M4A 可以直接写「2019」。
    private static func normalizedReleaseDate(_ value: String?, fileExtension: String) -> String? {
        guard let raw = emptyToNil(value) else { return nil }
        guard fileExtension == "mp3", raw.count == 4, raw.allSatisfy(\.isNumber) else {
            return raw
        }
        return String(format: "%@-01-01T00:00:00Z", raw)
    }

    /// 回读校验。参数类型不写 `AudioMetadata` —— 那个名字引擎和咱们各有一份，写出来会绑错。
    private static func verify(
        _ edits: Edits,
        readBack metadata: SFBAudioEngine.AudioMetadata,
        fileExtension: String
    ) throws {
        if edits.writes(.title) {
            try requireEqual(edits.title, metadata.title ?? "", field: "标题")
        }
        if edits.writes(.artist) {
            try requireEqual(emptyToNil(edits.artist), emptyToNil(metadata.artist), field: "艺人")
        }
        if edits.writes(.album) {
            try requireEqual(emptyToNil(edits.album), emptyToNil(metadata.albumTitle), field: "专辑名")
        }
        if edits.writes(.albumArtist) {
            try requireEqual(emptyToNil(edits.albumArtist), emptyToNil(metadata.albumArtist), field: "专辑艺人")
        }
        if edits.writes(.composer) {
            try requireEqual(emptyToNil(edits.composer), emptyToNil(metadata.composer), field: "作曲者")
        }
        if edits.writes(.genre) {
            try requireEqual(emptyToNil(edits.genre), emptyToNil(metadata.genre), field: "类型")
        }
        if edits.writes(.lyrics) {
            try requireEqual(emptyToNil(edits.lyrics), emptyToNil(metadata.lyrics), field: "歌词")
        }
        if edits.writes(.comment) {
            try requireEqual(emptyToNil(edits.comment), emptyToNil(metadata.comment), field: "注释")
        }
        if edits.writes(.releaseDate) {
            let expected = normalizedReleaseDate(edits.releaseDate, fileExtension: fileExtension)
            // 回读时引擎可能把 ISO8601 缩成年 —— 比「年」那四位就够。
            try requireEqual(yearPrefix(expected), yearPrefix(metadata.releaseDate), field: "发布日期")
        }
        if edits.writes(.discNumber) {
            try requireEqual(edits.discNumber, metadata.discNumber, field: "光盘编号")
        }
        if edits.writes(.discTotal) {
            try requireEqual(edits.discTotal, metadata.discTotal, field: "光盘总数")
        }
        if edits.writes(.trackNumber) {
            try requireEqual(edits.trackNumber, metadata.trackNumber, field: "曲目编号")
        }
        if edits.writes(.trackTotal) {
            try requireEqual(edits.trackTotal, metadata.trackTotal, field: "曲目总数")
        }
        if edits.writes(.cover), edits.coverData != nil {
            let hasCover = !(metadata.attachedPictures(ofType: .frontCover).isEmpty
                && metadata.attachedPictures.isEmpty)
            guard hasCover else { throw WriteError.verificationFailed("封面") }
        }
    }

    private static func yearPrefix(_ value: String?) -> String? {
        guard let value, value.count >= 4 else { return emptyToNil(value) }
        return String(value.prefix(4))
    }

    private static func requireEqual<T: Equatable>(_ expected: T, _ actual: T, field: String) throws {
        guard expected == actual else { throw WriteError.verificationFailed(field) }
    }
}

private extension MetadataWriter.Edits {
    func writes(_ field: MetadataWriter.Field) -> Bool {
        changedFields.contains(field)
    }
}

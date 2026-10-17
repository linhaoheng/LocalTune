import Foundation
import RxRelay
import RxSwift
import UIKit

/// 歌曲信息编辑页的状态 —— 草稿 + 保存。
///
/// 🔴 不认识界面：不持有 VC、不弹窗、不挑图。页面只做订阅 → 画 → 转发。
///
/// ## 保存时机
///
/// **只有点「保存」才写盘**（含换封面）。封面进草稿、不另开一次保存 ——
/// 否则会和「保存」抢写盘，第二次被静默挡掉。
/// 标题不许空：空着点保存会弹「标题不能为空」，不静默还原。
///
/// ## 🔴 换封面为什么算两份字节
///
/// 换封面要落两处，两处的**身份不一样**，不能共用一份字节：
///
/// | 落哪 | 身份 | 怎么压 |
/// |---|---|---|
/// | `Library/custom/` | **缓存**（给屏幕看，丢了能重建） | 缩最长边 ＋ 压 JPEG |
/// | 音频文件标签里 | **数据**（跟着文件走，别的播放器也读） | **不缩边**、质量高一点 |
///
/// 共用一份，就等于拿「给屏幕」的决定去管文件 —— 缩边那一步是**为屏幕**做的，
/// 不该管到文件头上。
///
/// ## 🔴 写了文件 ⇒ 库里那份「文件状态」必须跟着换
///
/// 库里那一行有两样东西在描述**磁盘上那份文件**：`fingerprint`（内容指纹）和
/// `fileSize` / `fileModificationDate`（记号）。标签一写回文件，这两样**当场过期** ——
/// 留着旧值就是撒谎，代价是「同一份文件再导入被判成**重复跳过**」
/// 「扫描以为它变过、其实是刚改的」。所以写盘之后**当场重算、一起回库**（见 `writeTags`）。
///
/// ## 线程
///
/// 草稿与快照在主线程；写文件（含重算指纹）/ 落盘封面发到后台，结果回到主线程再更新库。
final class TrackEditorViewModel {

    // MARK: - 快照

    struct FileInfoRow: Equatable {
        var title: String
        var value: String
    }

    /// 界面要画的一切（不含图片 —— 快照必须能比较是否相等）。
    struct Snapshot: Equatable {
        var fileRows: [FileInfoRow]
        var title: String
        var album: String
        var albumArtist: String
        var artist: String
        var composer: String
        var genre: String
        var lyrics: String
        var releaseDate: String
        var discNumber: String
        var discTotal: String
        var trackNumber: String
        var trackTotal: String
        var comment: String
        /// 库里记的封面路径（可能是 `custom/…`）。
        var artworkPath: String?
        /// 刚挑还没（或刚）落盘 —— 有的话页面画待定封面图。
        var hasPendingCover: Bool
        var isSaving: Bool
        var hasChanges: Bool
    }

    let snapshot: Observable<Snapshot>

    /// 保存失败 —— 页面订阅、弹一句人话。
    let saveErrors: Observable<Error>

    /// 保存成功并该关页 —— 页面订阅、关掉这一页。
    let didSaveAndShouldDismiss: Observable<Void>

    /// 刚挑的封面图（不进快照，避免破坏相等比较）。
    var pendingCoverImage: UIImage? { draftRelay.value.pendingCoverImage }

    // MARK: - 依赖

    private let trackID: Track.ID
    private let library: LibraryStore
    private let fileURL: URL

    // MARK: - 草稿

    private let draftRelay: BehaviorRelay<Draft>
    private let isSavingRelay = BehaviorRelay(value: false)
    private let saveErrorsRelay = PublishRelay<Error>()
    private let didSaveRelay = PublishRelay<Void>()

    /// 打开页 / 上次保存成功时的底稿 —— 和草稿一样进流，快照管道才能不碰 `self`。
    private let baselineRelay: BehaviorRelay<Draft>

    private struct Draft {
        var title: String
        var album: String
        var albumArtist: String
        var artist: String
        var composer: String
        var genre: String
        var lyrics: String
        var releaseDate: String
        var discNumber: String
        var discTotal: String
        var trackNumber: String
        var trackTotal: String
        var comment: String
        var artworkPath: String?
        /// 🔴 **init 读侧表那一刻定死的事实**（全工程只有 init 一个写者）：
        /// `false` ＝ 这次**没读到**原词是什么 —— 草稿里那个空框是「不知道」，
        /// **不是「本来就没有」** ⇒ 保存一路只读这个标记：不写侧表、文件标签也不许带上歌词，
        /// 否则改个标题点保存就顺手把歌词删了。`true` ＝ 读到了（包括「真没有」——那也是知道）。
        var lyricsSourceKnown: Bool
        var pendingCoverImage: UIImage?
        /// 存进 `Library/custom/` 的那份字节 —— **缓存**，给屏幕看，缩过边、压过。
        var pendingDisplayCoverData: Data?
        /// 写进音频文件标签的那份字节 —— **数据**，跟着文件走，**不缩边**。
        var pendingEmbeddedCoverData: Data?
        var fileRows: [FileInfoRow]
    }

    /// 磁盘上那一份**写完之后的**样子 —— 库里必须跟着换的那两样。
    ///
    /// 两样都**从磁盘读**（`FileFingerprint` / `MusicFileStore.stamp`），不是算出来的预测值：
    /// 标签写回之后文件到底变成什么样，只有再读一遍才知道。
    private struct FileState {
        /// 内容指纹。
        let fingerprint: String
        /// 文件记号（大小 ＋ 修改时间）。
        let stamp: FileStamp
    }

    init(track: Track, library: LibraryStore) {
        self.trackID = track.id
        self.library = library
        let resolvedURL = MusicFileStore.resolve(relativePath: track.path)
        self.fileURL = resolvedURL

        // 🔴 **「读不到」≠「没有」**：侧表读失败时填空串就是把两件事合并成一件 ——
        // 保存时会把「不知道」当成「真没有」写回去，歌词就这么删掉的。
        // ⇒ 读成不成分开记：成功（含「真没有」，那也是知道）→ `lyricsSourceKnown = true`。
        let seedLyrics: String?
        var lyricsSourceKnown = true
        do {
            seedLyrics = try library.lyrics(for: track.id)?.lyrics
        } catch {
            seedLyrics = nil
            lyricsSourceKnown = false
        }

        let initial = Draft(
            title: track.title,
            album: track.album,
            albumArtist: track.albumArtist ?? "",
            artist: track.artist,
            composer: track.composer ?? "",
            genre: track.genre ?? "",
            // 内嵌歌词住在侧表，跟 `track` 分开取。
            lyrics: seedLyrics ?? "",
            releaseDate: Self.displayReleaseDate(track.releaseDate),
            discNumber: Self.numberString(track.discNumber),
            discTotal: Self.numberString(track.totalDiscs),
            trackNumber: Self.numberString(track.trackNumber),
            trackTotal: Self.numberString(track.totalTracks),
            comment: track.comment ?? "",
            artworkPath: track.artworkPath,
            lyricsSourceKnown: lyricsSourceKnown,
            pendingCoverImage: nil,
            pendingDisplayCoverData: nil,
            pendingEmbeddedCoverData: nil,
            fileRows: Self.makeFileRows(for: track, fileURL: resolvedURL)
        )
        draftRelay = BehaviorRelay(value: initial)
        baselineRelay = BehaviorRelay(value: initial)

        // 🔴 三条流组合出快照，闭包**不许捕获 self**：
        // 否则赋值 `snapshot = …` 时 Swift 会认为 self 还没用完（`snapshot` 自己还没初始化）。
        snapshot = Observable.combineLatest(
            draftRelay.asObservable(),
            isSavingRelay.asObservable(),
            baselineRelay.asObservable()
        )
        .map { draft, isSaving, base in
            Snapshot(
                fileRows: draft.fileRows,
                title: draft.title,
                album: draft.album,
                albumArtist: draft.albumArtist,
                artist: draft.artist,
                composer: draft.composer,
                genre: draft.genre,
                lyrics: draft.lyrics,
                releaseDate: draft.releaseDate,
                discNumber: draft.discNumber,
                discTotal: draft.discTotal,
                trackNumber: draft.trackNumber,
                trackTotal: draft.trackTotal,
                comment: draft.comment,
                artworkPath: draft.artworkPath,
                hasPendingCover: draft.pendingCoverImage != nil,
                isSaving: isSaving,
                hasChanges: !Self.sameContent(draft, base)
            )
        }
        .distinctUntilChanged()
        .share(replay: 1)

        saveErrors = saveErrorsRelay.asObservable()
        didSaveAndShouldDismiss = didSaveRelay.asObservable()

        loadFileSizeAsync()
    }

    // MARK: - 动作

    func updateTitle(_ text: String) { mutate { $0.title = text } }
    func updateAlbum(_ text: String) { mutate { $0.album = text } }
    func updateAlbumArtist(_ text: String) { mutate { $0.albumArtist = text } }
    func updateArtist(_ text: String) { mutate { $0.artist = text } }
    func updateComposer(_ text: String) { mutate { $0.composer = text } }
    func updateGenre(_ text: String) { mutate { $0.genre = text } }
    func updateLyrics(_ text: String) { mutate { $0.lyrics = text } }
    func updateReleaseDate(_ text: String) { mutate { $0.releaseDate = text } }
    func updateDiscNumber(_ text: String) { mutate { $0.discNumber = text } }
    func updateDiscTotal(_ text: String) { mutate { $0.discTotal = text } }
    func updateTrackNumber(_ text: String) { mutate { $0.trackNumber = text } }
    func updateTrackTotal(_ text: String) { mutate { $0.trackTotal = text } }
    func updateComment(_ text: String) { mutate { $0.comment = text } }

    /// 用户挑了一张新封面 —— **只进草稿**，跟改标题一样，点「保存」才落盘。
    ///
    /// ⚠️ 不在这儿单独开一次写盘：否则会和「保存」抢同一条写盘路，
    /// 第二次被「正在保存」静默挡掉（点了没反应）。
    func applyPickedCover(_ image: UIImage) {
        // 压 JPEG 在本层做（`CoverImageWriter`，`Core/UI`）—— `ArtworkStore` 只收字节。
        //
        // 🔴 **算两份，不是一份**：这两份的身份不一样，共用一份字节就等于
        // 拿「给屏幕」的决定（缩边）去管文件（见类 doc）。
        guard let displayData = CoverImageWriter.jpegDataForCustomCover(image),
              let embeddedData = CoverImageWriter.jpegDataForEmbeddedCover(image) else {
            saveErrorsRelay.accept(CoverError.cannotEncode)
            return
        }
        mutate {
            $0.pendingCoverImage = image
            $0.pendingDisplayCoverData = displayData
            $0.pendingEmbeddedCoverData = embeddedData
        }
    }

    /// 点「保存」：有改动就写盘并关页；没改动直接关。
    func saveIfNeededAndDismiss() {
        guard !Self.sameContent(draftRelay.value, baselineRelay.value) else {
            didSaveRelay.accept(())
            return
        }
        let trimmedTitle = draftRelay.value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            saveErrorsRelay.accept(CoverError.emptyTitle)
            return
        }
        persist(dismissWhenDone: true)
    }

    var hasUnsavedChanges: Bool {
        !Self.sameContent(draftRelay.value, baselineRelay.value)
    }

    // MARK: - 私有

    private func mutate(_ body: (inout Draft) -> Void) {
        var draft = draftRelay.value
        body(&draft)
        draftRelay.accept(draft)
    }

    private func persist(dismissWhenDone: Bool) {
        guard !isSavingRelay.value else { return }
        isSavingRelay.accept(true)

        let draft = draftRelay.value
        let base = baselineRelay.value
        let changed = Self.changedFields(from: base, to: draft)
        let oldArtworkPath = base.artworkPath

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.writeTagsAndArtwork(
                draft: draft,
                changed: changed,
                oldArtworkPath: oldArtworkPath,
                dismissWhenDone: dismissWhenDone
            )
        }
    }

    /// 后台：落封面 → 写文件标签（**顺带重算文件状态**）→ 回主线程改库。（`persist` 只负责开跑。）
    private func writeTagsAndArtwork(
        draft: Draft,
        changed: Set<MetadataWriter.Field>,
        oldArtworkPath: String?,
        dismissWhenDone: Bool
    ) {
        do {
            let newArtworkPath = try Self.resolveArtworkPath(draft: draft, trackID: trackID)
            let edits = Self.makeEdits(draft: draft, changed: changed)
            let fileState = try Self.writeTags(edits, to: fileURL)
            DispatchQueue.main.async {
                self.commitToDatabase(
                    draft: draft,
                    newArtworkPath: newArtworkPath,
                    oldArtworkPath: oldArtworkPath,
                    fileState: fileState,
                    dismissWhenDone: dismissWhenDone
                )
            }
        } catch {
            DispatchQueue.main.async {
                self.isSavingRelay.accept(false)
                self.saveErrorsRelay.accept(error)
            }
        }
    }

    /// 后台：把标签写进文件，并把**写完之后的**文件状态（指纹 ＋ 记号）读回来。
    ///
    /// 🔴 这两样必须跟标签**一起**回库（理由见类 doc）：文件字节被我们改过之后，
    /// 库里那一行原来记的指纹/记号就指向一份**已经不存在的字节**了 —— 后果是
    /// 「同一份文件再导入被判成重复跳过」「扫描以为它变过、其实是刚改的」。
    ///
    /// ⚠️ 没有字段要改就**不写、也不重算** —— 文件没动，指纹还是对的；
    /// 顺带省掉一次整文件哈希（无损音乐一首几十上百 MB）。
    ///
    /// - Returns: 文件**没被改写**时 `nil` —— 调用方据此不动库里那两样。
    private static func writeTags(
        _ edits: MetadataWriter.Edits, to fileURL: URL
    ) throws -> FileState? {
        guard !edits.changedFields.isEmpty else { return nil }
        try MetadataWriter.write(edits, to: fileURL)
        return fileState(of: fileURL)
    }

    /// 读**写完之后的**文件状态。
    ///
    /// 🔴 **算不出指纹不让整次保存失败**：走到这儿时标签**已经写进文件了** ——
    /// 报一句"保存失败"然后什么都不做，库里就留着**旧指纹**（正是这次要修的那个坑），
    /// 而且用户以为没保存、会再点一次。
    ///
    /// ⇒ 算不出就记**空串**（`Track.fingerprint` 里「还没算过」那个说法）：
    /// 空指纹**不参与判重**（`ImportDuplicatePolicy` 两边都挡着），所以不会误报「重复跳过」；
    /// 下次扫描见它是空的会重算补上（`scanOne` → `saveFingerprint`），**自己就好了**。
    ///
    /// ⚠️ 记号照读：读不出就是「不知道」，扫描下次会重读一遍 —— 方向是安全的。
    private static func fileState(of fileURL: URL) -> FileState {
        // 敢吞 `try?` 这一下：理由见上（库必须跟上文件；补得回来）。
        let fingerprint = (try? FileFingerprint.sha256(of: fileURL)) ?? ""
        return FileState(fingerprint: fingerprint, stamp: MusicFileStore.stamp(of: fileURL))
    }

    /// 主线程：读回那一行、改字段、写库、删旧封面、复位双 relay。
    private func commitToDatabase(
        draft: Draft,
        newArtworkPath: String?,
        oldArtworkPath: String?,
        fileState: FileState?,
        dismissWhenDone: Bool
    ) {
        do {
            guard var track = try library.track(id: trackID) else {
                throw CoverError.trackGone
            }
            let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else {
                throw CoverError.emptyTitle
            }
            track.title = trimmedTitle
            track.artist = draft.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            track.album = draft.album.trimmingCharacters(in: .whitespacesAndNewlines)
            track.albumArtist = Self.optionalText(draft.albumArtist)
            track.composer = Self.optionalText(draft.composer)
            track.genre = Self.optionalText(draft.genre)
            track.releaseDate = Self.optionalText(draft.releaseDate)
            track.comment = Self.optionalText(draft.comment)
            track.discNumber = Self.intValue(draft.discNumber)
            track.totalDiscs = Self.intValue(draft.discTotal)
            track.trackNumber = Self.intValue(draft.trackNumber)
            track.totalTracks = Self.intValue(draft.trackTotal)
            track.artworkPath = newArtworkPath
            // 🔴 文件被改写时，指纹和记号**必须跟着换**（见 `writeTags`）：
            // 它们描述的就是磁盘上那份文件，留在旧值上等于库里记着一份**不存在的东西**。
            if let fileState {
                track.fingerprint = fileState.fingerprint
                track.fileSize = fileState.stamp.fileSize
                track.fileModificationDate = fileState.stamp.fileModificationDate
            }
            try library.update(track)
            // 🔴 **内嵌歌词单独写** —— 它住在侧表（`TrackLyrics`），不在 `tracks` 那一行上。
            // ⚠️ 两条写**不合成一个事务**是有意的：这一步的"上游"是**已经写进音频文件**的标签，
            // 万一这里失败，库与文件下一次重扫**自己就对上了**（侧表那份是文件标签的镜像）
            // ⇒ 有自愈路径，不另加一层兜底。
            // 🔴 **init 没读到原词就整个不碰**（`lyricsSourceKnown`，事实由 init 一个写者定）——
            // 这时候草稿里那个空框是「不知道」，把它写回去等于删词。
            if draft.lyricsSourceKnown {
                try library.setLyrics(Self.optionalText(draft.lyrics), for: track.id)
            }

            if let oldArtworkPath, oldArtworkPath != newArtworkPath {
                ArtworkStore.delete(artworkPath: oldArtworkPath)
            }

            var cleared = draft
            cleared.title = trimmedTitle
            cleared.artworkPath = newArtworkPath
            cleared.pendingCoverImage = nil
            cleared.pendingDisplayCoverData = nil
            cleared.pendingEmbeddedCoverData = nil
            baselineRelay.accept(cleared)
            draftRelay.accept(cleared)
            isSavingRelay.accept(false)
            if dismissWhenDone {
                didSaveRelay.accept(())
            }
        } catch {
            isSavingRelay.accept(false)
            saveErrorsRelay.accept(error)
        }
    }

    /// 新封面要写进库的路径：这轮换了封面就落盘拿新路径，否则沿用 `draft` 里的。
    ///
    /// 🔴 **返回 `String?` 不是偷懒，是这首歌真的可能没有封面** ——
    /// `Track.artworkPath` 本身就是可选（没抓到内嵌封面的歌就是 `nil`）。
    /// 声明成非可选，就等于逼着调用方编一个 `""` 出来写进库 —— 那是**撒谎**，
    /// 编译器报错只是替我们拦住了它。
    private static func resolveArtworkPath(draft: Draft, trackID: String) throws -> String? {
        guard let coverData = draft.pendingDisplayCoverData else {
            return draft.artworkPath
        }
        guard let saved = ArtworkStore.saveCustom(coverData, named: trackID) else {
            throw CoverError.cannotSave
        }
        return saved
    }

    /// `Draft` → 文件标签改写。**纯函数** —— 不落盘、不碰 relay。
    private static func makeEdits(
        draft: Draft,
        changed: Set<MetadataWriter.Field>
    ) -> MetadataWriter.Edits {
        var edits = MetadataWriter.Edits(changedFields: changed)
        edits.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        edits.artist = draft.artist
        edits.album = draft.album
        edits.albumArtist = Self.optionalText(draft.albumArtist)
        edits.composer = Self.optionalText(draft.composer)
        edits.genre = Self.optionalText(draft.genre)
        edits.lyrics = Self.optionalText(draft.lyrics)
        edits.releaseDate = Self.optionalText(draft.releaseDate)
        edits.comment = Self.optionalText(draft.comment)
        edits.discNumber = Self.intValue(draft.discNumber)
        edits.discTotal = Self.intValue(draft.discTotal)
        edits.trackNumber = Self.intValue(draft.trackNumber)
        edits.trackTotal = Self.intValue(draft.trackTotal)
        if let coverData = draft.pendingEmbeddedCoverData {
            edits.coverData = coverData
            edits.changedFields.insert(.cover)
        }
        return edits
    }

    private func loadFileSizeAsync() {
        let url = fileURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 敢吞：文件大小是只读补充信息，读失败就整行不出现，不挡编辑。
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let self, let size else { return }
            let text = Self.byteString(size)
            DispatchQueue.main.async {
                self.applyFileSize(text)
            }
        }
    }

    /// 「文件大小」这一行：已有就改值，没有就插在第 3 行（`min(2, count)`）。
    /// **纯函数** —— 不碰 relay，好断言。
    static func rowsBySettingFileSize(_ rows: [FileInfoRow], text: String) -> [FileInfoRow] {
        var rows = rows
        if let index = rows.firstIndex(where: { $0.title == "文件大小" }) {
            rows[index].value = text
        } else {
            rows.insert(FileInfoRow(title: "文件大小", value: text), at: min(2, rows.count))
        }
        return rows
    }

    /// 把读到的文件大小同步进底稿（补充只读信息，不算「用户改动」）。
    private func applyFileSize(_ text: String) {
        let rows = Self.rowsBySettingFileSize(draftRelay.value.fileRows, text: text)
        var draft = draftRelay.value
        draft.fileRows = rows
        var base = baselineRelay.value
        base.fileRows = rows
        baselineRelay.accept(base)
        draftRelay.accept(draft)
    }

    private static func sameContent(_ a: Draft, _ b: Draft) -> Bool {
        a.title == b.title
            && a.album == b.album
            && a.albumArtist == b.albumArtist
            && a.artist == b.artist
            && a.composer == b.composer
            && a.genre == b.genre
            && a.lyrics == b.lyrics
            && a.releaseDate == b.releaseDate
            && a.discNumber == b.discNumber
            && a.discTotal == b.discTotal
            && a.trackNumber == b.trackNumber
            && a.trackTotal == b.trackTotal
            && a.comment == b.comment
            && a.artworkPath == b.artworkPath
            && a.pendingDisplayCoverData == b.pendingDisplayCoverData
    }

    private static func changedFields(from old: Draft, to new: Draft) -> Set<MetadataWriter.Field> {
        var fields = Set<MetadataWriter.Field>()
        if old.title != new.title { fields.insert(.title) }
        if old.artist != new.artist { fields.insert(.artist) }
        if old.album != new.album { fields.insert(.album) }
        if old.albumArtist != new.albumArtist { fields.insert(.albumArtist) }
        if old.composer != new.composer { fields.insert(.composer) }
        if old.genre != new.genre { fields.insert(.genre) }
        // 🔴 原词是「不知道」时歌词字段**整个退出这次保存**（`lyricsSourceKnown` 一处判，
        // 侧表 / 文件标签两路都看它）—— 空框上打的字是半盲编辑，写回去可能盖掉文件里
        // 用户没见过的词。要改歌词，重开一次页面（读到了再改）。
        if old.lyrics != new.lyrics, new.lyricsSourceKnown { fields.insert(.lyrics) }
        if old.releaseDate != new.releaseDate { fields.insert(.releaseDate) }
        if old.comment != new.comment { fields.insert(.comment) }
        if old.discNumber != new.discNumber { fields.insert(.discNumber) }
        if old.discTotal != new.discTotal { fields.insert(.discTotal) }
        if old.trackNumber != new.trackNumber { fields.insert(.trackNumber) }
        if old.trackTotal != new.trackTotal { fields.insert(.trackTotal) }
        return fields
    }

    private static func makeFileRows(for track: Track, fileURL: URL) -> [FileInfoRow] {
        var rows: [FileInfoRow] = [
            FileInfoRow(title: "文件名", value: fileURL.lastPathComponent),
            FileInfoRow(title: "文件位置", value: fileURL.deletingLastPathComponent().lastPathComponent),
        ]
        if let duration = track.durationText {
            rows.append(FileInfoRow(title: "时间", value: duration))
        }
        if let bitRate = track.bitRate, bitRate > 0 {
            rows.append(FileInfoRow(title: "比特率", value: "\(bitRate) kbps"))
        }
        if let sampleRate = track.sampleRate, sampleRate > 0 {
            let khz = Double(sampleRate) / 1000
            let text = khz.rounded() == khz
                ? String(format: "%.0f kHz", khz)
                : String(format: "%.1f kHz", khz)
            rows.append(FileInfoRow(title: "采样率", value: text))
        }
        if let channels = track.channels, channels > 0 {
            rows.append(FileInfoRow(title: "通道数", value: "\(channels)"))
        }
        return rows
    }

    private static func displayReleaseDate(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        if value.count >= 4, value.prefix(4).allSatisfy(\.isNumber) {
            return String(value.prefix(4))
        }
        return value
    }

    private static func numberString(_ value: Int?) -> String {
        guard let value, value > 0 else { return "" }
        return "\(value)"
    }

    private static func intValue(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(trimmed), number > 0 else { return nil }
        return number
    }

    private static func optionalText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func byteString(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 0.1 { return String(format: "%.2f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private enum CoverError: LocalizedError {
        case cannotEncode
        case cannotSave
        case trackGone
        case emptyTitle

        var errorDescription: String? {
            switch self {
            case .cannotEncode: return "这张图没法当成封面用"
            case .cannotSave: return "封面存不到手机里"
            case .trackGone: return "这首歌已经不在曲库里了"
            case .emptyTitle: return "标题不能为空"
            }
        }
    }
}

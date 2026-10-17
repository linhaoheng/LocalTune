import Foundation

/// 处理**一个文件**：算指纹（只读）→ 读标签（只读，同时是校验）→ 拷 / 查 → **落进库**。
///
/// ⚠️ **这个顺序是硬规矩：有副作用的动作必须排在决策之后。**
/// 具体说：查（算指纹、读标签）全是只读的，**先做完**；之后才拷进沙盒、才写库。
///
/// 不要为了「少读一遍文件」把"拷贝"和"算指纹"合成一步（边拷边算）：
/// 那样**打不开的文件**先被拷进来，读标签那一步才发现读不了 —— 沙盒里留下孤儿文件，
/// 还得再写一段清理逻辑。宁可每首多读一遍。
///
/// ## 🔴 身份是路径，跳过问内容
///
/// 一首歌的主键是**它在 `music/` 里的路径**（见 `TrackIdentity`）。
/// 「库里是不是已经有这首」问的是内容指纹：另有活文件 ⇒ 跳过（`.duplicate`）；
/// 死行不挡。导入和扫描共用 `ImportDuplicatePolicy`。
///
/// 指纹因此有两用：① 认「磁盘上已经有一份同名同内容的副本」（`copyAndPrepare` 第 2 步）；
/// ② 按内容跳过。扫描也要哈希 —— 省掉就只剩半条规矩。
///
/// ## 🔴 处理完**立刻**写库（一首一首，不攒批）
///
/// 这一首算完就写进去 —— 用户看到的就是"收一首、列表里多一首"。
/// 唯一的代价在**几千首的首次导入**：库里每写一次都会让观察重读整张曲库、
/// 页面重建整张列表（详见 `ImportService` 顶上那段）。
///
/// ⚠️ **落库的四个动作（封面先落盘 → 写库 → 收拾旧封面 / 失败撤回）的顺序见 `write`** ——
/// 顺序反了会看到"某一行一直没有封面，滚出去再滚回来才有"。
struct TrackImporter {

    let store: LibraryStore

    // MARK: - 两条路各一条

    /// 「打开文件」的一条：文件在沙盒**外**，要拷进来。
    ///
    /// 步骤编号在下面每一步的注释里（`importOne` 是 1，`copyAndPrepare` 接着 2–5）——
    /// 出问题时照着号看一眼就知道卡在哪一步。
    func importOne(_ source: URL) async -> ImportOutcome {
        let fileName = source.lastPathComponent

        // 1. 算指纹（只读）—— 只为了第 2 步认「磁盘上是不是已经有一份同名同内容的副本」
        let fingerprint: String
        do {
            fingerprint = try FileFingerprint.sha256(of: source)
        } catch {
            return .failed(ImportFailure(
                fileName: fileName,
                reason: Self.failureReason(for: error, fallback: .copyFailed),
                detail: error.localizedDescription
            ))
        }

        return await copyAndPrepare(source, fileName: fileName, fingerprint: fingerprint)
    }

    /// `importOne` 剩下的那一段：能复用磁盘上现成的那一份就复用，否则读标签、拷进来、取库里旧行。
    private func copyAndPrepare(
        _ source: URL, fileName: String, fingerprint: String
    ) async -> ImportOutcome {
        // 2. 磁盘上已经躺着一份**同名又同内容**的？→ 直接用那一份，**不要再拷一份**
        //
        // 两种情况会走到这儿：① 删除时只删了库行、文件留在 `music/` 里（孤儿）；
        // ② 用户把同一个文件又选了一遍。两种都是"想把这个文件放回库里"，
        // 而不是"想在磁盘上再要一份"—— 不认它的话会拷出「歌 2.mp3」。
        //
        // ⚠️ 判据是**同名 + 同内容**两个都要：名字对上才可能是同一个文件，
        // 内容对上才敢确定没认错（同名不同内容 = 这个位置已经换成别的歌了）。
        //
        // ⚠️ 这一份**不是我们建的**，所以 `copiedByUs: false`：写库失败时不能撤它。
        if let reusable = MusicFileStore.reusableCopy(ofFileName: fileName, matching: fingerprint) {
            let existing: Track?
            do {
                existing = try existingTrack(for: reusable)
            } catch {
                return .failed(ImportFailure(
                    fileName: fileName, reason: .databaseFailed, detail: error.localizedDescription
                ))
            }
            if existing != nil {
                return .unchanged
            }
            return await index(
                reusable, existing: nil, stamp: MusicFileStore.stamp(of: reusable),
                copiedByUs: false, fingerprint: fingerprint
            )
        }

        do {
            if try store.hasLiveDuplicate(fingerprint: fingerprint) {
                return .duplicate
            }
        } catch {
            return .failed(ImportFailure(
                fileName: fileName, reason: .databaseFailed, detail: error.localizedDescription
            ))
        }

        // 3. 读标签（只读，同时是校验）—— 打不开的文件压根不该拷进沙盒
        let metadata: AudioMetadata
        do {
            metadata = try MetadataReader.read(source)
        } catch {
            return .failed(ImportFailure(
                fileName: fileName, reason: .invalidAudioFile, detail: error.localizedDescription
            ))
        }

        // 4. 拷贝（重名自动加 " 2" / " 3"，不覆盖、不删原件）
        let destination: URL
        do {
            destination = try MusicFileStore.uniqueDestination(for: fileName)
            try MusicFileStore.copy(from: source, to: destination)
        } catch {
            return .failed(ImportFailure(
                fileName: fileName,
                reason: Self.failureReason(for: error, fallback: .copyFailed),
                detail: error.localizedDescription
            ))
        }

        // 5. 按**目标文件**问一次库里有没有它那一行
        //
        // 拷进来之后才第一次按**路径**问「这个位置在库里是哪一行」——
        // 上一次导入留下的那一行要保住它的导入时间和播放次数。
        let existing: Track?
        do {
            existing = try existingTrack(for: destination)
        } catch {
            return .failed(ImportFailure(
                fileName: fileName, reason: .databaseFailed, detail: error.localizedDescription
            ))
        }

        return await save(
            fileURL: destination, metadata: metadata,
            existing: existing, stamp: MusicFileStore.stamp(of: destination), copiedByUs: true,
            fingerprint: fingerprint
        )
    }

    /// 「扫描」的一条：文件已经在 `Documents/music/` 里了。
    ///
    /// 路径对上且记号没变、指纹也有了 ⇒ `.unchanged`。
    /// 否则哈希，按内容跳过或写库。
    func scanOne(_ fileURL: URL) async -> ImportOutcome {
        let fileName = fileURL.lastPathComponent
        let stamp = MusicFileStore.stamp(of: fileURL)

        let existing: Track?
        do {
            existing = try existingTrack(for: fileURL)
        } catch {
            return .failed(ImportFailure(
                fileName: fileName, reason: .databaseFailed, detail: error.localizedDescription
            ))
        }

        if let existing,
           !Self.needsMetadataRefresh(existing, stamp: stamp),
           !existing.fingerprint.isEmpty {
            return .unchanged
        }

        let fingerprint: String
        do {
            fingerprint = try FileFingerprint.sha256(of: fileURL)
        } catch {
            return .failed(ImportFailure(
                fileName: fileName,
                reason: Self.failureReason(for: error, fallback: .copyFailed),
                detail: error.localizedDescription
            ))
        }

        if let existing, !Self.needsMetadataRefresh(existing, stamp: stamp) {
            return await saveFingerprint(existing, fingerprint: fingerprint)
        }

        return await index(
            fileURL, existing: existing, stamp: stamp, copiedByUs: false, fingerprint: fingerprint
        )
    }

    /// 两条路合流的那一段：读标签（只读，同时是校验）→ 落进库。
    ///
    /// - Parameter copiedByUs: 这个文件是不是**我们自己刚拷进来的** —— 只决定一件事：
    ///   写库失败时要不要把它撤掉（见 `rollBack`）。
    private func index(
        _ fileURL: URL, existing: Track?, stamp: FileStamp, copiedByUs: Bool, fingerprint: String
    ) async -> ImportOutcome {
        // 读标签（只读，同时是校验）
        let metadata: AudioMetadata
        do {
            metadata = try MetadataReader.read(fileURL)
        } catch {
            return .failed(ImportFailure(
                fileName: fileURL.lastPathComponent,
                reason: .invalidAudioFile,
                detail: error.localizedDescription
            ))
        }

        return await save(
            fileURL: fileURL, metadata: metadata,
            existing: existing, stamp: stamp, copiedByUs: copiedByUs, fingerprint: fingerprint
        )
    }

    /// **算出这一行、落进库** —— 一个文件的处理到这儿结束。
    ///
    /// **封面和「行」是一条，但封面必须先落盘**：
    /// 行是**权威**（库里认它），封面是**缓存**（没有它这首歌照样能用）——
    /// 所以"封面存不上"永远不该让这首歌算失败（见 `ArtworkStore.save`，它自己不抛错）。
    ///
    /// 🔴 但**落盘顺序是封面在前、行在后**，而且**写成之后才收拾旧封面** ——
    /// 四步顺序一步都不能换，理由写在 `write` 里（反了就会看到"某一行一直没有封面，
    /// 滚出去再滚回来才有"）。
    ///
    /// 那「库里记了名字、图片没存上」怎么办？——**能自愈**，靠 `needsMetadataRefresh`：
    /// 它认「记了名字但文件不在」这一种，下次扫描会用同一个名字重存一次。
    ///
    /// - Parameter existing: 库里**这个文件对应的那一行**（没有就是 `nil`），由调用方带进来 ——
    ///   见 `existingTrack` 的说明。它身上有三样**必须接住**的东西：导入时间、播放次数，
    ///   以及**原来那张封面的名字**（换封面时要把它删掉）。
    /// - Parameter stamp: 这份文件的记号（大小 + 修改时间），**由调用方读好带进来**。
    ///   整个文件的处理只拍**这一张快照**：「扫描」路开头那次读取，既用来判"要不要刷新标签"，
    ///   也从这里接着传下来写进库 —— 判定的依据和记录下来的结果**保证是同一份**，
    ///   不存在"判的时候是一份、写的时候又重读一份"的缝隙。
    private func save(
        fileURL: URL, metadata: AudioMetadata,
        existing: Track?, stamp: FileStamp, copiedByUs: Bool, fingerprint: String
    ) async -> ImportOutcome {
        let fileName = fileURL.lastPathComponent
        let relativePath = MusicFileStore.relativePath(of: fileURL)
        let id = TrackIdentity.stableID(forRelativePath: relativePath)

        // 封面**该叫什么名字** —— 纯计算，磁盘上什么都不动。
        //
        // 🔴 **标签读出的封面**：每次都按这一趟读到的内容重算名字（带内容指纹），
        // 内容变了名字就变 ⇒ 缓存键变了 ⇒ 一定拿到新图。
        // 🔴 **用户手挑的封面是数据**：在 `Library/custom/`，重扫不许用文件里抠出来的图顶掉它。
        let keepingCustomCover = existing?.artworkPath.map(ArtworkStore.isCustomArtworkPath) == true
        let artworkPath: String?
        let artworkDataToSave: Data?
        if keepingCustomCover {
            artworkPath = existing?.artworkPath
            artworkDataToSave = nil
        } else {
            artworkPath = metadata.artworkData.flatMap {
                ArtworkStore.artworkFileName(for: $0, named: id)
            }
            artworkDataToSave = metadata.artworkData
        }

        let track = Track(
            id: id,
            path: relativePath,
            fileName: fileName,
            fingerprint: fingerprint,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            albumArtist: metadata.albumArtist,
            genre: metadata.genre,
            composer: metadata.composer,
            comment: metadata.comment,
            releaseDate: metadata.releaseDate,
            trackNumber: metadata.trackNumber,
            totalTracks: metadata.totalTracks,
            discNumber: metadata.discNumber,
            totalDiscs: metadata.totalDiscs,
            durationMs: metadata.durationMs,
            bitRate: metadata.bitRate,
            sampleRate: metadata.sampleRate,
            bitDepth: metadata.bitDepth,
            channels: metadata.channels,
            format: metadata.format,
            artworkPath: artworkPath,
            fileSize: stamp.fileSize,
            fileModificationDate: stamp.fileModificationDate,
            // ⚠️ 这两样**必须从库里那一行接着用**，不能拿新值顶掉：
            // 「这首是哪天进来的」和「这首被听过多少次」是**这首文件的经历**，
            // 不是"这次读标签读到的"东西。丢掉前者会让「按导入时间排序」错乱，
            // 丢掉后者等于用户重新扫一次库、播放次数全清零。
            // （只保前者、不保后者是常见的漏法 —— 我们两样都保。）
            dateAdded: existing?.dateAdded ?? Date(),
            playCount: existing?.playCount ?? 0,
            // ⚠️ 同理（见上）：**用户编辑的自定义歌词要接着用库里的那一份** ——
            // 它不属于"这次读标签读到的东西"。拿 `metadata` 顶掉 ＝ 用户白编辑一次。
            customLyrics: existing?.customLyrics ?? ""
        )

        let wrote = write(
            track,
            // 🔴 内嵌歌词**不跟着 `Track` 走**（它住在侧表 `TrackLyrics`）——
            // 从这一趟读到的 `metadata` 单独交给写口，由它在**同一事务**里写侧表。
            embeddedLyrics: metadata.lyrics,
            artworkData: artworkDataToSave,
            // 旧封面的名字接在这儿 —— 换封面时新名字和它不一样，写库成功后要把它删掉，
            // 不然每换一次封面，`Library/images/` 里就多一个没人认领的孤儿。
            // ⚠️ 保住手挑封面时**不传**旧路径：那张还在用，删了就丢了。
            replacing: keepingCustomCover ? nil : existing?.artworkPath,
            copiedRelativePath: copiedByUs ? relativePath : nil
        )
        // 🔴 库里原本就有这一行（按路径认出来的）⇒ 这一趟只是把它**刷新**了，列表一行都没多 ——
        // 该报「已在库」，不是「已导入」（翻译在 `ImportOutcome.reported`）。
        return ImportOutcome.reported(wrote, insertingNewRow: existing == nil)
    }

    /// 把这一首**落下去**：封面先落盘 → 写库 → 写成了才收拾被顶替的旧封面，没写成撤干净。
    ///
    /// 🔴 **四步的顺序一步都不能换**（第一条是实机反馈换来的，不是随手定的）：
    ///
    /// 1. **封面先落盘**。行一进库，列表下一秒就把它摆出来 —— 而列表那边「**行出现了**」
    ///    和「**封面文件到了**」是**两件互不相干的事**：单元格只在自己被配置的那一刻读一次封面，
    ///    差量刷新**不会**因为"某个文件后到了"去重画内容没变的行。
    ///    ⇒ 封面只要晚一步落盘，那一行就会**一直**是音符占位，直到被滚出屏幕、
    ///    cell 复用、重新配置一次为止。所以这里立一条不变式：
    ///    **行能被看见的时候，它的封面必然已经在盘上。**
    /// 2. **写库**（一次事务，只写这一首）。
    /// 3. **写成了**才删被顶替的旧封面。⚠️ 名字没变就不删 —— 那是这首歌**正在用的**那张
    ///    （内容没变时新旧同名）。
    /// 4. **没写成**把这一首留下的痕迹撤干净（见 `rollBack`）。
    ///
    /// - Parameters:
    ///   - artworkData: 这一趟从标签里读到的封面字节；这首没有封面就是 `nil`。
    ///   - replacedArtworkPath: 库里原来记着的封面名（要被顶替的那张）。
    ///   - copiedRelativePath: 这个文件是**我们自己刚拷进来**的话，记着它在 `music/` 里的路径 ——
    ///     写库失败时**只能撤自己拷的**，把用户原来那份删掉就是事故。
    ///
    /// - Returns: 写库的结果。⚠️ 这里的 `.imported` 只说「**这一行写进去了**」——
    ///   「库里原本有没有这一行」**不归它管**（它不知道，`existing` 在 `save` 手上）。
    ///   报给用户之前由 `save` 翻译一次（`ImportOutcome.reported`）。
    private func write(
        _ track: Track,
        embeddedLyrics: String?,
        artworkData: Data?,
        replacing replacedArtworkPath: String?,
        copiedRelativePath: String?
    ) -> ImportOutcome {
        // 1. 封面先落盘
        //
        // ⚠️ **这一步和下一步之间有个毫秒级的窗口**：封面写好了、库还没写 —— 这会儿要是
        //    App 崩溃 / 被系统杀掉 / 断电，盘上就留一张**没人引用**的封面。
        //
        //    **这个取舍是想清楚了才定的，就这么放着**：
        //    · 新增导入那条路**会自愈**：同一首歌下次进来会用**同一个名字**把它盖掉
        //      （名字 = 歌曲 id + 封面内容指纹，同一首歌同一张图必然同名）；
        //    · "刷新已有行"那条路（换过封面的歌）留下的那张不会被盖，会一直躺着 ——
        //      它只有几十 KB，而且不参与任何判断（库里记的是另一个名字）；
        //    · ⇒ **不做「孤儿封面清理」**（扫一遍 `Library/images/` 再查库、删掉没人引用的）：
        //      为几十 KB 每趟导入多扫一遍目录（几千张封面一顿读盘）不划算；
        //    · 🔴 写库失败那条路**不靠这个窗口兜** —— 靠 `rollBack`（撤自己拷的音轨 + 刚落的封面）。
        //
        //    换来的是一条硬保证：**行能被看见的时候，它的封面必然已经在盘上**（理由见上面第 1 条）。
        if let artworkData, let artworkPath = track.artworkPath {
            ArtworkStore.save(artworkData, as: artworkPath)
        }

        // 2. 写库（同内容活文件已在库 ⇒ 不写，自己刚拷的撤掉）
        do {
            let wrote = try store.saveSkippingLiveDuplicate(track, embeddedLyrics: embeddedLyrics)
            if !wrote {
                rollBack(
                    copiedRelativePath: copiedRelativePath,
                    writtenArtworkPath: track.artworkPath,
                    replacedArtworkPath: replacedArtworkPath
                )
                return .duplicate
            }
        } catch {
            rollBack(
                copiedRelativePath: copiedRelativePath,
                writtenArtworkPath: track.artworkPath,
                replacedArtworkPath: replacedArtworkPath
            )
            return .failed(ImportFailure(
                fileName: track.fileName,
                reason: .databaseFailed,
                detail: error.localizedDescription
            ))
        }

        // 3. 行进库了，才收拾被顶替的旧封面
        if let replacedArtworkPath, replacedArtworkPath != track.artworkPath {
            ArtworkStore.delete(artworkPath: replacedArtworkPath)
        }
        return .imported
    }

    /// 路径已在库、记号没变，只把缺的指纹补上 —— 对用户仍是「已在库」。
    private func saveFingerprint(_ existing: Track, fingerprint: String) async -> ImportOutcome {
        var updated = existing
        updated.fingerprint = fingerprint
        do {
            _ = try store.saveSkippingLiveDuplicate(updated)
            return .unchanged
        } catch {
            return .failed(ImportFailure(
                fileName: existing.fileName,
                reason: .databaseFailed,
                detail: error.localizedDescription
            ))
        }
    }

    /// 写库失败 —— 把这一首留下的痕迹撤干净。
    ///
    /// 撤两样，都是"库没写成、于是**没人认领**"的东西：
    /// - **我们自己拷进来的那份音频** —— 留着就是「磁盘上有、库里没有」的孤儿，
    ///   用户下次重新导入还会再多拷一份。`copiedRelativePath` 是 `nil`（扫描那条路，
    ///   文件本来就在 `music/` 里）时就什么都不动。
    /// - **刚落到盘上的那张封面** —— 但**只在名字和原来不同的时候**：同名意味着那本来就是
    ///   这首歌已有的封面（内容没变），库里那一行还指着它，删了才是事故。
    ///
    /// ⚠️ **不抛错、不上报**：撤不掉就算了 —— 留一份孤儿文件没有危害
    /// （音频下次扫描会照常收进库；封面下次导入同一首歌会用同一个名字把它覆盖掉），
    /// 为它再抛一次错反而会把真正的失败原因（写库为什么失败）盖掉。
    private func rollBack(
        copiedRelativePath: String?, writtenArtworkPath: String?, replacedArtworkPath: String?
    ) {
        if let copiedRelativePath {
            MusicFileStore.delete(relativePath: copiedRelativePath)
        }
        guard let writtenArtworkPath, writtenArtworkPath != replacedArtworkPath else { return }
        ArtworkStore.delete(artworkPath: writtenArtworkPath)
    }

    // MARK: - 判定

    /// 读库里「这个文件对应的那一行」。
    ///
    /// 主键按**相对 `Documents/music` 的路径**算（见 `TrackIdentity`），
    /// 所以同一个文件在哪儿问都是同一行。
    ///
    /// ⚠️ 只有**两个入口**读它：`scanOne` 和 `copyAndPrepare`。
    /// `save` 只算不读、也不写 —— 那一行由调用方带进来，否则扫描那条路会对同一行读两遍。
    private func existingTrack(for fileURL: URL) throws -> Track? {
        let id = TrackIdentity.stableID(forRelativePath: MusicFileStore.relativePath(of: fileURL))
        return try store.track(id: id)
    }

    /// 二次扫描提速：这一行的标签**还需不需要重读一遍**？
    static func needsMetadataRefresh(_ track: Track, stamp: FileStamp) -> Bool {
        // 库里记了封面名字、但那个文件不在磁盘上 → 重读一次把它补回来。
        //
        // 这一条是**补上漏掉的一环**：光有一句「库里记了名字、文件没存上，下次刷新标签会用
        // 同一个名字重存一次，自己就好了」其实**不成立** ——
        // 因为「要不要刷新标签」原本**只看修改时间和大小，不看封面文件在不在**，
        // 文件没动过就永远轮不到「刷新标签」。补上这一条，它才真的成立。
        //
        // 只在**记过**封面时才会命中，所以「本来就没有封面的歌」不会因此每趟重读。
        if let artworkPath = track.artworkPath, !ArtworkStore.exists(artworkPath: artworkPath) {
            return true
        }
        guard let storedModificationDate = track.fileModificationDate else { return true }
        if let current = stamp.fileModificationDate, current != storedModificationDate {
            return true
        }
        if let current = stamp.fileSize, current != track.fileSize {
            return true
        }
        return false
    }

    /// 把系统错误归类成给用户看的说法。
    ///
    /// 只认系统那套错误码（`NSCocoaErrorDomain`）；认不出来的就用调用方给的兜底值 ——
    /// **不硬猜**：猜错了用户会拿着一句错话去查一个不存在的问题。
    static func failureReason(for error: Error, fallback: FailureReason) -> FailureReason {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return fallback }
        switch CocoaError.Code(rawValue: nsError.code) {
        case .fileNoSuchFile:
            return .notFound
        case .fileReadNoPermission, .fileWriteNoPermission:
            return .permissionDenied
        case .fileWriteOutOfSpace:
            return .notEnoughSpace
        default:
            return fallback
        }
    }
}

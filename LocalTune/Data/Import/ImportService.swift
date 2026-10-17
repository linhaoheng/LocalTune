import Foundation

/// 导入 / 扫描的入口。两条流程：
///
/// - **`importFiles(_:)`** —— 「打开文件」：接文件选择器给的一堆 URL，逐个拷进沙盒再入库。
/// - **`scanLibrary()`** —— 「扫描本地音频」：递归扫 `Documents/music/`，磁盘上有、库里没有就进库。
///   **只管导入，不删库**。
///
/// ⚠️ 本类的方法**都不是** `@MainActor`，这是有意的：
/// 非主线程隔离的 `async` 方法**不继承调用方的线程** —— 所以读标签、拷文件、写库
/// 这些重活都在后台跑，界面不会被卡住（界面那边直接 `Task { await service.… }` 就行）。
/// 唯一回到主线程的是**进度回调**。
///
/// ## 🔴 写库是**一首一首**的
///
/// `TrackImporter` 处理完一个文件就把这一首写进库（见它里面的 `write`）——
/// 所以列表是"收一首、多一首"，进度条也是平滑地涨。
///
/// ⚠️ **代价要清楚**：库里每写一次，都会让观察**重读整张曲库**、页面**重建整张列表** ——
/// 所以这条路在**几千首的首次导入 / 首次扫描**上会明显更慢（每收一首就重做一遍这两件事）。
/// 「攒够一批再写」能把这两件事的次数压到 1/32，代价是列表成批地冒出来、进度跳着走 ——
/// **用户明确选了"一首一首"**（要"看着顺畅"，接受大库首次导入慢一些）。
/// 真要再拿回速度，正确的方向是让那一侧的观察别每次都读整库，而不是回来攒批。
///
/// ⚠️ **库出口是构造时传进来的**，不走全局容器 —— 数据只从 `LibraryStore` 进出，
/// 别的层不许自己碰库（也就没有"从哪儿都能拿到库连接"那种口子）。
final class ImportService {

    private let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
    }

    /// 扫描时**同时**处理几个文件。
    ///
    /// 读标签是这一趟里最慢的一步，串行做会把大曲库的扫描拖得很长。
    /// 4 路是个折中：再高对磁盘和 CPU 收益递减，反而拖慢前面那个"打开文件"的路。
    ///
    /// ⚠️ 这 4 路会**同时**往库里写（每一路算完就写自己那一首）—— 库那边是**串行**的
    /// （`DatabaseQueue` 把写入排队），所以不会打架，只是会轮流排一下队。
    static let maximumConcurrentScans = 4

    // MARK: - 打开文件

    /// 把用户选中的文件（或文件夹）拷进沙盒并入库。
    ///
    /// 串行处理：这条路用户就在旁边看着进度，串行能让浮层上的文件名和进度**对得上**；
    /// 而且这条路通常只有几首到几十首，快慢差别不明显。
    func importFiles(
        _ pickedURLs: [URL],
        onProgress: @MainActor @Sendable (ImportProgress) -> Void
    ) async -> ImportResult {
        var result = ImportResult()
        let importer = TrackImporter(store: store)
        await onProgress(ImportProgress(phase: .discovering))

        // 第一遍只读：把要处理的文件数出来 —— 进度条**要有分母**才能画。
        // 这一遍不碰磁盘内容、也不写库，纯粹是"数一数"。
        var targets: [(file: URL, owner: URL)] = []

        // ⚠️ **按文件路径去重**：用户完全可能把同一个文件选两遍、或者选了一个文件夹
        // 又单独选了里面的某个文件。那是**一个文件**，不是两首歌（身份是路径 ——
        // 见 `TrackImporter` 顶上那段）；不去重的话磁盘上会多拷一份副本、库里也多一行。
        var pickedPaths: Set<String> = []

        for pickedURL in pickedURLs {
            do {
                let scan = try await MusicFileStore.withSecurityScope(pickedURL) { () -> LocalAudioScanner.ScanOutcome in
                    // ⚠️ 敢吞 `try?` 这一下：连"是不是目录"都读不出来时，就当它**不是** ——
                    // 按单个文件往下走。这样后面真去读它时，报出来的是**它自己的毛病**
                    // （格式 / 权限），比在这儿先抛一句模糊的"读不到属性"更清楚。
                    let isDirectory =
                        (try? pickedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    guard isDirectory else {
                        // 单选一个文件：它的"父目录"就是它自己的位置，不存在读不进去的兄弟目录。
                        return LocalAudioScanner.ScanOutcome(audioFiles: [pickedURL], unreadableFolders: [])
                    }
                    // 选的是文件夹就把里面的音频都算上（递归）。
                    return try LocalAudioScanner.collectAudioFiles(in: pickedURL)
                }
                // 读不进去的子目录**要报出来**（见 `ImportResult.unreadableFolders`）：
                // 用户以为这一趟把整个文件夹都收进来了，其实有目录被跳过 —— 不报就等于没发生过。
                for folder in scan.unreadableFolders {
                    result.recordUnreadableFolder(named: folder.lastPathComponent)
                }
                // `owner` 记着"这个文件是从哪个选择结果里来的" —— 沙盒外的 URL 要成对开安全域，
                // 文件本身那个 URL 开不了，得用选择器给的那一个。
                for file in scan.audioFiles
                where pickedPaths.insert(file.standardizedFileURL.path).inserted {
                    targets.append((file: file, owner: pickedURL))
                }
            } catch {
                result.record(ImportFailure(
                    fileName: pickedURL.lastPathComponent,
                    reason: TrackImporter.failureReason(for: error, fallback: .copyFailed),
                    detail: error.localizedDescription
                ))
            }
        }

        var progress = ImportProgress(phase: .processing, total: targets.count)
        await onProgress(progress)

        for target in targets {
            // ⚠️ 这一遍回调要排在**处理之前** ——
            // 排在后面的话，浮层上写的永远是「上一首」，正在处理的那首反而看不到。
            progress.currentFileName = target.file.lastPathComponent
            await onProgress(progress)

            let outcome: ImportOutcome
            do {
                outcome = try await MusicFileStore.withSecurityScope(target.owner) {
                    await importer.importOne(target.file)
                }
            } catch {
                outcome = .failed(ImportFailure(
                    fileName: target.file.lastPathComponent,
                    reason: TrackImporter.failureReason(for: error, fallback: .copyFailed),
                    detail: error.localizedDescription
                ))
            }

            Self.apply(outcome, to: &result)
            progress.processed += 1
            // 跑的过程中只报这一个数（见 `ImportProgress`）——
            // 它是"真的进库了"的个数，**写成一首就涨一首**（每首自己落库，见 `TrackImporter.write`）。
            progress.imported = result.imported
            await onProgress(progress)
        }

        return result
    }

    // MARK: - 扫描本地音频

    /// 扫 `Documents/music/`：磁盘上有的、库里还没有的，收进库。
    ///
    /// ⚠️ **枚举失败不再吞掉**：把异常吞成"没找到文件"，等于「扫描发现 0 首」和
    /// 「扫描读不出来」是同一个结果 —— 用户看到「0 首」根本不知道出事了。
    func scanLibrary(
        onProgress: @MainActor @Sendable (ImportProgress) -> Void
    ) async -> ImportResult {
        var result = ImportResult()
        let importer = TrackImporter(store: store)
        await onProgress(ImportProgress(phase: .discovering))

        let root: URL
        do {
            root = try MusicFileStore.ensureMusicDirectory()
        } catch {
            result.record(ImportFailure(
                fileName: MusicFileStore.musicDirectory.lastPathComponent,
                reason: TrackImporter.failureReason(for: error, fallback: .copyFailed),
                detail: error.localizedDescription
            ))
            return result
        }

        let scan: LocalAudioScanner.ScanOutcome
        do {
            scan = try LocalAudioScanner.collectAudioFiles(in: root)
        } catch {
            result.record(ImportFailure(
                fileName: root.lastPathComponent,
                reason: TrackImporter.failureReason(for: error, fallback: .copyFailed),
                detail: error.localizedDescription
            ))
            return result
        }

        // 读不进去的子目录**要报出来**（见 `ImportResult.unreadableFolders`）：
        // 「有一整个文件夹没读进去」和「那个文件夹本来就没歌」在结果上必须分得开。
        for folder in scan.unreadableFolders {
            result.recordUnreadableFolder(named: folder.lastPathComponent)
        }

        let files = scan.audioFiles
        var progress = ImportProgress(phase: .processing, total: files.count)
        await onProgress(progress)

        // ⚠️ **并发的那几路只管处理文件，绝不碰进度。**
        // 进度统一从这个 `while` 循环里发 —— 它跑在**本函数自己的上下文**里，
        // 于是 `result` / `progress` 只被这一条路径改，不用加锁，
        // 也不会有两份进度交叉着报。
        // ⚠️ 那几路会各自写自己那一首（库里串行排队），所以「谁写」这件事不归这里管。
        await withTaskGroup(of: (String, ImportOutcome).self) { group in
            var next = 0

            // 先把前 4 条塞进去，之后「出一条、补一条」，保持 4 路满载。
            while next < min(Self.maximumConcurrentScans, files.count) {
                Self.addScanTask(to: &group, fileURL: files[next], importer: importer)
                next += 1
            }

            while let done = await group.next() {
                Self.apply(done.1, to: &result)
                progress.processed += 1
                progress.currentFileName = done.0
                // 写成一首就涨一首（理由见 `importFiles`）。
                progress.imported = result.imported
                await onProgress(progress)

                if next < files.count {
                    Self.addScanTask(to: &group, fileURL: files[next], importer: importer)
                    next += 1
                }
            }
        }

        // 注意：这里用的是**子任务**（`withTaskGroup`），不是游离的 `Task { }` ——
        // 外面一取消（用户退出这个页面），正在跑的那几路会跟着停，不会在后台自顾自扫完。

        // 🔴 收完新歌**还不算完** —— 还要反过来核对一遍：库里那些行，它指的文件还在不在。
        //
        // 这是「**磁盘是真相、库是索引**」的另一半。原来只做了「磁盘有、库没有 → 收进来」，
        // 另一半一直是空白，于是库里的行会**一直**假装文件还在。
        //
        // ⚠️ 复用这一趟**已经枚举出来的** `files` / `scan.unreadableFolders` —— 不重新扫一遍盘。
        reconcileMissingFiles(diskFiles: files, unreadableFolders: scan.unreadableFolders)

        return result
    }

    // MARK: - 对账：库里那些行，文件还在不在

    /// 扫完之后的反向核对（判据全在 `LibraryReconcile`，这里只负责把料凑齐、把结果写下去）。
    ///
    /// ⚠️ **读的是库、不是 `store.tracksNow`**：那是观察推给主线程的内存镜像，可能滞后，
    /// 而这一趟跑在后台。
    ///
    /// ⚠️ 对账失败**不打断这一趟导入**（`try?` 吞掉）：导入是这一趟的主业，对账是附带；
    /// 而且它**幂等**，下一次扫描会自己修好。**不往 `ImportResult` 里塞一条「对账失败」** ——
    /// 那会让用户看到一条他既看不懂、也不知道该怎么办的错。
    private func reconcileMissingFiles(diskFiles: [URL], unreadableFolders: [URL]) {
        let presentPaths = Set(diskFiles.map { MusicFileStore.relativePath(of: $0) })
        let unreadablePrefixes = Set(unreadableFolders.map { MusicFileStore.relativePath(of: $0) })
        guard let entries = try? store.reconcileEntries() else { return }

        let plan = LibraryReconcile.plan(
            presentPaths: presentPaths,
            unreadablePrefixes: unreadablePrefixes,
            entries: entries
        )
        // 🔴 没有真变化就**一行都不写** —— 写下去会让观察重跑、整张列表重建，
        // 而绝大多数时候一个字都没变（`LibraryReconcile` 顶上第一条红线）。
        guard !plan.isEmpty else { return }

        let now = Date()
        try? store.markMissing(trackIDs: plan.markMissing, at: now)
        try? store.clearMissing(trackIDs: plan.clearMissing)
    }

    private static func addScanTask(
        to group: inout TaskGroup<(String, ImportOutcome)>,
        fileURL: URL,
        importer: TrackImporter
    ) {
        group.addTask {
            let outcome = await importer.scanOne(fileURL)
            return (fileURL.lastPathComponent, outcome)
        }
    }

    // MARK: - 收结果

    /// 把一份的处理结果累加进总结果。
    ///
    /// ⚠️ **`.imported` 是真的写进库了**（`TrackImporter.save` 里写成了、**而且是新插了一行**才返回它）——
    /// 所以到这儿直接计数就对了，不用再等谁落库。
    private static func apply(_ outcome: ImportOutcome, to result: inout ImportResult) {
        switch outcome {
        case .imported: result.imported += 1
        case .unchanged: result.alreadyInLibrary += 1
        case .duplicate: result.duplicateSkipped += 1
        case .failed(let failure): result.record(failure)
        }
    }
}

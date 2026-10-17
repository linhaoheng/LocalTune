import Foundation

/// 一趟导入 / 扫描的结果。
///
/// ⚠️ **这三个数必须把这一趟处理过的每一份都装进去**：
/// `imported + alreadyInLibrary + duplicateSkipped + failed` = 处理过的总数。
/// 少算一类，结束那一屏上的数字就会看着自相矛盾。
///
/// 🔴 **「已导入」数的是「列表真的多了几行」** —— 库里原本就有这一行、这一趟只是把它刷新了
/// （重读了标签），**不算**：报「已导入」而列表一行没多，就是在撒谎。那一种算进「已在库」。
///
/// 「已在库」＝ 磁盘上这一份就是库里那一行（**按路径**认出来的，不管这一趟有没有顺手刷新它）。
/// 「重复跳过」＝ 另有一份**内容一样且文件还在**（`ImportDuplicatePolicy`）。
/// 两件事不能并成一个数。
///
/// ⚠️ `unreadableFolders` **不参与上面那个和** —— 数的是**文件夹**，不是文件：
/// 一个文件夹里本来有几首歌不知道，硬塞进「处理过的总数」会让等式变成假的。
struct ImportResult: Equatable, Sendable {

    /// **库里原本没有这一行**、这一趟真的新收进来了 —— 列表**多了这么几行**。
    ///
    /// ⚠️ 库里原本就有这一行、这一趟只是把它的标签刷新了一遍的，**不算**（报「已在库」）——
    /// 这条界线就是浮层那句话的字面意思。
    var imported = 0

    /// 「**磁盘上这一份就是库里那一行**」—— 按**路径**认出库里那一行。
    ///
    /// ⚠️ 这一趟**可能顺手把它的标签刷新了**（文件记号变了就重读一遍），但**列表一行都没多** ——
    /// 所以还是「已在库」，不是「已导入」。
    var alreadyInLibrary = 0

    /// 「另有一份内容一样、文件还在」—— 打开文件和扫描都会出。
    var duplicateSkipped = 0

    var failed = 0

    /// 有几个文件夹**读不进去**、被跳过了。
    ///
    /// 🔴 它**不是「失败」**（那 N 个文件夹不等于 N 首失败：里面有几首不知道，而且
    /// 扫描照样跑完了），但也**绝不能吞掉** —— 用户看不到这个数，就会以为
    /// 「扫完了、就这些歌」，其实有一整个文件夹的歌没进来。
    ///
    /// ⚠️ **不许把它并进「空目录」**：那两件事在结果上必须能区分。
    var unreadableFolders = 0

    /// 第一个读不进去的文件夹名 —— 结束那一屏要显示得下具体是哪个。
    ///
    /// 跟 `firstFailure` 一样**只留第一条**：浮层就一行，列一串没人看。
    var firstUnreadableFolder: String?

    /// 失败明细 —— **只留第一条**。
    ///
    /// 结束那一屏只显示一条，存一整个数组等于存下十几条永远没人看的记录。
    var firstFailure: ImportFailure?

    /// 记一条失败：**只计数 + 留住第一条**。
    mutating func record(_ failure: ImportFailure) {
        failed += 1
        if firstFailure == nil { firstFailure = failure }
    }

    /// 记一个读不进去的文件夹：**只计数 + 留住第一个**。
    mutating func recordUnreadableFolder(named name: String) {
        unreadableFolders += 1
        if firstUnreadableFolder == nil { firstUnreadableFolder = name }
    }
}

/// 一条失败明细。
///
/// `detail` 存系统给的原始错误原文 —— 只在「文件读不出来」时显示，
/// 界面拿它给用户看真因，而不是自己编一句。
struct ImportFailure: Equatable, Sendable {

    /// 出问题的那一份（音频文件名，或者文件夹名）。
    let fileName: String
    let reason: FailureReason

    /// 系统给的原始错误原文。没有就不填。
    let detail: String?
}

/// 失败原因分类。
///
/// 只留我们这两条流程真的会遇到的几种。网盘那几种
/// （`coordinatedReadFailed` / `providerReturnedError`）—— 我们没有那一层，不搬。
enum FailureReason: Equatable, Sendable {

    /// 这个格式引擎读不了（不在支持列表里）。
    case unsupportedFormat
    /// 文件不在了（被删了 / 拔了）。
    case notFound
    /// 没权限读。
    case permissionDenied
    /// 空间不够。
    case notEnoughSpace
    /// 文件在、但引擎打不开（半截文件 / 不是真音频）。
    case invalidAudioFile
    /// 写库失败。
    case databaseFailed
    /// 拷进沙盒失败。
    case copyFailed

    /// 给用户看的说法。
    var label: String {
        switch self {
        case .unsupportedFormat: "格式不支持"
        case .notFound: "文件不在了"
        case .permissionDenied: "没有读取权限"
        case .notEnoughSpace: "空间不够"
        case .invalidAudioFile: "文件读不出来"
        case .databaseFailed: "写库失败"
        case .copyFailed: "拷贝失败"
        }
    }
}

/// 处理**一个文件**之后的结果。
///
/// 它和 `ImportResult` 是"一件"和"一箱"的关系：`ImportService` 每处理完一份，
/// 就把这里的一个值累加进 `ImportResult`（见 `ImportService.apply(_:to:)`）。
///
/// ⚠️ `.imported` **是真的写进库了** —— `TrackImporter.save` 里写成了才返回它，
/// 不是"算好了、等着写"。所以它一到手就能直接计数，不用再等谁。
enum ImportOutcome: Equatable, Sendable {

    /// **库里原本没有这一行**、真的新收进来了 —— 列表多了这一行。
    case imported
    /// 就是库里那一份（**按路径**认出来的）—— 可能顺手刷新了它的标签，但**没有新行**。
    case unchanged
    /// 另有一份内容一样、文件还在 —— 不拷、不进新行。
    case duplicate
    case failed(ImportFailure)
}

extension ImportOutcome {

    /// 把「真的写进去了」翻译成**该报给用户的那个结果**。
    ///
    /// 🔴 **「已导入」只留给"库里原本没有这一行"**：刷新库里已有的一行**不是导入** ——
    /// 列表一行都没多，报「已导入」就是撒谎（`ImportResult.imported` 那句话的字面意思
    /// 就是"列表多了几首"）。
    ///
    /// ⚠️ 用 `switch` 不图省事：将来多一种结果，这里**编译不过** —— 逼着加的人先定它算不算「导入」。
    ///
    /// - Parameter insertingNewRow: 这一趟往库里**新插**了一行吗（＝ 库里原本没有它）。
    static func reported(_ wrote: ImportOutcome, insertingNewRow: Bool) -> ImportOutcome {
        guard !insertingNewRow else { return wrote }
        // 库里原本就有这一行 ⇒ 写成功只是"把它刷新了" ⇒ 报「已在库」。
        switch wrote {
        case .imported: return .unchanged
        case .unchanged, .duplicate, .failed: return wrote
        }
    }
}

import CryptoKit
import Foundation

/// 一份字节的 SHA256 —— 用来回答「**这份内容跟那份是不是同一份**」。
///
/// 它服务的是**同一件事**的三个落点：
/// - **认「磁盘上已经有一份同样的副本」**（`MusicFileStore.reusableCopy`）：
///   用户把同一个文件又选一遍、或者删库时把文件留在了 `music/` 里 ——
///   认出那一份就收进库，不要拷出第二份；
/// - **一张封面的名字里那一段**（`ArtworkStore.artworkFileName`）：内容一变名字就变，
///   图片缓存跟着自动失效（封面字节是内存里的，走 `Data` 那一版）；
/// - `TrackImporter.importOne` 里算源文件的哈希，交给第一条用。
///
/// 身份仍是路径（`TrackIdentity`）。指纹给 `ImportDuplicatePolicy` 认「同一份字节」：
/// 库里已有活文件就不拷第二份；死行不挡重导入。
/// 扫描也要哈希 —— 「是不是同一首歌」两条路共用这一问，省掉哈希就只剩半条规矩。
///
/// 分块读（256 KB 一块），不把整首歌读进内存 —— 无损音乐一首几十上百 MB，
/// 整个读进来在导入一批文件时会直接把内存顶爆。
///
/// ⚠️ **必须真读文件内容**：只把「相对路径 + 时长」拼成字符串再 SHA256 那种做法，
/// 换过编码的同一首歌会被当成两份，第一条用处就会失灵。
enum FileFingerprint {

    /// 一次读多少（256 KB）。
    static let bufferSize = 256 * 1024

    /// 算文件的 SHA256（64 个十六进制字符）。
    ///
    /// 循环里放 `Task.checkCancellation()`：导入大文件时会被随时取消
    /// （用户划走、或者退出导入），能取消就得能立刻停。
    static func sha256(of url: URL, bufferSize: Int = FileFingerprint.bufferSize) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        // 读完就关。**关不掉也敢吞**：`FileHandle` 在它自己被释放时还会再关一次，
        // 这里只是早点归还句柄 —— 为一次"迟早会关掉"的失败去中断整首歌的导入，不值得。
        defer { try? input.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: max(4 * 1024, bufferSize)) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 算**已经在手上的一段字节**的 SHA256 —— 同一个算法、同一种输出。
    ///
    /// 单独要一个 `Data` 版本是为了封面：封面字节是标签里读出来的，本来就在内存里，
    /// 再落一次盘只为了算出文件名，纯属白费。**两版输出的口径必须一样**
    /// （64 个十六进制字符），否则「内容变了没有」这件事在不同地方会有两种答案。
    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

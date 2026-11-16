import CryptoKit
import Foundation

/// 一首歌的**身份** —— 也就是 `Track.id` 是怎么算出来的。
///
/// 🔴 **身份（要稳定）和内容指纹（会变）是两个概念，合并就错。**
/// 指纹见 `FileFingerprint`；三条路的对比：
///
/// | 用什么当身份 | 会怎样 |
/// |---|---|
/// | 随机 UUID | 身份由「哪一次导入」决定 → 删掉再导入就成了新的一首，**收藏和歌单全丢** |
/// | 内容指纹 | 内容一变身份就变 → **改个歌名这首歌就变成「另一首」** |
/// | **相对路径**（选它） | 只要文件还在原处，身份就不变 —— 删了再导入回来还是同一首，收藏和歌单跟得住 |
///
/// ⚠️ 必须是**相对** `Documents/music` 的路径，不能是绝对路径：
/// iOS 的沙盒容器路径每次重装 / 更新都会变（`.../Application/<一串 UUID>/Documents/...`），
/// 用绝对路径的话，**每次 App 更新，库里所有歌的身份全变**，收藏和歌单全军覆没。
enum TrackIdentity {

    /// 相对路径 → 主键（相对路径的 SHA256，64 个十六进制字符）。
    static func stableID(forRelativePath relativePath: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalPath(relativePath).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Foundation 在根上做了软链的几个目录：`/var` → `/private/var` 等等。
    private static let privatePrefixedRoots = ["/private/var", "/private/tmp", "/private/etc"]

    /// 把路径规范成**唯一**的写法。
    ///
    /// 比 `standardizedFileURL` 多做一步：那个调用**也会**去掉开头的 `/private`，
    /// 但**只在路径当时能在磁盘上解析出来**的时候 —— 它要问文件系统。
    /// 于是同一个文件会按「这一刻看不看得见」产出两种拼法、两个都号称「稳定」的主键。
    /// （Cosmos 为此踩过坑：主键一翻转，那行就被当成「文件移动过」重新建，
    /// 挂在旧主键底下的封面、歌词全成了孤儿。）
    ///
    /// **无条件剥掉前缀**，答案才是字符串的纯函数 —— 这才是「稳定」该有的意思。
    static func canonicalPath(_ path: String) -> String {
        var canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        for prefix in privatePrefixedRoots where canonical == prefix || canonical.hasPrefix(prefix + "/") {
            canonical.removeFirst("/private".count)
            break
        }
        return canonical
    }
}

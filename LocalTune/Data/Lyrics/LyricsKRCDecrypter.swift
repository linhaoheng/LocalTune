import Compression
import Foundation

/// 把酷狗下载回来的**KRC 密文**解成明文（`[ti:…]` ＋ `[起,长]<起,长,0>字…` 那一套）。
///
/// 纯函数、零 UIKit、不联网。
///
/// ## 归 `Data/` 的理由
///
/// 它是"把拿到的东西读出来"，产物**还是外部格式 KRC** —— 与我们正文同源的换算才进
/// `Playback/Decisions/`（`LyricsExternalFormatPolicy`）。
///
/// ## 四步（key 是写死的常量，不是登录态 ⇒ 零鉴权）
///
/// 1. `content` 做 **base64** 解码；
/// 2. **丢掉前 4 字节** —— 就是 `krc18` 那层壳（`LDDC` 里叫 `KRC_MAGICHEADER`）；
/// 3. 用 **16 字节固定 key** 逐字节**循环 XOR**（下标取模）；
/// 4. **剥 2 字节 zlib 头** → inflate → UTF-8。
///
/// ## 🔴 两个坑（都是实测踩出来的）
///
/// - **砍不砍首字符**：`Lyricify` 的解密器最后有一句 `res[1..]`（砍掉明文第一个字符）。
///   实测**明文第一个字符本来就是 `[`**（前 12 字节 `5b 74 69 3a …` ⇒ `[ti:`），
///   不是 BOM ⇒ 它砍掉的就是方括号本身。它砍了不出事，只因为它自己的下游
///   （`KrcParser.GetSplitedKrc`）**只收 `[` 开头的行** ⇒ 被砍残的首行自动丢。
///   ⚠️ 万一某首 KRC **第一行就是歌词**，砍掉 `[` 会把整句歌词丢掉。
///   `LDDC`（Python）**不砍** ⇒ **我们也不砍**（这是与 Lyricify 的一处**有意偏离**，
///   不砍的结果与它**一样**，理由写在 `获取歌词-酷狗源.md` §C）。
/// - **Apple 的 `COMPRESSION_ZLIB` 吃的是「裸 deflate」**，不是带头 zlib 流。
///   `Lyricify`（SharpZipLib）/ `LDDC`（Python zlib）两家的库**自己会读掉那 2 字节头**，
///   所以它们源码里看不见这一步；Apple 的 API 不会 ⇒ 直接喂 `78 9c …` 会吐垃圾。
///   **先剥那 2 字节**再喂，一次到底。尾巴那 4 字节 adler32 不用管
///   （裸 inflater 在 deflate 结束标记处自己停）。
enum LyricsKRCDecrypter {

    /// 16 字节固定 key。
    private static let decryptKey: [UInt8] = [
        0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
        0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
    ]

    /// base64 的 KRC 密文 → 明文。任何一步读不出 ⇒ `nil`（**不猜、不兜**）。
    static func decrypt(_ encrypted: String) -> String? {
        guard let raw = Data(base64Encoded: encrypted), raw.count > 4 else { return nil }

        // ② 丢掉前 4 字节的壳，③ 逐字节循环 XOR（连那 2 字节 zlib 头也一起 XOR）。
        var bytes = [UInt8](raw.dropFirst(4))
        for index in bytes.indices {
            bytes[index] ^= decryptKey[index % decryptKey.count]
        }

        // ④ 剥 2 字节 zlib 头 → inflate。
        guard bytes.count > 2 else { return nil }
        guard let inflated = inflate(Data(bytes.dropFirst(2))) else { return nil }
        return String(data: inflated, encoding: .utf8)
    }

    // MARK: - 私有 · inflate

    /// 裸 deflate 流 → 原始字节（`COMPRESSION_ZLIB` 自带的流式接口）。
    private static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }

        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK
        else { return nil }
        defer { compression_stream_destroy(stream) }

        var output = Data()
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.src_ptr = source
            stream.pointee.src_size = data.count

            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(
                    stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    output.append(buffer, count: bufferSize - stream.pointee.dst_size)
                default:
                    // 出错 ⇒ 已写进 output 的那点也丢掉（不吐半截）。
                    output.removeAll()
                    return
                }
                if status == COMPRESSION_STATUS_END { return }
            }
        }
        return output.isEmpty ? nil : output
    }
}

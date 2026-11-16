import Compression
import Foundation

/// 通用二进制歌词解码：`magic + xor(repeating-key) + zlib` → 文本。
///
/// 照 primuse `XorZlibLyricsDecoder` 的思路，但**不带任何平台常量**：
/// `magic` / `xorKey` 由源配置的 `secrets` 给（键名照 primuse：
/// `lyricsMagicHex` / `lyricsXorKeyHex`）。
///
/// ⚠️ 只做解压，不做格式转换 —— 解出来是什么文本（KRC 布局 / ELRC）就交给 `LyricsParser`。
enum LyricsBinaryDecoder {

    /// 同一份东西，外面还包了一层 base64（JSON 里 `content` 那种写法）。
    ///
    /// 与 `decode(_:magicHex:xorKeyHex:)` 同一条契约：解不出来 ⇒ `nil`。
    static func decode(base64 content: String, magicHex: String, xorKeyHex: String) -> String? {
        guard let data = Data(base64Encoded: content) else { return nil }
        return decode(data, magicHex: magicHex, xorKeyHex: xorKeyHex)
    }

    /// 解不出来 ⇒ `nil`（magic 不匹配 / key 非法 / zlib 坏 / 校验和不符）。
    static func decode(_ data: Data, magicHex: String, xorKeyHex: String) -> String? {
        guard let magic = HexBytes.decode(magicHex),
              let key = HexBytes.decode(xorKeyHex),
              !key.isEmpty,
              data.count > magic.count,
              Array(data.prefix(magic.count)) == magic
        else { return nil }

        let body = data.subdata(in: magic.count..<data.count)
        var xored = Data(count: body.count)
        for index in 0..<body.count {
            xored[index] = body[index] ^ key[index % key.count]
        }

        guard let inflated = inflate(zlib: xored) else { return nil }
        return String(data: inflated, encoding: .utf8)
    }

    // MARK: - 私有

    /// zlib（2 字节头 ＋ raw deflate ＋ 4 字节 Adler-32）—— **流式**解。
    ///
    /// 一块 64KB 反复用，峰值内存就一块；一次性 `compression_decode_buffer` 要预申请 16MB
    /// 目标缓冲（KRC 实际只有几 KB），为这点数据占那么多不值得。
    private static func inflate(zlib data: Data) -> Data? {
        guard data.count > 6 else { return nil }
        let cmf = Int(data[0])
        let flg = Int(data[1])
        guard cmf & 0x0F == 8, ((cmf << 8) | flg) % 31 == 0 else { return nil }

        let raw = data.subdata(in: 2..<(data.count - 4))
        let expectedChecksum = data.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let chunkSize = 64 * 1024
        let maxOutputBytes = 16 * 1024 * 1024

        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { scratch.deallocate() }
        var stream = compression_stream(
            dst_ptr: scratch,
            dst_size: 0,
            src_ptr: UnsafePointer(scratch),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(&stream) }

        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { destination.deallocate() }

        return raw.withUnsafeBytes { buffer -> Data? in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = raw.count
            var output = Data()

            while true {
                stream.dst_ptr = destination
                stream.dst_size = chunkSize
                let status = compression_stream_process(
                    &stream,
                    Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                let produced = chunkSize - stream.dst_size
                if produced > 0 { output.append(destination, count: produced) }
                guard output.count <= maxOutputBytes else { return nil }

                switch status {
                case COMPRESSION_STATUS_END:
                    guard !output.isEmpty, adler32(output) == expectedChecksum else { return nil }
                    return output
                case COMPRESSION_STATUS_ERROR:
                    return nil
                default:
                    // 既没产出、源也读完了 —— 流提前断了（坏档）。
                    if produced == 0, stream.src_size == 0 { return nil }
                }
            }
        }
    }

    private static func adler32(_ data: Data) -> UInt32 {
        let modulus: UInt32 = 65_521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % modulus
            b = (b + a) % modulus
        }
        return (b << 16) | a
    }
}

import Foundation

/// 十六进制串 → 字节 —— **全工程只有这一份**。
///
/// 解码器的 `magicHex` / `xorKeyHex`、脚本助手的 seed 都走它。
/// 允许中间有空白、大小写都行；长度必须是偶数。空串 ⇒ 空数组（调用方自己判空）。
enum HexBytes {

    static func decode(_ hex: String) -> [UInt8]? {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

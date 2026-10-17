import Foundation

/// 「这份内容是不是已经作为**活文件**在库里」—— **纯函数**，导入和扫描共用。
///
/// 身份仍是路径（`TrackIdentity`）。指纹只回答「字节是不是同一份」。
/// 两条路都问这一句，不各写各的。
///
/// 🔴 **死行不能跳过**：库里有指纹、文件没了，再导入必须能救回来
/// 所以不是「库里有这个指纹就跳」，
/// 是「另有一条路径、文件还在」。
enum ImportDuplicatePolicy {

    /// - Parameter incomingRelativePath: 这一次要落成的相对路径。
    ///   还没拷进 `music/` 时传空 —— 库里任何活着的同内容都算「另有一份」。
    /// - Parameter otherPaths: 库里指纹对上的那些行的路径（可以含自己）。
    /// - Parameter isLive: 这条相对路径在磁盘上是不是还在。
    static func hasLiveDuplicate(
        ofRelativePath incomingRelativePath: String,
        otherPaths: [String],
        isLive: (String) -> Bool
    ) -> Bool {
        otherPaths.contains { path in
            path != incomingRelativePath && isLive(path)
        }
    }
}

import UIKit

/// 网络封面的**字节 → 图 ＋ 缓存** —— 通用读图器，不认识"哪个源"。
///
/// ## 🔴 它为什么住在 `Core`
///
/// 跟 `ThumbnailLoader` 一个道理（见 `ArtworkProvider.swift` 顶上那段）：
/// 解码 ＋ 缓存属于**界面这一侧**；"去哪个 URL 取字节"是 `Data` 的事。
/// 两边分开之后，`Data/Artwork/CoverSources/` 那一摊**连 `UIKit` 都不用 import**。
///
/// ⚠️ 依赖方向没歪：`Data` 层不碰这里，是 `Features` 层的 ViewModel 先拿到字节、
/// 再交给这里解码 —— 谁也不用认识谁。
///
/// ## 缓存键是 **URL**
///
/// 同一个 URL 只下一次；列表缩略图和大图是**两个不同的 URL**，天然分两份、不会互相盖掉。
/// 而两个源都是"尺寸写进地址"那种（酷狗 `{size}` / QQ `T002R{size}x{size}`）⇒
/// 内容变了地址也变 ⇒ **不需要** `invalidateCache()` 那种口子。
enum CoverImageLoader {

    /// 下过的图。条数封顶 —— 封面是**缓存**，踢掉重下即可。
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    /// 已经下过的那张（`nil` ＝ 还没下）。
    static func cached(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// 把刚取到的字节解成图并记下来。
    ///
    /// ⚠️ **认不出图就返回 `nil`，不抛错、也不缓存** —— 图是缓存，
    /// 解不出来只是这一格画占位底，不配让整页算失败。
    static func store(_ data: Data, for url: URL) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

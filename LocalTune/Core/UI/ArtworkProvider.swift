import ImageIO
import UIKit

/// 从一个**图片文件**读出「只够画这么大」的那张缩略图 —— 通用读图器，不认识封面 / 曲库。
///
/// 🔴 **它为什么住在 `Core`**：解码 + 缓存属于**界面这一侧**（参数是"点"和"屏幕倍数"），
/// 而"封面存在哪个目录"是 `Data` 的事。两边分开之后：`Data` 只给**文件 URL**，
/// 这里只管"给个 URL、按尺寸出图" —— 谁也不用认识谁，依赖方向没歪。
///
/// ⚠️ 唯一反向的那一下是 `invalidateCache()`：文件被删 / 被覆盖时 `ArtworkStore` 调它
/// （`Data → Core` 是合法方向）。缓存必须跟着文件失效，所以这个口子不能省。
enum ThumbnailLoader {

    /// 读一张图 —— **按你打算画多大**给你。读不出来返回 `nil`，不抛错。
    ///
    /// 🔴 **为什么必须说尺寸**：原图常是一两千像素，而列表里那一格只有 45 点。
    /// 不按尺寸取就等于每次都把整张图解出来再缩 —— 内存和 CPU 都白花，几百首一滚就看得出。
    /// 给了尺寸就走系统的**缩略图解码**，它**不会**先解整张。
    ///
    /// ⚠️ 缓存键**把尺寸和倍数都算进去**：同一个文件、不同大小是两张图。
    /// 只用文件名当键的话，列表先要 45、播放页再要另一档，后者会拿到 45 那张（糊的）。
    ///
    /// ⚠️ 图是**缓存**，读不到就是暂时没图，界面画个占位底即可 —— 所以不报错、也不记日志。
    ///
    /// - Parameters:
    ///   - fileURL: 图片文件在哪。
    ///   - pointSize: 要多大（**点**，跟界面里的单位一致）。
    ///   - displayScale: 屏幕倍数，把"点"换算成"像素"。
    ///   ⚠️ **必须由调用方给**，这里不自己取：后台线程上取不到当前屏幕的倍数
    ///   （只会拿到默认值），在 @3x 的机器上就会出一张偏小的图。
    ///   界面里有视图的用 `view.traitCollection.displayScale`；没有视图可挂时再用 `UITraitCollection.current`。
    static func image(at fileURL: URL, pointSize: CGSize, displayScale: CGFloat) -> UIImage? {
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }

        let key = "\(fileURL.absoluteString)#\(Int(pointSize.width))x\(Int(pointSize.height))@\(displayScale)x" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = thumbnail(at: fileURL, pointSize: pointSize, displayScale: displayScale) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 文件被删 / 被覆盖了 —— 这张图在内存里那几份都得作废。
    ///
    /// ⚠️ 缓存键带尺寸（一个文件可能同时有好几份），而 `NSCache` **没法遍历**、
    /// 也就没法"只踢掉这一个文件的那几份" ⇒ 整层清掉。删图是低频操作，下次重读一遍盘就是了。
    static func invalidateCache() {
        cache.removeAllObjects()
    }

    // MARK: - 私有

    /// 真去读盘、出一个小图。
    ///
    /// 走 `CGImageSourceCreateThumbnailAtIndex` —— 这是**只取要用的那点像素**的读法：
    /// `kCGImageSourceThumbnailMaxPixelSize` 告诉它"最长边别超过这个像素数"，
    /// 它就不会把整张图解出来。
    ///
    /// ⚠️ **不用** `UIImage(contentsOfFile:)` 再自己缩 —— 那是"先解整张再缩"，
    /// 正是这里要躲开的那种浪费。
    private static func thumbnail(
        at fileURL: URL,
        pointSize: CGSize,
        displayScale: CGFloat
    ) -> UIImage? {
        let maxPixel = max(pointSize.width, pointSize.height) * displayScale
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            // 图本身比要的还小时也照样出图 —— 不然小图会直接失败、变成"没图"。
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // 按图自带的朝向摆正：图常带旋转信息，不管它会躺倒。
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        // 出来的是**像素图**，把倍数标回去，按点排版时才铺得对。
        return UIImage(cgImage: cgImage, scale: displayScale, orientation: .up)
    }

    /// 缩略图的内存缓存。
    ///
    /// ⚠️ 用 `NSCache` 而不是普通字典：内存吃紧时它**自己会丢东西**，而这正是我们要的 ——
    /// 图丢了下次再读一次盘就行，不该为了"读得快"把内存占住不放。
    ///
    /// ⚠️ 这一层**不是"优化"而是必须的**：列表每次刷新都会要图，
    /// 每次都从磁盘读 + 解码的话，一滚就卡。
    ///
    /// ⚠️ `nonisolated(unsafe)` **不是"绕编译器"，它说的就是实情**：
    /// `NSCache` 没被标 `Sendable`（编译器证不出来它线程安全），但它**本来就是线程安全的** ——
    /// Apple 文档原话：「You can add, remove, and query items in the cache from different
    /// threads without having to lock the cache yourself.」
    private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()
}

/// 「**按要多大给一张图**」这个动作的形状 —— 迷你播放条和播放页的大封面都用它。
///
/// 🔴 **为什么给的是"动作"而不是"一张图"**：取图的那一层（`ArtworkStore`）按
/// 「要多大 + 屏幕倍数」出图，而这两个数**只有视图自己知道**：
/// - 要多大 —— 由版式定；（`SizeThatFits` 之类的时机上一次还没定下来）
/// - 屏幕倍数 —— **在后台线程上问不到**（只会拿到默认值），而且换屏幕（外接显示器 / 分屏）会变。
///
/// 给一张现成的图，就等于把"什么时候该重取"这件事**从视图手里拿走**、又没人接住。
/// 所以注入的是这个动作，视图自己决定什么时候调它（`MiniPlayerBar.didMoveToWindow` 就是那样）。
///
/// ⚠️ **它住在 `Core` 是因为形状里一个业务类型都没有** —— 参数是
/// 「封面名（`String?`）+ 尺寸 + 倍数」、返回值是 `UIImage?`。
/// 真正认识"封面存在哪"的是 `ArtworkStore`（Data 层），实现这个动作的是装配层
/// （`App/AppArtwork.swift`）—— 两头都不在这层，所以这层不会反向依赖谁。
///
/// - Parameters:
///   - artworkPath: 封面文件名（`Track.artworkPath`）。没图就是 `nil`。
///   - pointSize: 要多大（**点**）。
///   - displayScale: 屏幕倍数，把"点"换成"像素"用（@3x 的机器上要取更大的那张）。
/// - Returns: 取不到就是 `nil`，调用方自己画占位。
///
/// ⚠️ **它是个 typealias，名字里看不出底下是函数类型** —— 所以任何 `init` / 函数把它
/// 收成参数时，那个参数**必须写 `@escaping`**：收下它的人通常要**存进属性**，
/// 而不写就默认"用完就走"、存不住，编译器才报
/// *Passing non-escaping parameter ... to function expecting an '@escaping' closure*。
/// （本项目踩过：`MiniBarNavController.init` 转发给 `MiniPlayerBar.init` 时漏了这句。）
typealias ArtworkProvider = (
    _ artworkPath: String?, _ pointSize: CGSize, _ displayScale: CGFloat
) -> UIImage?

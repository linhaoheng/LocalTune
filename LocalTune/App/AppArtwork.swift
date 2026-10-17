import MediaPlayer
import UIKit

/// 把「封面」这个数据层的口子接给界面 —— 迷你播放条和播放页的大封面**共用这一处**。
///
/// 🔴 **它住在装配层（`App/`）有三个理由**：
/// - 它连接的是**两头**：「封面文件在哪」是 `Data/Artwork/ArtworkStore` 的事、
///   「按尺寸出图」是 `Core/UI` 里 `ThumbnailLoader` 的事 —— 只有装配层才允许同时认识这两边；
/// - 界面层自己写这个闭包就等于"认识封面存在哪"（`Features/` 不许查库的同一道理）；
/// - **两处用到就提上来**：迷你播放条（`MiniBarNavController` 装配时拿到的）
///   和播放页的大封面都要取封面图，各写一份就会走散。
enum AppArtwork {

    /// `ArtworkProvider` 的实现。用法：`coverView.artworkProvider = AppArtwork.image`。
    ///
    /// ⚠️ 这就是「名字 → 文件 → 图」那三步的全部：**名字转 URL** 在 `ArtworkStore`、
    /// **按尺寸解码**在 `ThumbnailLoader`，这里只把两头接起来 —— 三步各归各家，谁也不越界。
    ///
    /// - Returns: 取不到就是 `nil`，调用方自己画占位。
    static func image(
        artworkPath: String?,
        pointSize: CGSize,
        displayScale: CGFloat
    ) -> UIImage? {
        guard let artworkPath, !artworkPath.isEmpty else { return nil }
        return ThumbnailLoader.image(
            at: ArtworkStore.url(forArtworkPath: artworkPath),
            pointSize: pointSize,
            displayScale: displayScale
        )
    }

    /// `LockScreenArtworkLoader` 的实现 —— 锁屏要的那份封面素材。
    ///
    /// 🔴 **为什么整个"读图 → 包成 `MPMediaItemArtwork`"都在这儿**：`Playback` 不碰 UI，
    /// 而 `MPMediaItemArtwork` 的图像回调要吐 `UIImage`。交给装配层做，`NowPlayingCenter`
    /// 就只认识"一份素材"，不认识屏幕倍数、也不认识 `UIImage`。
    ///
    /// ⚠️ **倍数在调用这一刻（主线程）取好**再带进后台：`UITraitCollection.current`
    /// 在后台线程上只会给默认值，@3x 的机器上会出一张偏小的图。
    ///
    /// ⚠️ 读图在**后台**：解码要读盘，而调用方（`NowPlayingCenter.publish` 那条线）在主线程。
    static func lockScreenArtwork(
        artworkPath: String,
        completion: @escaping (MPMediaItemArtwork?) -> Void
    ) {
        let displayScale = UITraitCollection.current.displayScale
        DispatchQueue.global(qos: .utility).async {
            guard let image = image(
                artworkPath: artworkPath,
                pointSize: AppMetrics.nowPlayingArtworkPointSize,
                displayScale: displayScale
            ) else {
                return completion(nil)
            }
            completion(MPMediaItemArtwork(boundsSize: image.size) { _ in image })
        }
    }

    /// 播放页背景的取色：Store 解 **≤64 像素@1x**（上限，不放大）→ `CoverPalette` 桶聚类
    /// → 填进 `ArtworkPalette` 三个槽。
    ///
    /// 结果按封面**文件名**缓存。名字里带内容指纹，换封面 ⇒ 键变。
    /// 图本身的缓存仍在 `ThumbnailLoader`。
    ///
    /// ⚠️ **在后台线程上被调**（`NowPlayingViewModel` 的 `paletteScheduler`）—— 能这么调，是因为
    /// `ThumbnailLoader` 只用 ImageIO 和线程安全的 `NSCache`，倍数也是这里给死的
    /// `CoverPalette.sourceScale`、不去问屏幕。
    ///
    /// - Returns: 没封面 / 读不出像素是 `nil`，由那边退到兜底色。
    static func palette(artworkPath: String?) -> ArtworkPalette? {
        guard let artworkPath, !artworkPath.isEmpty else { return nil }
        let key = artworkPath as NSString
        if let cached = paletteCache.object(forKey: key) { return cached.palette }

        guard let image = ThumbnailLoader.image(
            at: ArtworkStore.url(forArtworkPath: artworkPath),
            pointSize: CoverPalette.sourceImageSize,
            displayScale: CoverPalette.sourceScale
        )?.cgImage,
              let cover = CoverPalette(image: image) else { return nil }

        let palette = ArtworkPalette(cover: cover)
        paletteCache.setObject(CachedPalette(palette), forKey: key)
        return palette
    }

    /// 小组件快照的封面素材：最长边 360pt @2x 的 JPEG 字节。
    ///
    /// 小组件扩展读不到主 App 的缩略图缓存，所以发布者把图**压成字节**随快照落进
    /// App Group。发布者按曲目缓存产出结果，这里只管「路径 → 字节」这一步。
    ///
    /// ⚠️ 倍数用 2（同拼图那条的理由）：扩展进程里没有屏幕可问，
    /// `UITraitCollection.current` 只给默认值，倍数在这里给死。
    static func widgetArtworkJPEG(artworkPath: String?) -> Data? {
        guard let artworkPath, !artworkPath.isEmpty else { return nil }
        let side = CGSize(width: widgetArtworkSide, height: widgetArtworkSide)
        guard let image = ThumbnailLoader.image(
            at: ArtworkStore.url(forArtworkPath: artworkPath),
            pointSize: side,
            displayScale: widgetArtworkScale
        ) else { return nil }
        return image.jpegData(compressionQuality: widgetArtworkJPEGQuality)
    }

    private static let widgetArtworkSide: CGFloat = 360
    private static let widgetArtworkScale: CGFloat = 2
    private static let widgetArtworkJPEGQuality: CGFloat = 0.72

    /// `PlaylistCoverService` 的**拼图动作**（`CollageBuilder`）的实现 ——
    /// 「这串封面路径 → 一张拼图的 JPEG 字节」，一张都用不上就是 `nil`。
    ///
    /// 🔴 **为什么拼图这一步也归装配层**：它两头都碰 ——
    /// 下面要 `ArtworkStore` 把「路径」变成「文件在哪」，上面要 `CoverCollage` 画布那一套。
    /// `Data` 层只该拿到**字节**，`Core/UI` 只该拿到**路径**，中间这一步只有装配层能接。
    ///
    /// ⚠️ 缩略图倍数用 2 —— 拼图边长 400 点，2x 对它足够清晰；
    /// 这里**没有屏幕可问**（后台线程，`UITraitCollection.current` 只给默认值）。
    /// 凑满 `CoverCollage.maxTileCount` 张就停：多缩是白卡。
    static func playlistCollageJPEG(artworkPaths: [String]) -> Data? {
        let tileSize = CGSize(width: CoverCollage.side, height: CoverCollage.side)
        var images: [UIImage] = []
        images.reserveCapacity(CoverCollage.maxTileCount)
        for path in artworkPaths {
            guard images.count < CoverCollage.maxTileCount else { break }
            if let image = image(artworkPath: path, pointSize: tileSize, displayScale: 2) {
                images.append(image)
            }
        }
        guard let mosaic = CoverCollage.make(from: images) else { return nil }
        return CoverImageWriter.jpegDataForCollage(mosaic)
    }
}

private extension AppArtwork {

    static let paletteCache = NSCache<NSString, CachedPalette>()

    final class CachedPalette {
        let palette: ArtworkPalette
        init(_ palette: ArtworkPalette) { self.palette = palette }
    }
}

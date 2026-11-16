import UIKit

/// 封面**像素**这一段的活儿 —— 缩边、压 JPEG、拼图。
///
/// 🔴 **为什么它不住在 `Data/`**（宪法 §一 Data 行「不出现 UIKit 视图」· §一 引言 SDP
/// 「依赖只许指向更稳定的一侧」）：`Data/Artwork/ArtworkStore` 管的是「**字节存哪**」
/// —— 目录、前缀、内容指纹、备份标记，那些是**文件系统**的事，稳定。
/// 而「把一张图缩到 1024 点再压成 JPEG」「把 4 张拼成一张」是**画布**的事：
/// 它要 `UIImage`、要 `UIGraphicsImageRenderer`、要知道画多少**像素**。
/// 像素尺寸是**界面量**（同一张图在 @2x/@3x 上要出不同大小的图）—— 让 `Data` 知道它，
/// 就等于让数据层依赖界面环境，依赖方向反了。
///
/// 所以这条轴切成三段，各归各家（同一根 SDD 原则，跟 `ArtworkStore` 名字→URL、
/// `ThumbnailLoader` 按尺寸解码、`AppArtwork` 装配是同一套切法）：
///
/// | 段 | 住哪 | 干什么 |
/// |---|---|---|
/// | 算名字 / 落盘 / 删文件 | `Data/Artwork/ArtworkStore` | 只碰 `Data` 与 `URL` |
/// | **缩边 / 压 JPEG / 拼图** | **本文件（`Core/UI`）** | **只碰 `UIImage` → `Data`** |
/// | 把两头接起来 | `App/AppArtwork` | 装配层唯一同时认识两边的地方 |
///
/// - Note: 搬过来时**一个数值都没改**（1024 / 0.86 / 400 / 4 格布局），
///   所以生成出来的拼图像素与搬之前**逐字节相同**。
enum CoverImageWriter {

    /// 手挑封面最长边（点）—— 再大只白占空间；对照 primuse 的缩图上限。
    static let customCoverMaxPixel: CGFloat = 1024

    /// 手挑封面 JPEG 质量。
    static let customCoverJPEGQuality: CGFloat = 0.86

    /// 内嵌进音频文件那份封面的 JPEG 质量。
    ///
    /// 🔴 跟 `customCoverJPEGQuality` **不是一回事**：那份是**缓存**（给屏幕看），
    /// 这份是**数据**（跟着文件走、别的播放器也读）—— 所以这份**不缩边**、质量也高一点。
    static let embeddedCoverJPEGQuality: CGFloat = 0.92

    /// 相册挑出来的图 → 写进 `custom/` / `covers/` 用的 JPEG 字节（先缩最长边再压）。
    ///
    /// ⚠️ 标签封面**不走这里**（那条保留原始字节，不做有损重压缩，见 `ArtworkStore.save`）。
    static func jpegDataForCustomCover(_ image: UIImage) -> Data? {
        let resized = resizedForCustomCover(image)
        return resized.jpegData(compressionQuality: customCoverJPEGQuality)
    }

    /// 相册挑出来的图 → 写进**音频文件标签**用的 JPEG 字节。
    ///
    /// 🔴 **不缩边**：「缩到 1024」是**给屏幕**定的（手机屏幕最多也就显示一千出头像素），
    /// 那个决定不该管到文件头上 —— 文件里那份是**数据**，替用户丢像素是撒谎。
    ///
    /// ⚠️ 仍然要编码一次，这一步躲不掉：相册里那张原图可能是 HEIC / RAW（别的播放器读不了），
    /// 而且系统那个裁剪界面走完之后，我们手里只剩一张按裁剪框重画过的图，原文件已经不在流程里了。
    static func jpegDataForEmbeddedCover(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: embeddedCoverJPEGQuality)
    }

    /// 拼图 → JPEG 字节。给「落盘」那一步用。
    static func jpegDataForCollage(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: customCoverJPEGQuality)
    }

    /// 最长边缩到 `customCoverMaxPixel`，小图不动。
    ///
    /// ⚠️ `format.scale = 1`：**输出多少像素由 `newSize` 说了算**，不跟屏幕倍数走 ——
    /// 这是搬到这里之后仍然成立的原因：像素数是这一行算出来的，不是问系统问出来的。
    private static func resizedForCustomCover(_ image: UIImage) -> UIImage {
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > customCoverMaxPixel, maxSide > 0 else { return image }
        let scale = customCoverMaxPixel / maxSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// 歌单拼图封面 —— **纯拼图**，不认歌单、不碰磁盘。
///
/// 从歌单里带封面的歌各取一张，最多拼 **4** 张（1 / 2 / 3 / 4 四种布局）。
///
/// ⚠️ **不**在这儿落盘：落盘是 `ArtworkStore.savePlaylistCollage` 的事；
/// 拼出来只是一张 `UIImage`，调用方决定往哪写。
///
/// 🔴 与 `CoverImageWriter` 同文件：两者是同一段活儿（把几张画布拼/缩成一张画布），
/// 且各自都只有拼图那条路一个调用方 —— 拆成两个文件只是「一个类型一个文件」的教条，
/// 凑不出第二个独立职责。
enum CoverCollage {

    /// 拼图边长（点）—— **400**。
    static let side: CGFloat = 400

    /// 最多几格 —— 收集源图和 `make` 共用这一处，禁止再写裸 `4`。
    static let maxTileCount = 4

    /// 从最多 `maxTileCount` 张图拼出一张方图。空数组 → `nil`。
    ///
    /// - 1 张：原样返回（不再重画一遍）
    /// - 2 张：上下对半
    /// - 3 张：左一整列 + 右上下两格
    /// - 4 张：四宫格
    static func make(from images: [UIImage], size: CGFloat = side) -> UIImage? {
        let tiles = Array(images.prefix(maxTileCount))
        guard !tiles.isEmpty else { return nil }
        if tiles.count == 1 { return tiles[0] }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let half = size / 2
            let rects: [CGRect]
            switch tiles.count {
            case 2:
                rects = [
                    CGRect(x: 0, y: 0, width: size, height: half),
                    CGRect(x: 0, y: half, width: size, height: half),
                ]
            case 3:
                rects = [
                    CGRect(x: 0, y: 0, width: half, height: size),
                    CGRect(x: half, y: 0, width: half, height: half),
                    CGRect(x: half, y: half, width: half, height: half),
                ]
            default:
                rects = [
                    CGRect(x: 0, y: 0, width: half, height: half),
                    CGRect(x: half, y: 0, width: half, height: half),
                    CGRect(x: 0, y: half, width: half, height: half),
                    CGRect(x: half, y: half, width: half, height: half),
                ]
            }
            for (index, image) in tiles.enumerated() {
                fill(image, in: rects[index])
            }
        }
    }

    /// 等比放大铺满格子，居中裁掉多出来的边（aspect fill）。
    private static func fill(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        image.draw(in: CGRect(origin: origin, size: drawSize))
    }
}

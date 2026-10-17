import UIKit

/// 一个歌单的封面 —— **该画什么**。
///
/// 🔴 **它是值、不是视图**：这里只回答「这个歌单的封面属于哪一档」，
/// 怎么落到像素上是 `PlaylistCoverView` 的事（取图和画图分开）。
/// 列表行和详情页表头用的是**同一套规则** —— 两处各写一遍必然走散。
///
/// ⚠️ `Hashable` 不是顺手加的：`PlaylistRow` 要能进 `Set` / 做相等比较，而它里面装着这个类型。
enum PlaylistCover: Hashable {

    /// 「最爱的歌曲」：还没有封面时 —— 一块底 + 一颗心。
    case favorites

    /// 有封面 —— 存的是 `Playlist.artworkPath`：
    /// 手挑的带 `covers/` 前缀、生成的拼图是裸文件名（落 `images/`）。
    case artwork(String)

    /// 还没有封面 —— 画个占位符号。
    case placeholder

    /// 从一个歌单得出它的封面 —— **全 App 只有这一处**这么判。
    ///
    /// 顺序：**有封面 > 最爱心 > 占位**。
    ///
    /// 🔴 **只看库里那一列**：封面是手挑的还是生成的，画出来一模一样，所以不分开；
    /// 「哪张」由库说了算，界面**不碰磁盘**（磁盘上的东西不在观察流的失效条件里）。
    init(_ playlist: Playlist) {
        if let path = playlist.artworkPath, !path.isEmpty {
            self = .artwork(path)
        } else if playlist.isFavorites {
            self = .favorites
        } else {
            self = .placeholder
        }
    }
}

/// 把 `PlaylistCover` 画到屏幕上 —— **全 App 唯一一处**知道这四件事：
/// 哪一档用哪块底色、画哪个符号、符号多大、取图取多大。
///
/// ⚠️ 取图也在这儿（走注入的 `ArtworkProvider`）—— 跟曲库页的行同一个做法。**别把取图提到外面去**：
/// 尺寸和屏幕倍数只有视图自己知道（见 `ArtworkProvider` 那段），外面给一张现成的图，
/// 等于把"什么时候该重取"从视图手里拿走、又没人接住。
/// ⚠️ 但"封面文件在哪"它**不认识** —— 那是 `Data` 的事，由装配层把动作递进来。
final class PlaylistCoverView: UIImageView {

    /// 这一枚自己的尺寸。
    ///
    /// ⚠️ 只有这一个地方用 ⇒ 先放在这儿、**不往 `AppMetrics` 放**
    /// （跟曲库页的行内尺寸同一条规矩：只有一个地方用的不进令牌表）。
    private enum Metrics {

        /// 下面那两个符号大小是**对着 54 点那一格封面**定的 —— 也就是列表行里那一格。
        static let referenceSide: CGFloat = 54

        /// 「最爱的歌曲」那颗心 —— **22**。
        static let favoritesSymbolPointSize: CGFloat = 22

        /// 用户歌单的空封面那个符号 —— **20 中等**（比上面那颗心小一号，也细一档）。
        static let emptySymbolPointSize: CGFloat = 20
    }

    /// 取图的动作 —— 装配层（`App/AppArtwork.image`）给。
    ///
    /// ⚠️ 取图**只走这一条缝**："封面文件在哪"是 `Data` 的事，这一枚不认识
    /// （跟曲库行同一个做法，见 `Core/UI/ArtworkProvider.swift`）。
    var artworkProvider: ArtworkProvider?

    /// 现在画的是哪一档 —— 也用来判"尺寸变了要不要重画"。
    private var cover: PlaylistCover?

    /// 上一次**真的画出去**时这一枚多大。
    ///
    /// ⚠️ `layoutSubviews` 会被叫很多次，而读图要按尺寸取（换尺寸就是另一张缩略图）——
    /// 拿它挡一下，尺寸没变就不重取。
    private var renderedSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    /// 建一个空封面 —— 尺寸全由约束定，`frame` 没有意义，所以**不要它**。
    ///
    /// 🔴 这个无参构造**必须自己写**：`UIImageView` 的指定构造器不止
    /// `init(frame:)` / `init?(coder:)` 这两个，它自己还有 `init(image:)` 那几个 ——
    /// 上面只实现了前两个，于是**继承不到**超类的无参构造。
    ///（`UIView` 的子类才继承得到，比如 `SongTableCell` 里那个 `FormatTag`。）
    convenience init() {
        self.init(frame: .zero)
    }

    /// 换成要画的封面。
    func show(_ cover: PlaylistCover) {
        self.cover = cover
        // 换了内容 ⇒ 逼它重画一次（尺寸没变也得重画）。
        renderedSize = .zero
        render()
    }

    /// ⚠️ 尺寸是**布局之后**才定的，所以画的时机不能只在 `show(_:)` 里 ——
    /// 那一刻这一枚可能还是零大（刚出队、约束刚装上）。
    override func layoutSubviews() {
        super.layoutSubviews()
        render()
    }

    // MARK: - 私有

    /// 把封面落到像素上。
    private func render() {
        guard let cover, bounds.size != renderedSize, bounds.width > 0 else { return }
        renderedSize = bounds.size

        switch cover {
        case .favorites:
            showSymbol(
                "heart.fill",
                pointSize: Metrics.favoritesSymbolPointSize,
                weight: .regular,
                background: AppColor.favoritesCover
            )

        case .placeholder:
            showSymbol(
                "music.note.list",
                pointSize: Metrics.emptySymbolPointSize,
                weight: .medium,
                background: AppColor.artworkPlaceholder
            )

        case .artwork(let path):
            // ⚠️ 尺寸和倍数要跟**这一格实际多大**对上，不然读出来的是另一张图（白读一次）。
            // ⚠️ 倍数用 `traitCollection`，不用 `UITraitCollection.current` —— 这一枚自己的环境
            //（分屏 / 外接屏）才准；曲库行同一条。
            if let loaded = artworkProvider?(
                path,
                bounds.size,
                traitCollection.displayScale
            ) {
                image = loaded
                // 解码瞬间底下垫这块色 —— 不留白块。
                backgroundColor = AppColor.artworkPlaceholder
                contentMode = .scaleAspectFill
                tintColor = nil
            } else {
                // 文件没了 / 坏了：画占位符号，跟 `.placeholder`、曲库行同一口径 ——
                // 只垫色会像"空着一块"，有符号才是"这张封面没了"。
                showSymbol(
                    "music.note.list",
                    pointSize: Metrics.emptySymbolPointSize,
                    weight: .medium,
                    background: AppColor.artworkPlaceholder
                )
            }
        }
    }

    /// 画一个符号：底色 + 图标，图标居中。
    ///
    /// ⚠️ 符号大小**跟着这一枚等比放大**：上面那两个数是照 54 点定的，而详情页表头那个封面
    /// 比它大得多 —— 照搬 22 上去会小得像粒芝麻。比例就是「这一枚有多宽 ÷ 54」。
    ///
    /// ⚠️ `weight` 是 **`UIImage.SymbolWeight`**，不是 `UIFont.Weight` —— 两者同名档位
    /// （`.regular` / `.medium`…）看着一样、是**两个不同的类型**，写错编译不过。
    private func showSymbol(
        _ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight, background: UIColor
    ) {
        let scale = bounds.width / Metrics.referenceSide
        image = UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize * scale, weight: weight)
        )
        backgroundColor = background
        contentMode = .center
        tintColor = AppColor.accent
    }
}

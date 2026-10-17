import UIKit

/// 封面流一格：封面 + 倒影（在 bounds 外）+ 歌名 / 艺人。
///
/// 倒影在格子下面，collection / cell 都 `clipsToBounds = false`。
/// 用 `layoutSubviews` 摆 frame 是有意的例外（数字仍进 `AppMetrics`）。
final class PlaylistCoverFlowCell: UICollectionViewCell {

    static let reuseIdentifier = "PlaylistCoverFlowCell"

    private let imageView = UIImageView()
    /// 倒影外层只负责圆角裁切；渐变 mask 在内层，二者不能同层。
    private let reflectionContainer = UIView()
    private let reflectionView = UIImageView()
    private let reflectionMask = CAGradientLayer()
    private let infoContainer = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var artworkProvider: ArtworkProvider?
    private var artworkPath: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = false
        clipsToBounds = false

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = AppMetrics.coverFlowCoverCornerRadius
        imageView.layer.masksToBounds = true
        // 常暗浮层上的封面占位底走浮层色族：`AppColor.artworkPlaceholder` 是实色（浅色下近白），
        // 压在这页黑底上就是一块白 —— 判据见 `AppColor.artworkPlaceholder` 注释。
        imageView.backgroundColor = AppColor.overlayFillSubtle
        imageView.layer.borderWidth = AppMetrics.coverFlowCoverBorderWidth
        imageView.layer.borderColor = AppColor.overlayFillSubtle.cgColor
        contentView.addSubview(imageView)

        reflectionContainer.clipsToBounds = true
        reflectionContainer.layer.cornerRadius = AppMetrics.coverFlowCoverCornerRadius
        reflectionContainer.layer.masksToBounds = true
        contentView.addSubview(reflectionContainer)

        reflectionView.contentMode = .scaleAspectFill
        reflectionView.clipsToBounds = true
        reflectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
        reflectionContainer.addSubview(reflectionView)

        reflectionMask.colors = [
            AppColor.coverFlowReflectionMask
                .withAlphaComponent(AppMetrics.coverFlowReflectionMaskTopOpacity).cgColor,
            AppColor.coverFlowReflectionMask.cgColor
        ]
        reflectionMask.startPoint = CGPoint(x: 0.5, y: 0)
        reflectionMask.endPoint = CGPoint(x: 0.5, y: AppMetrics.coverFlowReflectionMaskEndY)
        reflectionView.layer.mask = reflectionMask

        infoContainer.alpha = 0
        contentView.addSubview(infoContainer)

        titleLabel.textAlignment = .center
        titleLabel.textColor = AppColor.overlayTextStrong
        titleLabel.font = AppFont.coverFlowTitle
        titleLabel.numberOfLines = 2
        titleLabel.layer.shadowColor = AppColor.shadow.cgColor
        titleLabel.layer.shadowOpacity = AppMetrics.coverFlowTitleShadowOpacity
        titleLabel.layer.shadowRadius = AppMetrics.coverFlowTitleShadowRadius
        titleLabel.layer.shadowOffset = CGSize(width: 0, height: AppMetrics.coverFlowTitleShadowOffsetY)

        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = AppColor.overlayTextSecondary
        subtitleLabel.font = AppFont.coverFlowSubtitle
        subtitleLabel.layer.shadowColor = AppColor.shadow.cgColor
        subtitleLabel.layer.shadowOpacity = AppMetrics.coverFlowSubtitleShadowOpacity
        subtitleLabel.layer.shadowRadius = AppMetrics.coverFlowSubtitleShadowRadius
        subtitleLabel.layer.shadowOffset = CGSize(width: 0, height: AppMetrics.coverFlowSubtitleShadowOffsetY)

        infoContainer.addSubview(titleLabel)
        infoContainer.addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        let reflectionHeight = bounds.height * AppMetrics.coverFlowReflectionHeightFraction
        let belowY = bounds.maxY + AppMetrics.coverFlowReflectionGap
        reflectionContainer.frame = CGRect(
            x: 0,
            y: belowY,
            width: bounds.width,
            height: reflectionHeight
        )
        // ⚠️ 带 transform 的视图不给它设 `frame`（Apple：非 identity 时 `frame` 未定义、不该改）。
        // 倒影视图是 `scaleY(-1)`，只能设 `bounds` + `center`。
        reflectionView.bounds = CGRect(origin: .zero, size: reflectionContainer.bounds.size)
        reflectionView.center = CGPoint(
            x: reflectionContainer.bounds.midX,
            y: reflectionContainer.bounds.midY
        )
        reflectionMask.frame = reflectionView.bounds
        let pad = AppMetrics.coverFlowInfoPaddingX
        infoContainer.frame = CGRect(
            x: -pad,
            y: belowY,
            width: bounds.width + pad * 2,
            height: AppMetrics.coverFlowInfoHeight
        )
        titleLabel.frame = CGRect(
            x: 0,
            y: 0,
            width: infoContainer.bounds.width,
            height: AppMetrics.coverFlowInfoTitleHeight
        )
        subtitleLabel.frame = CGRect(
            x: 0,
            y: AppMetrics.coverFlowInfoTitleHeight,
            width: infoContainer.bounds.width,
            height: AppMetrics.coverFlowInfoHeight - AppMetrics.coverFlowInfoTitleHeight
        )
        renderArtwork()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        reflectionView.image = nil
        titleLabel.text = nil
        subtitleLabel.text = nil
        artworkPath = nil
        reflectionView.alpha = 0
        infoContainer.alpha = 0
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        guard let attrs = layoutAttributes as? PlaylistCoverFlowLayoutAttributes else { return }
        let absProgress = abs(attrs.progress)
        reflectionView.alpha = CoverFlowGeometry.reflectionAlpha(absProgress: absProgress)
        infoContainer.alpha = CoverFlowGeometry.infoAlpha(absProgress: absProgress)
    }

    func show(_ item: CoverFlowItem, artworkProvider: ArtworkProvider?) {
        titleLabel.text = item.title
        subtitleLabel.text = item.artist
        self.artworkProvider = artworkProvider
        artworkPath = item.artworkPath
        renderArtwork()
    }

    private func renderArtwork() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if let image = artworkProvider?(artworkPath, size, traitCollection.displayScale) {
            imageView.image = image
            imageView.contentMode = .scaleAspectFill
            imageView.tintColor = nil
            reflectionView.image = image
            reflectionView.contentMode = .scaleAspectFill
            reflectionView.tintColor = nil
            return
        }
        let placeholder = UIImage(systemName: "music.note")
        imageView.image = placeholder
        imageView.contentMode = .center
        imageView.tintColor = AppColor.subtitle
        reflectionView.image = placeholder
        reflectionView.contentMode = .center
        reflectionView.tintColor = AppColor.subtitle
    }
}

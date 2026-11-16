import UIKit

/// 封面流格子的 attributes：除了系统那套，还带离中央多远（格子用它调倒影 / 歌名透明度）。
final class PlaylistCoverFlowLayoutAttributes: UICollectionViewLayoutAttributes {
    var progress: CGFloat = 0

    override func copy(with zone: NSZone? = nil) -> Any {
        let copied = super.copy(with: zone)
        guard let attributes = copied as? PlaylistCoverFlowLayoutAttributes else {
            assertionFailure("layoutAttributesClass 必须是 PlaylistCoverFlowLayoutAttributes")
            return copied
        }
        attributes.progress = progress
        return attributes
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PlaylistCoverFlowLayoutAttributes else { return false }
        return super.isEqual(other) && progress == other.progress
    }
}

/// 横滑 3D 封面流。公式在 `CoverFlowGeometry`，这里只组 transform。
///
/// 🔴 **几何只读 live bounds**（`collectionView.bounds`）。转屏在 alongside 摆位，
/// 那时 bounds 正随过渡在变，`layoutIfNeeded` 拿到的就是当拍 —— 不钉 `referenceSize`、不缓存目标尺寸。
final class PlaylistCoverFlowLayout: UICollectionViewFlowLayout {

    override class var layoutAttributesClass: AnyClass {
        PlaylistCoverFlowLayoutAttributes.self
    }

    override init() {
        super.init()
        scrollDirection = .horizontal
        minimumInteritemSpacing = 0
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let bounds = collectionView.bounds
        // **不**设"宽高为 0 就跳过"的保护 —— 宽高为 0 时照算，边长会落到下限 220。
        // 跳过会保留上一次的 `itemSize`（转屏进场时就是拿旧几何在跑）。
        let side = CoverFlowGeometry.itemSide(bounds: bounds.size)
        itemSize = CGSize(width: side, height: side)
        minimumLineSpacing = CoverFlowGeometry.lineSpacing(side: side)
        let inset = CoverFlowGeometry.sectionInsets(bounds: bounds.size, side: side)
        sectionInset = UIEdgeInsets(
            top: inset.top,
            left: inset.left,
            bottom: inset.bottom,
            right: inset.right
        )
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        true
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let collectionView,
              let base = super.layoutAttributesForElements(in: rect)
        else { return nil }

        let midX = collectionView.contentOffset.x + collectionView.bounds.width * 0.5
        let side = itemSize.width

        return base.map { attribute in
            guard attribute.representedElementCategory == .cell,
                  let attrs = attribute.copy() as? PlaylistCoverFlowLayoutAttributes
            else { return attribute }

            let progress = CoverFlowGeometry.progress(
                itemCenterX: attrs.center.x,
                midX: midX,
                side: side
            )
            let absProgress = abs(progress)
            var transform = CATransform3DIdentity
            transform.m34 = AppMetrics.coverFlowPerspective
            transform = CATransform3DTranslate(
                transform,
                progress * side * AppMetrics.coverFlowTranslateXFraction,
                0,
                absProgress * -AppMetrics.coverFlowDepth
            )
            transform = CATransform3DRotate(
                transform,
                progress * -AppMetrics.coverFlowRotationAngle,
                0,
                1,
                0
            )
            attrs.transform3D = transform
            attrs.zIndex = Int((1 - absProgress) * AppMetrics.coverFlowZIndexScale)
            attrs.progress = progress
            return attrs
        }
    }

    override func targetContentOffset(
        forProposedContentOffset proposedContentOffset: CGPoint,
        withScrollingVelocity velocity: CGPoint
    ) -> CGPoint {
        guard let collectionView else {
            return super.targetContentOffset(
                forProposedContentOffset: proposedContentOffset,
                withScrollingVelocity: velocity
            )
        }
        let bounds = collectionView.bounds
        let viewportWidth = bounds.width
        let expanded = CGRect(
            x: proposedContentOffset.x - viewportWidth * 0.5,
            y: 0,
            width: viewportWidth * 2,
            height: bounds.height
        )
        guard let attributes = layoutAttributesForElements(in: expanded)?
            .filter({ $0.representedElementCategory == .cell }),
              !attributes.isEmpty
        else {
            return super.targetContentOffset(
                forProposedContentOffset: proposedContentOffset,
                withScrollingVelocity: velocity
            )
        }
        let proposedCenterX = proposedContentOffset.x + viewportWidth * 0.5
        guard let closest = attributes.min(by: {
            abs($0.center.x - proposedCenterX) < abs($1.center.x - proposedCenterX)
        }) else {
            return super.targetContentOffset(
                forProposedContentOffset: proposedContentOffset,
                withScrollingVelocity: velocity
            )
        }
        // 落点算完再夹回合法区间（`scrollToItem` 那类系统 API 内部也这么做）。
        // 夹法跟子页 `scrollToCenteredIndex` 共用 `CoverFlowGeometry.clampedOffsetX`，
        // 两边都读 `adjustedContentInset`。
        let inset = collectionView.adjustedContentInset
        return CGPoint(
            x: CoverFlowGeometry.clampedOffsetX(
                centeringItemCenterX: closest.center.x,
                viewportWidth: viewportWidth,
                contentWidth: collectionViewContentSize.width,
                insetLeft: inset.left,
                insetRight: inset.right
            ),
            y: proposedContentOffset.y
        )
    }
}

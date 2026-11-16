import CoreGraphics
import Foundation

/// 歌单封面流盖不盖上去 —— 判断吐 enum，不吐 Bool。
///
/// `Equatable` 是给单测的 `XCTAssertEqual` 用的：带关联值的 enum **不会**自动合成，
/// 得自己声明（全项目带值 enum 都这么写）。
enum CoverFlowSurface: Equatable {
    /// 仍是详情那张表。
    case list
    /// 3D 封面流盖层；`showExit` = 手机菜单强制进场才露关闭键。
    case overlay(showExit: Bool)
}

/// 封面流一格要画的内容。格子不收 `Track`。
struct CoverFlowItem: Equatable {
    let id: Track.ID
    let title: String
    let artist: String
    let artworkPath: String?
}

/// 封面流的几何：只吐数。3D 变换在 `PlaylistCoverFlowLayout` 里组。
enum CoverFlowGeometry {

    static func surface(
        isPhone: Bool,
        width: CGFloat,
        height: CGFloat,
        iPadAutoEnabled: Bool,
        isEmpty: Bool,
        forceLock: Bool
    ) -> CoverFlowSurface {
        guard width > height else { return .list }
        guard !isEmpty else { return .list }
        if isPhone { return .overlay(showExit: forceLock) }
        guard iPadAutoEnabled else { return .list }
        return .overlay(showExit: false)
    }

    static func itemSide(bounds: CGSize) -> CGFloat {
        max(
            min(
                bounds.width * AppMetrics.coverFlowMaxWidthFraction,
                bounds.height * AppMetrics.coverFlowMaxHeightFraction
            ),
            AppMetrics.coverFlowMinSide
        )
    }

    static func lineSpacing(side: CGFloat) -> CGFloat {
        side * -AppMetrics.coverFlowSpacingOverlapRatio
    }

    static func sectionInsets(bounds: CGSize, side: CGFloat) -> (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        let horizontal = max((bounds.width - side) * 0.5, 0)
        let vertical = max(
            (bounds.height - AppMetrics.coverFlowVerticalInsetHeightFactor * side) * 0.5,
            0
        )
        return (vertical, horizontal, vertical, horizontal)
    }

    static func progress(itemCenterX: CGFloat, midX: CGFloat, side: CGFloat) -> CGFloat {
        let activeDistance = max(side * AppMetrics.coverFlowActiveDistanceFraction, 1)
        return min(max((itemCenterX - midX) / activeDistance, -1), 1)
    }

    static func reflectionAlpha(absProgress: CGFloat) -> CGFloat {
        max(
            AppMetrics.coverFlowReflectionAlphaBase
                - AppMetrics.coverFlowReflectionAlphaSlope * absProgress,
            AppMetrics.coverFlowReflectionAlphaMin
        )
    }

    static func infoAlpha(absProgress: CGFloat) -> CGFloat {
        let full = AppMetrics.coverFlowInfoAlphaFullThreshold
        let fade = AppMetrics.coverFlowInfoAlphaFadeThreshold
        if absProgress < full { return 1 }
        if absProgress < fade {
            let span = fade - full
            return max((absProgress - full) / -span + 1, 0)
        }
        return 0
    }

    static func clampedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    /// 把一个「想让某格中心对准视口中心」的 `contentOffset.x` 夹回合法区间。
    ///
    /// 🔴 两处共用这一份，口径不许分叉：① layout 的 `targetContentOffset`（松手吸最近一张）；
    /// ② 子页的 `scrollToCenteredIndex`（程序摆正）。两边都读 `adjustedContentInset`。
    static func clampedOffsetX(
        centeringItemCenterX itemCenterX: CGFloat,
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        insetLeft: CGFloat,
        insetRight: CGFloat
    ) -> CGFloat {
        let minX = -insetLeft
        let maxX = max(contentWidth - viewportWidth + insetRight, minX)
        return min(max(itemCenterX - viewportWidth * 0.5, minX), maxX)
    }

    /// 找一个 id 在一列里的下标：找得到就用它，找不到按 `previousIndex` 夹紧。
    /// 两处用它：① 快照变了保住当前那张（`previousIndex` = 当前下标）；
    /// ② 进场瞄当前装着的那首（`previousIndex` 传 `0` ⇒ 找不到落第一首）。
    static func index<ID: Equatable>(
        preserving id: ID?,
        in ids: [ID],
        previousIndex: Int
    ) -> Int {
        if let id, let found = ids.firstIndex(of: id) { return found }
        return clampedIndex(previousIndex, count: ids.count)
    }
}

import SnapKit
import UIKit

/// 播放页现在是哪一种摆法。
///
/// 只吃尺寸、是不是手机、歌词开关。**不**吃方向枚举，也**不**吃「强制横屏」那面旗
/// （旗只改 mask；几何仍是 `width > height`）。
enum NowPlayingLayoutKind: Equatable {
    /// 竖屏：封面 XOR 歌词。
    case portrait
    /// 手机横屏：左封面右歌词，不管歌词开关。
    case phoneLandscape
    /// iPad 横屏开歌词：左栏竖屏链、右栏歌词。
    case padLandscapeLyrics
    /// iPad 横屏关歌词：竖屏链居中，宽不超过 500。
    case padLandscapeCover
}

extension NowPlayingLayoutKind {

    var hidesPortraitChrome: Bool { self == .phoneLandscape }

    var showsLandscapePlay: Bool { self == .phoneLandscape }

    var usesCompactBlocks: Bool { self == .phoneLandscape }

    var coverInset: CGFloat {
        self == .phoneLandscape
            ? AppMetrics.nowPlayingCoverLandscapeInset
            : AppMetrics.nowPlayingCoverInset
    }

    func coverHidden(lyricsVisible: Bool) -> Bool {
        switch self {
        case .portrait: return lyricsVisible
        case .phoneLandscape, .padLandscapeLyrics, .padLandscapeCover: return false
        }
    }

    func lyricsHidden(lyricsVisible: Bool) -> Bool {
        switch self {
        case .portrait: return !lyricsVisible
        case .phoneLandscape, .padLandscapeLyrics: return false
        case .padLandscapeCover: return true
        }
    }
}

/// 尺寸 → kind；kind → 整份换页面约束。
enum NowPlayingLayout {

    static func kind(
        width: CGFloat,
        height: CGFloat,
        isPhone: Bool,
        lyricsVisible: Bool
    ) -> NowPlayingLayoutKind {
        guard width > height else { return .portrait }
        if isPhone { return .phoneLandscape }
        return lyricsVisible ? .padLandscapeLyrics : .padLandscapeCover
    }

    struct Surface {
        var host: UIView
        var quality: UIView
        var cover: UIView
        var lyrics: UIView
        var info: UIView
        var progress: UIView
        var transport: UIView
        var landscapePlay: UIView
        var landscapeExit: UIView
    }

    /// `size` 必须是**目标**尺寸（转屏时 bounds 还是旧的）。
    static func apply(_ kind: NowPlayingLayoutKind, on surface: Surface, size: CGSize) {
        switch kind {
        case .portrait:
            applyPortrait(on: surface)
        case .phoneLandscape:
            applyPhoneLandscape(on: surface)
        case .padLandscapeLyrics:
            let column = size.width / 2 - AppMetrics.nowPlayingPadLandscapeColumnInset
            applyPadLandscape(on: surface, columnWidth: column, lyrics: true)
        case .padLandscapeCover:
            let column = min(size.width, AppMetrics.nowPlayingPadLandscapeMaxWidth)
            applyPadLandscape(on: surface, columnWidth: column, lyrics: false)
        }
    }
}

private extension NowPlayingLayout {

    static func applyPortrait(on surface: Surface) {
        let host = surface.host
        let safe = host.safeAreaLayoutGuide
        let inset = AppMetrics.nowPlayingHorizontalInset

        surface.quality.snp.remakeConstraints { make in
            make.top.equalTo(safe.snp.top).offset(AppMetrics.nowPlayingQualityTopOffset)
            make.height.equalTo(AppMetrics.nowPlayingQualityBarHeight)
            make.leading.trailing.equalToSuperview()
                .inset(AppMetrics.nowPlayingQualityHorizontalInset)
        }
        surface.cover.snp.remakeConstraints { make in
            make.top.equalTo(surface.quality.snp.bottom).offset(AppMetrics.nowPlayingCoverTopGap)
            make.bottom.equalTo(surface.info.snp.top)
            make.leading.trailing.equalToSuperview()
        }
        surface.lyrics.snp.remakeConstraints { make in
            make.top.equalTo(surface.quality.snp.bottom).offset(AppMetrics.nowPlayingCoverTopGap)
            make.bottom.equalTo(surface.info.snp.top).offset(-AppMetrics.nowPlayingLyricsBottomGap)
            make.leading.trailing.equalToSuperview()
                .inset(AppMetrics.nowPlayingLyricsHorizontalInset)
        }
        surface.transport.snp.remakeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(safe.snp.bottom)
                .offset(-AppMetrics.nowPlayingTransportBottomInset)
        }
        surface.progress.snp.remakeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(inset)
            make.bottom.equalTo(surface.transport.snp.top).offset(-AppMetrics.s10)
        }
        surface.info.snp.remakeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(inset)
            make.bottom.equalTo(surface.progress.snp.top).offset(-AppMetrics.s10)
        }
        pinLandscapeButtons(on: surface, safe: safe)
    }

    static func applyPhoneLandscape(on surface: Surface) {
        let host = surface.host
        let safe = host.safeAreaLayoutGuide
        let top = AppMetrics.nowPlayingLandscapeTopInset
        let bottom = AppMetrics.nowPlayingLandscapeBottomInset

        surface.cover.snp.remakeConstraints { make in
            make.top.equalTo(safe.snp.top).offset(top)
            make.bottom.equalTo(surface.progress.snp.top)
            make.width.equalToSuperview()
                .multipliedBy(AppMetrics.nowPlayingLandscapeCoverWidthFraction)
            make.centerX.equalTo(host.snp.centerX)
                .multipliedBy(AppMetrics.nowPlayingLandscapeCoverCenterFraction)
        }
        surface.progress.snp.remakeConstraints { make in
            make.top.equalTo(surface.cover.snp.bottom)
            make.centerX.equalTo(surface.cover)
            make.width.equalTo(surface.cover)
                .multipliedBy(AppMetrics.nowPlayingLandscapeProgressWidthFraction)
            make.bottom.equalTo(safe.snp.bottom).offset(-bottom)
        }
        surface.landscapePlay.snp.remakeConstraints { make in
            make.trailing.equalTo(safe.snp.trailing).offset(-top)
            make.centerY.equalTo(surface.info)
            make.size.equalTo(
                CGSize(
                    width: AppMetrics.nowPlayingChromeButtonSide,
                    height: AppMetrics.nowPlayingChromeButtonHeight
                )
            )
        }
        surface.info.snp.remakeConstraints { make in
            make.top.equalTo(safe.snp.top).offset(top)
            make.leading.equalTo(host.snp.centerX).offset(top)
            make.trailing.equalTo(surface.landscapePlay.snp.leading)
                .offset(-AppMetrics.nowPlayingCoverTopGap)
        }
        surface.lyrics.snp.remakeConstraints { make in
            make.leading.equalTo(surface.info)
            make.trailing.equalTo(safe.snp.trailing).offset(-top)
            make.top.equalTo(surface.info.snp.bottom)
                .offset(AppMetrics.nowPlayingLandscapeLyricsTopGap)
            make.bottom.equalTo(safe.snp.bottom).offset(-bottom)
        }
        surface.landscapeExit.snp.remakeConstraints { make in
            make.trailing.equalTo(safe.snp.trailing).offset(-AppMetrics.nowPlayingChromeGap)
            make.bottom.equalTo(safe.snp.bottom).offset(-AppMetrics.nowPlayingChromeGap)
            make.size.equalTo(
                CGSize(
                    width: AppMetrics.nowPlayingChromeWideSide,
                    height: AppMetrics.nowPlayingChromeButtonHeight
                )
            )
        }
        // 音质条 / 传输行横屏不在链上，仍钉在原位以免无约束。
        surface.quality.snp.remakeConstraints { make in
            make.top.equalTo(safe.snp.top).offset(AppMetrics.nowPlayingQualityTopOffset)
            make.height.equalTo(AppMetrics.nowPlayingQualityBarHeight)
            make.leading.trailing.equalToSuperview()
                .inset(AppMetrics.nowPlayingQualityHorizontalInset)
        }
        surface.transport.snp.remakeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(safe.snp.bottom)
                .offset(-AppMetrics.nowPlayingTransportBottomInset)
        }
    }

    static func applyPadLandscape(on surface: Surface, columnWidth: CGFloat, lyrics: Bool) {
        let host = surface.host
        let safe = host.safeAreaLayoutGuide
        let side = AppMetrics.nowPlayingPadLandscapeSideInset

        if lyrics {
            surface.transport.snp.remakeConstraints { make in
                make.leading.equalToSuperview().offset(side)
                make.width.equalTo(columnWidth)
                make.bottom.equalTo(safe.snp.bottom)
                    .offset(-AppMetrics.nowPlayingTransportBottomInset)
            }
        } else {
            surface.transport.snp.remakeConstraints { make in
                make.centerX.equalToSuperview()
                make.width.equalTo(columnWidth)
                make.bottom.equalTo(safe.snp.bottom)
                    .offset(-AppMetrics.nowPlayingTransportBottomInset)
            }
        }
        surface.quality.snp.remakeConstraints { make in
            make.top.equalTo(safe.snp.top).offset(AppMetrics.nowPlayingQualityTopOffset)
            make.height.equalTo(AppMetrics.nowPlayingQualityBarHeight)
            make.leading.equalTo(surface.transport.snp.leading)
                .offset(AppMetrics.nowPlayingQualityHorizontalInset)
            make.trailing.equalTo(surface.transport.snp.trailing)
                .offset(-AppMetrics.nowPlayingQualityHorizontalInset)
        }
        surface.progress.snp.remakeConstraints { make in
            make.leading.width.equalTo(surface.transport)
            make.bottom.equalTo(surface.transport.snp.top).offset(-AppMetrics.s10)
        }
        surface.info.snp.remakeConstraints { make in
            make.leading.width.equalTo(surface.transport)
            make.bottom.equalTo(surface.progress.snp.top).offset(-AppMetrics.s10)
        }
        surface.cover.snp.remakeConstraints { make in
            make.leading.width.equalTo(surface.transport)
            make.top.equalTo(surface.quality.snp.bottom).offset(AppMetrics.nowPlayingCoverTopGap)
            make.bottom.equalTo(surface.info.snp.top)
        }
        if lyrics {
            surface.lyrics.snp.remakeConstraints { make in
                make.trailing.equalToSuperview().offset(-side)
                make.width.equalTo(columnWidth)
                make.top.equalTo(safe.snp.top).offset(AppMetrics.nowPlayingPadLandscapeLyricsTop)
                make.bottom.equalTo(safe.snp.bottom)
            }
        } else {
            surface.lyrics.snp.remakeConstraints { make in
                make.leading.width.equalTo(surface.transport)
                make.top.equalTo(safe.snp.top).offset(AppMetrics.nowPlayingQualityTopOffset)
                make.bottom.equalTo(surface.info.snp.top)
                    .offset(-AppMetrics.nowPlayingLyricsBottomGap)
            }
        }
        pinLandscapeButtons(on: surface, safe: safe)
    }

    static func pinLandscapeButtons(on surface: Surface, safe: UILayoutGuide) {
        let top = AppMetrics.nowPlayingLandscapeTopInset
        surface.landscapePlay.snp.remakeConstraints { make in
            make.trailing.equalTo(safe.snp.trailing).offset(-top)
            make.top.equalTo(safe.snp.top).offset(top)
            make.size.equalTo(
                CGSize(
                    width: AppMetrics.nowPlayingChromeButtonSide,
                    height: AppMetrics.nowPlayingChromeButtonHeight
                )
            )
        }
        surface.landscapeExit.snp.remakeConstraints { make in
            make.trailing.equalTo(safe.snp.trailing).offset(-AppMetrics.nowPlayingChromeGap)
            make.bottom.equalTo(safe.snp.bottom).offset(-AppMetrics.nowPlayingChromeGap)
            make.size.equalTo(
                CGSize(
                    width: AppMetrics.nowPlayingChromeWideSide,
                    height: AppMetrics.nowPlayingChromeButtonHeight
                )
            )
        }
    }
}

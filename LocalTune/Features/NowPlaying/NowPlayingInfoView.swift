import MarqueeLabel
import SnapKit
import UIKit

/// 播放页的**信息行** —— 歌名（跑马灯）+ 艺人，右边两颗键（**收藏** + **引用/歌词**）。
///
/// 它只做一件事：把给它的三样东西摆上去。
/// 高度**由内容撑**：歌名一行 + 一个行距 + 艺人一行 —— 不写"总高 73.67"那种推导值
///
/// ⚠️ **歌名原样用 `Track.title`，不做兜底**：列表行和迷你条都是原样用
/// （`SongRow.make` 也是 `title: track.title`）。这一页自己兜一个"未知标题"，
/// 同一首歌在三处就会有两个名字。**没有标题这件事该在库那一层统一处理，不是这一页的事。**
///
/// ⚠️ **艺人同理**：`track.artist` 原样，空就空着 —— 这一行**只显示艺人**（不含专辑），
/// 理由见 `NowPlayingViewModel.Content.artist`。
final class NowPlayingInfoView: UIView {

    /// 点了收藏键。
    var onToggleFavorite: (() -> Void)?

    /// 点了引用键 —— 开 / 关歌词。
    var onToggleLyrics: (() -> Void)?

    /// 现在摆着的是什么 —— 值没变就不重画。
    private struct Displayed: Equatable {
        var title: String
        var artist: String
        var isFavorite: Bool
    }

    private var displayed: Displayed?

    private let titleLabel = MarqueeLabel()
    private let artistLabel = UILabel()
    private let favoriteButton = PressScaleButton(icon: nil)

    /// 「引用 / 歌词」键（`commentButton`）—— 开 / 关竖屏歌词。
    /// 位置：**在收藏键右边、间距 12、贴最右**。
    private let quoteButton = PressScaleButton(icon: nil)

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 对外

    /// 换内容。**值没变就什么都不做**（底下的订阅一秒能被叫到十几次）。
    ///
    /// ⚠️ 进度那条流**不许**订到这儿 —— MarqueeLabel 每次改 `text` 都会重置滚动
    /// （切歌或播放态变化才刷新信息行）。
    func show(title: String, artist: String, isFavorite: Bool) {
        let next = Displayed(title: title, artist: artist, isFavorite: isFavorite)
        guard next != displayed else { return }
        displayed = next

        titleLabel.text = title
        artistLabel.text = artist
        applyFavorite(isFavorite)
    }

    // MARK: - 装配

    private func buildSubviews() {
        titleLabel.font = AppFont.nowPlayingTitle
        // 🔴 **纯白** —— `titleLabel.textColor` 设成纯白（不掺 alpha）。
        titleLabel.textColor = AppColor.nowPlayingSolid
        titleLabel.speed = .rate(AppMetrics.marqueeScrollRate)
        titleLabel.fadeLength = AppMetrics.marqueeFadeLength
        titleLabel.trailingBuffer = AppMetrics.nowPlayingMarqueeTrailingBuffer
        titleLabel.animationDelay = AppMetrics.nowPlayingMarqueeStartDelay
        // 横向：愿意被拉宽（低拥抱），也愿意比固有字宽更窄（低抗压缩）——
        // 长歌名把剩余宽度吃满去滚，不跟右侧两键抢。
        // ⚠️ **别抄** label `.required` 抗压缩：右边是**固定宽 80**的
        // `playSettingView`，键不会被挤；我们键贴图标 intrinsic 宽，label 抗压缩反而会挤键。
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        artistLabel.font = AppFont.nowPlayingArtist
        artistLabel.textColor = AppColor.overlayTextSecondary
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        artistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        artistLabel.setContentHuggingPriority(.required, for: .vertical)
        artistLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        // ⚠️ 两颗键的图标颜色都必须显式给 —— `PressScaleButton` 默认取的是**浅色主题那一档**
        // （`AppColor.title`），而这一页是固定深色浮层，不给就成了深字压在深底上。
        favoriteButton.iconColor = AppColor.overlayTextSecondary
        favoriteButton.addTarget(self, action: #selector(favoriteTapped), for: .touchUpInside)
        // 键保持图标固有宽 —— 护的是键，不是歌名（见上面 label 那条理由）。
        favoriteButton.setContentHuggingPriority(.required, for: .horizontal)
        favoriteButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 初始是"关"：开播放页默认看封面（`AppSettings.lyricsVisible` 的初值也是关）。
        quoteButton.icon = Self.symbol(
            name: "quote.bubble", pointSize: AppMetrics.nowPlayingInfoActionIconPointSize
        )
        quoteButton.iconColor = AppColor.overlayTextSecondary
        quoteButton.accessibilityLabel = "歌词"
        quoteButton.addTarget(self, action: #selector(lyricsTapped), for: .touchUpInside)
        quoteButton.setContentHuggingPriority(.required, for: .horizontal)
        quoteButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(titleLabel)
        addSubview(artistLabel)
        addSubview(favoriteButton)
        addSubview(quoteButton)
        // 高度由歌名 + 艺人撑出来（表三）。纵向 required，封面撑宽抢不到这里。
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        applyPortraitArrangement()
    }

    /// 手机横屏只露歌名；其余形态仍是歌名 + 艺人 + 两键。
    func applyLayoutKind(_ kind: NowPlayingLayoutKind) {
        let compact = kind.usesCompactBlocks
        artistLabel.isHidden = compact
        favoriteButton.isHidden = compact
        quoteButton.isHidden = compact
        isUserInteractionEnabled = !compact
        if compact {
            applyLandscapeArrangement()
        } else {
            applyPortraitArrangement()
        }
    }

    private func applyPortraitArrangement() {
        titleLabel.snp.remakeConstraints { make in
            make.leading.equalToSuperview()
            make.top.equalToSuperview().offset(AppMetrics.nowPlayingInfoTopPadding)
            make.trailing.lessThanOrEqualTo(favoriteButton.snp.leading).offset(-AppMetrics.s10)
        }

        artistLabel.snp.remakeConstraints { make in
            make.leading.equalToSuperview()
            make.top.equalTo(titleLabel.snp.bottom).offset(AppMetrics.nowPlayingInfoLineGap)
            make.trailing.lessThanOrEqualTo(favoriteButton.snp.leading).offset(-AppMetrics.s10)
            make.bottom.equalToSuperview()
                .offset(-AppMetrics.nowPlayingInfoBottomPadding)
        }

        quoteButton.snp.remakeConstraints { make in
            make.trailing.equalToSuperview()
            make.top.equalToSuperview().offset(AppMetrics.nowPlayingInfoTopPadding)
            make.height.equalTo(AppMetrics.nowPlayingChromeButtonHeight)
        }
        favoriteButton.snp.remakeConstraints { make in
            make.trailing.equalTo(quoteButton.snp.leading)
                .offset(-AppMetrics.nowPlayingInfoActionGap)
            make.centerY.equalTo(quoteButton)
            make.height.equalTo(AppMetrics.nowPlayingChromeButtonHeight)
        }
    }

    private func applyLandscapeArrangement() {
        titleLabel.snp.remakeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalToSuperview().offset(AppMetrics.nowPlayingInfoLandscapeTopPadding)
            make.bottom.equalToSuperview()
        }
    }

    // MARK: - 收藏

    /// 收藏态**只用图标表达**：空心 `heart` ↔ 实心 `heart.fill`。
    ///
    /// 🔴 **颜色不跟着变** —— 每次都调
    /// `styleChrome(songInfo.favoriteButton, heart, ...)`，而那个函数里 tint 恒为
    /// `NowPlayingChrome.tint`（次级 70%）；收藏前后**只有图标换**。
    /// ⚠️ 我们原来还额外"提亮一档"（收藏后给 `overlayText` 90%）—— 已去掉（用户要求颜色一致）。
    /// ⚠️ 也不用红色：那颗心不是红的，特意染红反而变成"另一个 App 的收藏"。
    private func applyFavorite(_ isFavorite: Bool) {
        favoriteButton.icon = Self.symbol(
            name: isFavorite ? "heart.fill" : "heart",
            pointSize: AppMetrics.nowPlayingInfoActionIconPointSize
        )
        favoriteButton.iconColor = AppColor.overlayTextSecondary
        // 无障碍念的是"这个键干什么" —— 已收藏时它要能让用户取消收藏。
        favoriteButton.accessibilityLabel = isFavorite ? "取消收藏" : "收藏"
        favoriteButton.accessibilityValue = isFavorite ? "已收藏" : nil
    }

    // MARK: - 歌词开关

    /// 歌词开着没有 —— 决定引用键画空心的 `quote.bubble` 还是实心的 `quote.bubble.fill`。
    ///
    /// 🔴 **只换图标、不换颜色**：`updateLyricsToggleIcon`
    /// 每次也只换符号名，tint 始终是那一个 `overlayTextSecondary`。给它染个色（比如开时变黄）
    /// 就是"另一个 App 的开关"了 —— 跟收藏那颗心"只有图标换、颜色不动"是同一条规矩。
    func setLyricsToggleActive(_ isActive: Bool) {
        quoteButton.icon = Self.symbol(
            name: isActive ? "quote.bubble.fill" : "quote.bubble",
            pointSize: AppMetrics.nowPlayingInfoActionIconPointSize
        )
        quoteButton.iconColor = AppColor.overlayTextSecondary
        quoteButton.accessibilityValue = isActive ? "已显示" : nil
    }

    private static func symbol(name: String, pointSize: CGFloat) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        )
    }

    @objc private func favoriteTapped() {
        onToggleFavorite?()
    }

    @objc private func lyricsTapped() {
        onToggleLyrics?()
    }
}


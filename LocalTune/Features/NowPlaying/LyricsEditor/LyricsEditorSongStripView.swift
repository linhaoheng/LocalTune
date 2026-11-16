import SnapKit
import UIKit

/// 「编辑歌词」页顶部那条 —— 封面 ＋ 歌名/艺人 ＋ 当前时间 ＋ 播放键。
///
/// 📍 版式，数值全在 `AppMetrics.lyricsEditor*` 里。
///
/// 🔴 **它不认识播放器**：时间与在播否都由页面从 `PlayManager` 那两条流收到之后转过来
/// （`setPosition` / `setPlaying`）—— 这一层只管画。
final class LyricsEditorSongStripView: UIView {

    private let coverImageView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let timeLabel = UILabel()
    private let playButton = PressScaleButton(icon: nil, iconColor: AppColor.accent)

    /// 点播放 / 暂停。页面把它接到 `PlayManager.togglePlayPause`。
    var onTogglePlayback: (() -> Void)?

    /// 封面 —— 由页面按 `ArtworkProvider` 取好塞进来（**这一层不认识封面存在哪**）。
    func setCover(_ image: UIImage?) {
        if let image {
            coverImageView.image = image
            coverImageView.contentMode = .scaleAspectFill
        } else {
            coverImageView.image = UIImage(systemName: "music.note")
            coverImageView.contentMode = .center
        }
    }

    /// 歌名 / 艺人 —— **只显示艺人**（`track.artist` 原样、空就空着，跟播放页同一条）。
    func setSong(title: String, artist: String) {
        titleLabel.text = title
        artistLabel.text = artist
    }

    /// 这一刻播到几秒。
    ///
    /// 🔴 走 `DurationText`（全工程唯一一处时长格式化），**不自己拼 `分:秒`**
    /// —— `PlaybackTime.format` 是另一份，抄进来就成了"同一规则两处记着"。
    func setPosition(_ position: TimeInterval) {
        timeLabel.text = DurationText.text(seconds: Int(position.rounded()))
    }

    /// 播放键画哪一个。**「在装」也算在播**（同 `isPlaybackActive` 的口径，换歌那几百毫秒不闪）。
    func setPlaying(_ playing: Bool) {
        playButton.icon = UIImage(
            systemName: playing ? "pause.fill" : "play.fill",
            withConfiguration: Self.playSymbol
        )
    }

    // MARK: - 数值

    /// 播放键那颗图标的大小。
    ///
    /// 📍 那颗是**系统默认大小**（只给了 tint，没给尺寸）—— 我们给一个
    /// **跟播放页一致**的字号，免得两处的播放键一眼看出大小不同。
    private static let playSymbol = UIImage.SymbolConfiguration(
        pointSize: AppMetrics.nowPlayingIconPointSize, weight: .regular
    )

    // MARK: - 建立

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpSubviews()
        setUpConstraints()
        setPlaying(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    private func setUpSubviews() {
        backgroundColor = AppColor.surface
        layer.cornerRadius = AppMetrics.lyricsEditorSongStripCornerRadius

        coverImageView.clipsToBounds = true
        coverImageView.layer.cornerRadius = AppMetrics.lyricsEditorCoverCornerRadius

        titleLabel.font = AppFont.lyricsEditorSongTitle
        titleLabel.textColor = AppColor.title
        titleLabel.numberOfLines = 1

        artistLabel.font = AppFont.lyricsEditorSongArtist
        artistLabel.textColor = AppColor.subtitle
        artistLabel.numberOfLines = 1

        timeLabel.font = AppFont.lyricsEditorSongTime
        timeLabel.textColor = AppColor.secondaryText
        timeLabel.textAlignment = .right

        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)

        [coverImageView, titleLabel, artistLabel, timeLabel, playButton].forEach(addSubview)
    }

    private func setUpConstraints() {
        let side = AppMetrics.lyricsEditorSongStripInset
        coverImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(side)
            make.centerY.equalToSuperview()
            make.size.equalTo(AppMetrics.lyricsEditorCoverSide)
        }
        playButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-side)
            make.centerY.equalToSuperview()
            make.size.equalTo(AppMetrics.lyricsEditorPlayButtonSide)
        }
        timeLabel.snp.makeConstraints { make in
            make.trailing.equalTo(playButton.snp.leading).offset(-AppMetrics.lyricsEditorSongStripTimeGap)
            make.centerY.equalToSuperview()
            make.width.equalTo(AppMetrics.lyricsEditorSongStripTimeWidth)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(coverImageView.snp.trailing).offset(AppMetrics.lyricsEditorCoverTitleGap)
            make.trailing.equalTo(timeLabel.snp.leading).offset(-AppMetrics.lyricsEditorSongStripTimeGap)
            make.top.equalToSuperview().offset(AppMetrics.lyricsEditorSongTitleTop)
        }
        artistLabel.snp.makeConstraints { make in
            make.leading.trailing.equalTo(titleLabel)
            make.top.equalTo(titleLabel.snp.bottom).offset(AppMetrics.lyricsEditorSongArtistGap)
            make.bottom.equalToSuperview().offset(-AppMetrics.lyricsEditorSongArtistBottom)
        }
    }

    @objc private func playTapped() { onTogglePlayback?() }
}

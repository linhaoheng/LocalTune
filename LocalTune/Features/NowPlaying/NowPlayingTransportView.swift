import SnapKit
import UIKit

/// 播放页的**传输行** —— 播放模式 · 上一首 · 播放/暂停 · 下一首 · 队列（竖屏五键）。
///
/// 🔴 **五个键一对一对齐**（竖屏就是这五个：
/// `repeatBtn` / `backBtn` / `playBtn` / `nextBtn` / `listBtn` —— 最左那颗叫 repeat，
/// 我们管的是整套 `PlaybackMode`，代码里叫 `modeButton`）。
/// 这一刀里**四个是真动作**，队列那个点了只能说一句「队列页还没做」——
/// 队列**数据**是有的（`PlayQueue`），**页面**还没做，位置先留着、给反馈，不当死按钮。
///
/// ⚠️ **模式的图标和文案归界面管**（见 `face(_:)`）—— 不写进 `PlaybackMode`。
///
/// 🔴 **不因「无歌」灰键**：无当前曲进不了这一页（`AppRouter.presentNowPlaying`）；
/// 页开着删空队列只 dismiss、不 `show` 空态。`TransportView` 也不因无歌禁上/播/下。
/// 曾有的 `hasTrack` 置灰是「空页可待」死分支，已删。
///
/// **纯界面**：不认识播放器、不认识库 —— 只认五个回调和"现在长什么样"。
final class NowPlayingTransportView: UIView {

    // MARK: - 回调

    var onPlaybackMode: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onQueue: (() -> Void)?

    // MARK: - 私有

    /// 现在摆着的样子 —— 值没变就不重画。
    private struct Displayed: Equatable {
        var playbackMode: PlaybackMode
        var isPlaybackActive: Bool
    }

    private var displayed: Displayed?

    private let modeButton = PressScaleButton(icon: nil)
    private let previousButton = PressScaleButton(icon: nil)
    private let playPauseButton = PressScaleButton(icon: nil)
    private let nextButton = PressScaleButton(icon: nil)
    private let queueButton = PressScaleButton(icon: nil)

    // MARK: - 建立

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildSubviews()
        wireActions()
        // 先摆一次默认键面，等内容流推来真状态。
        show(playbackMode: .sequential, isPlaybackActive: false)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 对外

    /// 换样子。
    ///
    /// - Parameter isPlaybackActive: 画「暂停」还是「播放」—— 用 `PlayerState.isPlaybackActive`
    ///   （**在装也算在播**），跟迷你条同一套。
    func show(
        playbackMode: PlaybackMode,
        isPlaybackActive: Bool
    ) {
        let next = Displayed(
            playbackMode: playbackMode,
            isPlaybackActive: isPlaybackActive
        )
        guard next != displayed else { return }
        displayed = next

        let face = Self.face(playbackMode)
        modeButton.icon = Self.symbol(face.symbol)
        modeButton.accessibilityLabel = "播放模式"
        modeButton.accessibilityValue = face.label

        playPauseButton.icon = Self.symbol(
            isPlaybackActive ? "pause.fill" : "play.fill",
            pointSize: AppMetrics.nowPlayingPlayIconPointSize
        )
        playPauseButton.accessibilityLabel = isPlaybackActive ? "暂停" : "播放"
    }

    // MARK: - 装配

    private func buildSubviews() {
        // ⚠️ 图标颜色必须**逐个显式给**：`PressScaleButton` 默认取的是浅色主题那一档
        // （`AppColor.title`），这一页是固定深色浮层，不给就是深字压深底。
        //
        // 🔴 传输行五颗**全是纯白**（`nowPlayingSolid`）—— `TransportView.swift:129`
        // 那个 `styleSymbol(...)` 里就是把 tint 设成纯白，五颗全走它。
        //
        // 📍 **只设"永远不变"的那几个**；模式键和播放键的**图标**每次状态变了都要重设，
        // 那两行在 `show(...)` 里。
        let controlColor = AppColor.nowPlayingSolid
        modeButton.iconColor = controlColor
        previousButton.iconColor = controlColor
        playPauseButton.iconColor = controlColor
        nextButton.iconColor = controlColor
        queueButton.iconColor = controlColor

        previousButton.icon = Self.symbol(
            "backward.fill", pointSize: AppMetrics.nowPlayingSkipIconPointSize
        )
        nextButton.icon = Self.symbol(
            "forward.fill", pointSize: AppMetrics.nowPlayingSkipIconPointSize
        )
        queueButton.icon = Self.symbol("music.note.list")

        previousButton.accessibilityLabel = "上一首"
        nextButton.accessibilityLabel = "下一首"
        queueButton.accessibilityLabel = "播放队列"

        let buttons = [modeButton, previousButton, playPauseButton, nextButton, queueButton]
        buttons.forEach(addSubview)

        // 中间那个键**上下贴死这一块** ⇒ 这一块的高度就是它撑出来的
        //（边上那几个也一样高 60，不会顶出去）。
        playPauseButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.bottom.equalToSuperview()
            make.size.equalTo(AppMetrics.nowPlayingPlayButtonSize)
        }

        let gap = AppMetrics.nowPlayingTransportCenterGap
        previousButton.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.trailing.equalTo(playPauseButton.snp.leading).offset(-gap)
            make.size.equalTo(Self.sideButtonSize)
        }
        nextButton.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalTo(playPauseButton.snp.trailing).offset(gap)
            make.size.equalTo(Self.sideButtonSize)
        }
        modeButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(AppMetrics.nowPlayingTransportSideInset)
            make.centerY.equalToSuperview()
            make.size.equalTo(Self.sideButtonSize)
        }
        queueButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-AppMetrics.nowPlayingTransportSideInset)
            make.centerY.equalToSuperview()
            make.size.equalTo(Self.sideButtonSize)
        }
    }

    private func wireActions() {
        modeButton.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        previousButton.addTarget(self, action: #selector(previousTapped), for: .touchUpInside)
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        queueButton.addTarget(self, action: #selector(queueTapped), for: .touchUpInside)
    }

    /// 两侧键的点击区 —— 40 宽、60 高（和中间那个一样高，点击区上下都贴满）。
    private static var sideButtonSize: CGSize {
        CGSize(
            width: AppMetrics.nowPlayingSideButtonWidth,
            height: AppMetrics.nowPlayingSideButtonHeight
        )
    }

    /// 控制键的图标：点大小统一走令牌（`PressScaleButton` 的图标尺寸由图自己带）。
    private static func symbol(
        _ name: String,
        pointSize: CGFloat = AppMetrics.nowPlayingIconPointSize
    ) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        )
    }

    // MARK: - 播放模式键面

    /// 给人看 / 念的那句话 —— 切模式 HUD 和无障碍共用。
    static func label(_ mode: PlaybackMode) -> String {
        face(mode).label
    }

    /// 这一档的图标和无障碍文案。
    private static func face(_ mode: PlaybackMode) -> (symbol: String, label: String) {
        switch mode {
        case .sequential: return ("arrow.left.arrow.right", "顺序播放")
        case .all: return ("repeat", "列表循环")
        case .one: return ("repeat.1", "单曲循环")
        case .shuffle: return ("shuffle", "随机播放")
        }
    }

    // MARK: - 动作

    @objc private func modeTapped() { onPlaybackMode?() }
    @objc private func previousTapped() { onPrevious?() }
    @objc private func playPauseTapped() { onPlayPause?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func queueTapped() { onQueue?() }
}

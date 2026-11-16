import SnapKit
import UIKit

/// 播放页的**进度条** —— 一条能拖的滑杆 + 两头各一个时间（左：**已播** · 右：**还剩**）。
///
/// ## 三件事按"谁说了算"分好了
///
/// - **平时**：滑杆跟着页面推下来的位置走（那个位置是 `NowPlayingViewModel` 算过的 ——
///   拖动中它推的是**手指的位置**，不是引擎读数）；
/// - **拖着的时候**：只往上报三个动作（按下 / 拖到哪 / 松手），**自己不判任何事**；
/// - **"到底跳不跳、什么时候跳"**：在 ViewModel 那边（松手才跳）。
///
/// ⇒ 这个类是**纯界面**：它不认识播放器、不认识库，只会"画"和"报动作"。
///
/// ## 两个细节
///
/// 1. **圆点是"常显"的**：`normal` 和 `.highlighted` 都是那颗白圆 ——
///    两个状态给**同一张白圆**（`ProgressView.swift:63-64`）。
///    ⚠️ 另一种写法是"常态一张全透明图、按下才显"（`transparentThumbImage` + `isTouch`）——
///    那种肉眼能看出差，别做。
/// 2. **滑杆的量程直接是"秒"**（`0...duration`），不是 `0...1`：少一层换算就少一处能算错的地方。
/// 3. **相对拖动**：手指在条上拖多远，圆点就走多远 —— **不是**点哪跳哪（见 `SeekSlider`）。
final class NowPlayingProgressView: UIView {

    // MARK: - 动作（全部转给 ViewModel，这儿不判事）

    /// 手指按下 —— 从这一刻起引擎读数不算数。
    var onScrubBegan: ((TimeInterval) -> Void)?
    /// 手指拖到了哪儿（只更新界面）。
    var onScrubChanged: ((TimeInterval) -> Void)?
    /// 手指抬起 —— **这时候才真的跳**。
    var onScrubEnded: ((TimeInterval) -> Void)?

    // MARK: - 私有

    private let slider = SeekSlider()
    private let elapsedLabel = UILabel()

    /// 右边那个 —— 🔴 **剩余时间**（带负号，`-04:05`），**不是总时长**。
    ///
    /// 写法：`remainingLabel.text = "-\(clock(max(0, duration - time)))"`；截图里也是 `-04:05`。
    /// ⚠️ 总长仍然要从外面传进来 —— 剩余时间是它减出来的，`show(elapsed:duration:)` 的入参不变。
    private let remainingLabel = UILabel()

    /// 上一次摆过的内容 —— 值没变就不重画（底下的订阅一秒能被叫到十几次）。
    private var displayed: (elapsed: TimeInterval, duration: TimeInterval)?

    // MARK: - 建立

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildSubviews()
        wireActions()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 对外

    /// 换位置和总长（都是秒）。
    ///
    /// - Parameters:
    ///   - elapsed: 这一刻该画在哪儿。
    ///   - duration: 总长；`<= 0` ＝ **还不知道**（引擎还没报、库里也没记）⇒ 整块禁用。
    func show(elapsed: TimeInterval, duration: TimeInterval) {
        guard displayed?.elapsed != elapsed || displayed?.duration != duration else { return }
        displayed = (elapsed, duration)

        guard duration > 0 else {
            // 总长都不知道，画不了比例 —— 禁用，并把滑块**归零**。
            // 只禁用不归零的话，换歌装载那几百毫秒会停在上一首的位置再弹回来。
            slider.isEnabled = false
            slider.value = 0
            elapsedLabel.text = nil
            remainingLabel.text = nil
            return
        }

        slider.isEnabled = true
        slider.minimumValue = 0
        slider.maximumValue = Float(duration)
        // ⚠️ 拖动中把同一个值写回去是**无害的**：上面推下来的就是滑杆刚报上去的那个数，
        // 写回去等于没动。真正要防的（引擎读数把滑块拽回去）在 ViewModel 那边拦掉了。
        slider.value = Float(min(max(elapsed, 0), duration))

        // ⚠️ 负数在 `DurationText` 里是"程序员写错"，所以两个都先夹一下再传 ——
        // 进度这种东西天然可能是 -0.0001（引擎浮点）。
        elapsedLabel.text = DurationText.text(seconds: Int(max(elapsed, 0).rounded()))
        // 🔴 **右边是"还剩多久"**（带负号的剩余），不是"一共多久"。
        remainingLabel.text =
            "-" + DurationText.text(seconds: Int(max(duration - elapsed, 0).rounded()))
    }

    // MARK: - 装配

    private func buildSubviews() {
        // ⚠️ `UISlider` **没有** `minimumTrackImage` 这种属性 —— 只有 `setMinimumTrackImage(_:for:)`
        // 这个方法（旧的 `setMinimumTrackImage:forState:`）。写属性名那样是编译不过的。
        // ⚠️ 同时**不再设** `minimumTrackTintColor` / `maximumTrackTintColor`：图上已经带了颜色，
        // 设了也不算数（图优先）—— 那就成了"同一个颜色两处写着"，早晚走散。
        slider.setMinimumTrackImage(
            Self.trackImage(color: AppColor.nowPlayingSolid), for: .normal
        )
        slider.setMaximumTrackImage(Self.trackImage(color: AppColor.overlayBorder), for: .normal)
        // 🔴 **常显**：两个状态都挂白圆（见类型顶上第 1 条）—— 原来常态挂的是一张全透明图。
        slider.setThumbImage(Self.thumb(), for: .normal)
        slider.setThumbImage(Self.thumb(), for: .highlighted)
        slider.accessibilityLabel = "播放进度"

        for label in [elapsedLabel, remainingLabel] {
            label.font = AppFont.nowPlayingTime
            // 🔴 **纯白**（不是次级白）—— `ProgressView.swift:67-68` 两个时间的 `textColor` 都是纯白。
            // 原来给的是 `overlayTextSecondary`（70%），暗了一档。
            label.textColor = AppColor.nowPlayingSolid
            label.setContentHuggingPriority(.required, for: .vertical)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        remainingLabel.textAlignment = .right

        addSubview(slider)
        addSubview(elapsedLabel)
        addSubview(remainingLabel)
        // 高度由滑杆 + 时间撑出来（表三）。纵向 required，封面撑宽抢不到这里。
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        applyPortraitArrangement()
    }

    /// 手机横屏只留轨道；时间藏掉，高度跟着滑杆走。
    func applyLayoutKind(_ kind: NowPlayingLayoutKind) {
        let compact = kind.usesCompactBlocks
        elapsedLabel.isHidden = compact
        remainingLabel.isHidden = compact
        if compact {
            applyLandscapeArrangement()
        } else {
            applyPortraitArrangement()
        }
    }

    private func applyPortraitArrangement() {
        slider.snp.remakeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalToSuperview().offset(AppMetrics.nowPlayingProgressTopPadding)
            make.height.equalTo(AppMetrics.nowPlayingSliderThumbSize)
        }

        elapsedLabel.snp.remakeConstraints { make in
            make.leading.equalToSuperview()
            make.top.equalTo(slider.snp.bottom).offset(AppMetrics.nowPlayingProgressLabelGap)
            make.bottom.equalToSuperview()
                .offset(-AppMetrics.nowPlayingProgressBottomPadding)
        }

        remainingLabel.snp.remakeConstraints { make in
            make.trailing.equalToSuperview()
            make.centerY.equalTo(elapsedLabel)
            make.leading.greaterThanOrEqualTo(elapsedLabel.snp.trailing).offset(AppMetrics.s8)
        }
    }

    private func applyLandscapeArrangement() {
        slider.snp.remakeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.bottom.equalToSuperview()
            make.height.equalTo(AppMetrics.nowPlayingSliderThumbSize)
        }
    }

    private func wireActions() {
        // ⚠️ 按下就要报：从这一刻起引擎读数就不该再推滑杆了。
        // 只靠 `valueChanged` 的话，按住不动的那段时间里滑杆会被读数拽着走。
        slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        // 三个"抬手"都要接：落在滑杆上、落在外面、被系统打断（来电、手势）。
        // 漏一个的话，那一次拖动就永远不会结束 —— 进度条会一直"听手指的"。
        slider.addTarget(self, action: #selector(scrubEnded), for: .touchUpInside)
        slider.addTarget(self, action: #selector(scrubEnded), for: .touchUpOutside)
        slider.addTarget(self, action: #selector(scrubEnded), for: .touchCancel)
    }

    // MARK: - 动作

    @objc private func scrubBegan() {
        onScrubBegan?(TimeInterval(slider.value))
    }

    @objc private func scrubChanged() {
        onScrubChanged?(TimeInterval(slider.value))
    }

    @objc private func scrubEnded() {
        onScrubEnded?(TimeInterval(slider.value))
    }

    // MARK: - 轨道与圆点的图

    /// 轨道图：一条圆角短线，左右各留一点"可拉伸帽"。
    ///
    /// ⚠️ 必须能拉伸（`resizableImage`）：不写的话，`UISlider` 会把这 8 点宽的小图
    /// **两端直接拉长**，圆角被拉成斜角。
    ///
    /// ⚠️ 宽度那个 `× 4` 是**推出来的、不是设计值**：两端各需要一个完整的圆角（半径 2 ⇒ 2 点），
    /// 再各留一倍余量给拉伸 —— 比 `半径 × 4` 窄就会看到变形。
    private static func trackImage(color: UIColor) -> UIImage {
        let height = AppMetrics.nowPlayingSliderTrackHeight
        let width = AppMetrics.nowPlayingSliderTrackCornerRadius * 4
        let size = CGSize(width: width, height: height)

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerRadius: AppMetrics.nowPlayingSliderTrackCornerRadius
            ).fill()
        }
        let cap = AppMetrics.nowPlayingSliderTrackCornerRadius
        return image.resizableImage(
            withCapInsets: UIEdgeInsets(top: 0, left: cap, bottom: 0, right: cap)
        )
    }

    /// 那颗白圆（常显）。
    ///
    /// 🔴 用 `nowPlayingSolid`（**不掺 alpha 的实白**），**不是** `overlayText` ——
    /// 后者是 `whiteA11`（alpha 90%）的半透明白，压在深底上就是一颗"半透明的白点"。
    /// `ProgressView.swift:110-117` 用的是**不掺 alpha 的纯白**。
    private static func thumb() -> UIImage {
        let side = AppMetrics.nowPlayingSliderThumbSize
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { _ in
            AppColor.nowPlayingSolid.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        }
    }

}

/// 进度条专用的滑杆。
///
/// 两件事：
/// 1. **扩大命中区**（`point(inside:)`）—— 轨道细，上下多吃一点才好按；
/// 2. **相对拖动**（`SeekSlider`）—— 手指在轨道/热区上左右拖，
///    进度跟**拖了多远**走，**不是**「点到哪进度跳到哪」。
///    默认 `UISlider` 按下会把圆点吸到触摸点；这里关掉那套，只认位移增量。
private final class SeekSlider: UISlider {

    /// 不调 super：`UISlider` 默认按触摸点绝对定位（圆点吸过去）。
    ///
    /// ⚠️ `touchDown` / `touchUpInside` / `touchUpOutside` / `touchCancel` 由 `UIControl`
    /// 自己发，**这里不许再手动发** —— 再发一遍就是每次松手 `seek` 两次。
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        true
    }

    /// 按位移增量推值。`valueChanged` 本来由 `UISlider` 的 super 发，跳过了 super 只能自己发。
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let dx = touch.location(in: self).x - touch.previousLocation(in: self).x
        let width = max(trackRect(forBounds: bounds).width, 1)
        let delta = Float(dx / width) * (maximumValue - minimumValue)
        setValue(value + delta, animated: false)
        sendActions(for: .valueChanged)
        return true
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(
            dx: -AppMetrics.nowPlayingSliderHitExpandX,
            dy: -AppMetrics.nowPlayingSliderHitExpandY
        ).contains(point)
    }
}

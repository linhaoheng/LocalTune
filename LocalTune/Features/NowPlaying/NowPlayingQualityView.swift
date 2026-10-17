import SnapKit
import UIKit

/// 播放页的**音质条** —— 一行说明文字 ＋ 一枚档位徽章：`FLAC · 16bit/44.1kHz` ＋ `SQ`。
///
/// 🔴 **数据是现成的**：`Track.format / sampleRate / bitDepth / bitRate` 在**导入那一刻**
/// 就读进库了（`MetadataReader`）。**不重新打开文件现算** —— 每次显示都重读一遍
/// （`AudioQuality(track:)` 里现开一次文件），那是白白地把 IO 放到"一进页面"这个当口上。
/// ⚠️ **算的地方变了，呈现出来的样子一模一样** —— 所以下面每一条都按
/// `PlayingQualityInfoView` 的规格写。
///
/// ## 这一块自己不管位置和大小
///
/// 🔴 **位置（安全区 + 44）和高度（24）是页面给的**（`NowPlayingViewController.layout()`，
/// 走 `AppMetrics.nowPlayingQualityTopOffset` / `nowPlayingQualityBarHeight`）——
/// 就是这么分的（`NowPlayingViewController.swift:273-277`）。
/// ⇒ 所以这里**只负责"内容在这一块里怎么摆"**：整组居中（`contentContainer.center = superview`）。
///
/// ⚠️ 一条都读不到时**文字留空、徽章藏起来，但这一块照样占位** —— 高度是页面写死的 24，
/// 跟有没有内容无关，**不压 0、封面不上移**。
final class NowPlayingQualityView: UIView {

    /// 这一块内部的数。
    ///
    /// ⚠️ 先放这儿、**不往 `AppMetrics` 放**：它只有这一个地方用
    ///（走 `AppMetrics` 的是**页面那条链上**的数，见 `NowPlayingViewController.layout()`）。
    private enum Metrics {

        /// 文字和徽章之间那点缝：**6**。
        ///
        /// `PlayingQualityInfoView`（`badge.leading = textLabel.trailing + 6`）。
        static let badgeGap: CGFloat = 6
    }

    private let textLabel = UILabel()

    /// 档位徽章 —— 字号是**播放页这一档**（9 粗）；列表行那枚是 8 粗，分两档。
    private let badge = QualityBadge(font: AppFont.nowPlayingQualityBadge)

    /// 文字 ＋ 徽章横着排，**整组居中**。
    ///
    /// ⚠️ 用 `UIStackView` 而不是手算两条约束：徽章一藏，这一组**自己**就只剩文字、
    /// 居中照样是居中的（手算的话还得跟着改约束）。
    private let contentStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 对外

    /// 换内容。`nil` ＝ 这一条什么都没有 ⇒ 文字留空、徽章藏起来，但**这一块不收起**（高度照旧占着）。
    ///
    /// ⚠️ 不做「值没变就不重画」那种去重：文字的真相已经在 `textLabel.text` 上，
    /// 再存一份 `displayedText` 就是同一个事实有两个出处 —— 而且这里由**低频**的内容流驱动
    /// （换歌 / 收藏变了 / 开关翻了才发），根本没有需要挡的重复。
    func show(_ line: AudioQualityLine?) {
        textLabel.text = line?.text
        // ⚠️ 没有音质信息时**徽章要整枚藏掉** —— 只把文字清空的话，
        // 它会留一个空胶囊（左右内边距那 6 点的渐变色块）杵在那儿。
        badge.isHidden = line == nil
        if let line { badge.show(line.level) }
    }

    // MARK: - 装配

    private func buildSubviews() {
        textLabel.font = AppFont.nowPlayingQuality
        textLabel.textColor = AppColor.overlayTextSecondary
        textLabel.textAlignment = .center
        textLabel.lineBreakMode = .byTruncatingTail

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = Metrics.badgeGap
        contentStack.addArrangedSubview(textLabel)
        contentStack.addArrangedSubview(badge)
        addSubview(contentStack)

        // 🔴 **整组居中**（`contentContainer.center = superview`）。
        //
        // ⚠️ 这里**不要**再钉高度、也不要"上下一贴"：这一块的位置和高度**都是页面给的固定值**
        //（安全区 + 44、高 24），内容只要在这一块里居中就对了。
        // ⚠️ 曾经自己在这儿算高度（"一行字那么高" ≈ 13），结果和 24 对不上 ——
        // 位置、大小全错。**高度不归这里管。**
        //
        // 🔴 **宽度要加上限**（这一条**有意偏离**）：`contentContainer` 只有 `center`
        // 一条，内容一超宽就**直接溢出到屏幕外**（不截断）。正常长度的音质文字放得下，
        // 但系统文字调到最大时那一段文字就顶出去了。
        // 这里面是毛病，不学。⇒ 补两条上限；超了让**文字**去截断（它的 `lineBreakMode`
        // 是 `.byTruncatingTail`、抗压缩优先级 750 又低于徽章的 required），
        // 徽章那两个字永远完整。
        contentStack.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview()
            make.trailing.lessThanOrEqualToSuperview()
        }
    }
}

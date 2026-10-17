import SnapKit
import UIKit

/// 歌曲列表的一行：封面 + 歌名 + 「艺人 - 专辑」 ＋ 音质那一小枚 + 行尾更多菜单 / 勾选标记。
///
/// 🔴 它**只画**：拿到的是排好版的一行内容（`SongRow`），不查数据、不做判断。
///
/// ⚠️ **这一行归 `Components/`**：曲库页和歌单详情页显示的是**同一个行**
/// （两个页面也共用同一个 `SongNormalCell`）—— 各写一份必然走散。
/// 它和 `SongRow` 是这个目录里**唯一**依赖 `Data` 层类型的那条边
///（取封面走 `ArtworkStore`）：行画的就是"一首歌"，箭头方向 `Components → Data` 是允许的。
final class SongTableCell: UITableViewCell {

    static let reuseIdentifier = "SongTableCell"

    /// 行高的**下限** —— 字没放大时就是它，放大了让内容自己撑开。
    ///
    /// ⚠️ 放在 `Metrics` 外面是有意的：列表要拿它当**估算行高**（`estimatedRowHeight`），
    /// 那是页面的事，得看得见。
    static let minimumHeight: CGFloat = 60

    /// 封面边长 —— 行里那一格多大。
    ///
    /// ⚠️ **对外可见、不放 `Metrics` 里**：列表页的封面**预取**也要用同一个尺寸
    /// （见 `SongsViewController` 的预取那块）。两处各写一个数的话，改尺寸那天就会变成
    /// "预取的是一种、画出来是另一种"，预取白做。
    static let artworkSide: CGFloat = 45

    private enum Metrics {

        static let artworkCornerRadius: CGFloat = 5
        static let textSpacing: CGFloat = 6

        /// 封面到文字的常态间距：**10**（`infoOffset`）。
        static let infoLeading: CGFloat = 10

        /// 正在播时文字再退一点，给竖杠腾位：**32**（`currentTrackInfoLeading`）。
        static let currentTrackInfoLeading: CGFloat = 32

        /// 竖杠边长 —— 16；设计文档也写 16×16。
        static let playingBarsSide: CGFloat = 16

        /// 「艺人 - 专辑」和格式标记之间那条缝：**4**。
        ///
        /// `artistToFormatGap` = 4（`formatLabel.leading = artistLabel.trailing + 4`）。
        static let artistToFormatGap: CGFloat = 4

        /// 格式标记和音质徽章之间那条缝：**3**。
        ///
        /// `formatToBadgeGap` = 3（`qualityBadge.leading = formatLabel.trailing + 3`）。
        /// ⚠️ 跟上面那个 4 **不是一个数**（本来就是两个数）—— 所以它俩不能合成一个 `spacing`。
        static let formatToBadgeGap: CGFloat = 3

        /// 行尾「更多」按钮的点击区宽度 —— 也是**勾选模式**下那一枚的宽度。
        ///
        /// **`32`** —— 照 primuse 的行尾菜单按钮
        /// （`Views/Components/SongRowView.swift:546-549`：`ellipsis` 那张图外面留的框是 32×32）。
        ///
        /// ⚠️ 这个宽度**连带管着文字能占多宽**（`textStack.trailing` 是拿它算的）——
        /// 改它不只是挪一下图标，整行的文字可用宽度会跟着变。
        ///
        /// ⚠️ 两种状态**共用同一格**：勾选标记也在这一格里（它换的就是这同一颗按钮
        /// 的图，不是另摆一个视图）—— 所以换模式时文字那一列**不会跟着跳**。
        static let moreButtonWidth: CGFloat = 32

        /// 行尾「更多」图标的大小 —— **系统正文档（`.body`，17）**。
        ///
        /// ⚠️ 别凭感觉放大：这一档才和行里的文字是同一份视觉重量。
        /// 调大了整行看起来就是"按钮比内容还抢眼"。
        ///
        /// ⚠️ 它是**固定值**，不跟系统文字大小走（行里的字会放大，这个不会）——
        /// 字号调到很大时图标会显得偏小，那时再谈要不要让它跟着缩放。
        static let moreIconPointSize: CGFloat = 17

        /// 挑歌页右侧图标：已加入和未加入都用 17pt semibold。
        static let selectionIconPointSize: CGFloat = 17

        /// 文字右缘离「更多」的常态间距（无播放次数时）。
        static let trailDefault: CGFloat = AppMetrics.s10

        /// 文字右缘离「更多」—— 中间要给「耳机 + 次数」腾位（`trailWithPlayCountOffset = 50`）。
        static let trailWithPlayCount: CGFloat = 50

        /// 分隔线的左缩进 —— 对齐到**文字的左边缘**。
        ///
        /// ⚠️ 必须显式设：`UITableViewCell` 的默认缩进是 16，不是"对齐文字"。
        /// 位置 = 左右内边距 + 封面 + 封面到文字的间距。
        static var separatorInset: CGFloat {
            AppMetrics.s15 + SongTableCell.artworkSide + AppMetrics.s10
        }
    }

    // MARK: - 零件

    private let artworkView = UIImageView()
    private let playingBars = PlayingBarsView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    /// 格式标记（`FLAC` / `ALAC` / `MP3`）—— 细描边的小圆角标签。
    private let formatTag = FormatTag()

    /// 音质档位徽章（`SD` / `HQ` / `SQ` / `HR`）—— 跟播放页共用同一个组件。
    ///
    /// ⚠️ 字号是**列表行这一档**（**8 粗**），比播放页那枚（9 粗）小一号 —— 就是两个字号，
    /// 而且这一枚旁边站着一个 **9pt 的格式标记**，用 8 才比它小（见 `AppFont.songRowQualityBadge`）。
    private let qualityBadge = QualityBadge(font: AppFont.songRowQualityBadge)

    /// 「不在本机」那一枚 —— 跟格式标记**同一个零件**（细描边的小圆角标签）。
    ///
    /// 🔴 它**顶掉**音质那两枚，不并列（理由见 `showTags`）。刻意用灰、不用告警色：
    /// 整机恢复时是**每一行**都带它，一屏红标比灰标难受得多 —— 该喊话的是顶上那条横幅，
    /// 这一枚只负责**说出状态**。
    private let missingTag = FormatTag()

    /// 行尾那一格 —— **两种状态共用这一颗按钮**：常态画「更多」（点它弹菜单），
    /// 选择模式画勾选标记（**不吃点击**，点整行才算）。看 `showAccessory`。
    ///
    /// ⚠️ 用 `.custom`：`.system` 会按按钮自己的度量去摆这张图，
    /// 把我们给的 `pointSize` 放大；`.custom` 不做处理，图按原尺寸画。按下变暗照旧。
    private let moreButton = UIButton(type: .custom)

    /// 「耳机 + 次数」—— 显示开关开着才露；藏着时文字右缘回到常态间距。
    private let playCountView = PlayCountView()

    /// 歌名一行、副标题一行，竖着摞 —— 两行之间的间距由它管。
    private let textStack = UIStackView()

    /// 副标题那一行：**「艺人 - 专辑」＋ 格式标记 ＋ 音质徽章**横着排。
    private let subtitleRow = UIStackView()

    /// 文字相对封面的 leading —— 正在播时从 10 推到 32，给竖杠腾位。
    private var textLeading: Constraint?

    /// 文字相对「更多」的 trailing —— 有播放次数时再退一点给角标腾位。
    private var textTrailing: Constraint?
    private var moreButtonWidth: Constraint?

    // MARK: - 建立

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupAppearance()
        setupHierarchy()
        setupConstraints()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        playingBars.setPlaying(false)
        playingBars.isHidden = true
        playCountView.isHidden = true
        titleLabel.textColor = AppColor.title
        textLeading?.update(offset: Metrics.infoLeading)
        textTrailing?.update(offset: -Metrics.trailDefault)
    }

    // MARK: - 注入

    /// 取图的动作 —— 页面从装配层拿到再递给这一行。
    ///
    /// ⚠️ 这一行**不认识封面存在哪**：那是 `Data` 层的事，这儿只认
    /// 「给个名字 + 尺寸 + 倍数，出一张图」这个形状（见 `Core/UI/ArtworkProvider.swift`）。
    var artworkProvider: ArtworkProvider?

    // MARK: - 配置

    /// 把一行内容摆到这一行上。
    ///
    /// - `accessory`：行尾画「更多」菜单还是勾选标记。
    /// - `isCurrent`：是不是现在装的那一首。
    /// - `isPlaying`：是不是真的在出声（竖杠动画；暂停时当前行仍高亮 + 静竖杠）。
    /// - `isSelecting`：曲库多选时关掉「正在播」高亮 —— 勾选跟播放指示别抢同一行。
    func show(
        _ row: SongRow,
        accessory: SongRowAccessory,
        isCurrent: Bool = false,
        isPlaying: Bool = false,
        isSelecting: Bool = false
    ) {
        // 🔴 「这一行算不算高亮」**只算一次** —— 歌名颜色、竖杠、文字退后三样都从它出来。
        //
        // 收成一处的理由：这三样原来各自判一遍、还各自判一次 `isSelecting` ——
        // 只要有一处漏判，就会出现「蓝字配灰杠」这种自相矛盾的一行。
        //
        // ⚠️ **文件不在本机 ⇒ 不高亮**：它播不了，再给它上「正在播」的蓝字是撒谎。
        let highlighted = isCurrent && !isSelecting && !row.isMissing

        titleLabel.text = row.title
        subtitleLabel.text = row.subtitle
        titleLabel.textColor = Self.titleColor(highlighted: highlighted, isMissing: row.isMissing)
        showTags(row.quality, isMissing: row.isMissing)
        showPlayCount(row.playCount)
        showArtwork(row.artworkPath, isMissing: row.isMissing)
        showAccessory(accessory)
        showPlaybackChrome(highlighted: highlighted, isPlaying: isPlaying)
    }

    /// 歌名该是什么颜色 —— 🔴 **全类唯一一处决定它**。
    ///
    /// 优先级从高到低：**文件不在本机（灰）> 正在播（蓝）> 常态**。
    ///
    /// ⚠️ 为什么非要收成一处：原来这个颜色**有两个写者**（「正在播」那一套写一遍、
    /// 缺失那一套再写一遍）—— **谁后调谁说了算**。踩过：缺失那套无条件把颜色写回常态，
    /// 把正在播那一行的蓝字抹了。收成一处之后，「谁后调」这件事根本不存在。
    private static func titleColor(highlighted: Bool, isMissing: Bool) -> UIColor {
        if isMissing { return AppColor.subtitle }
        return highlighted ? AppColor.accent : AppColor.title
    }

    /// 「正在播」那一套：**竖杠 + 文字退后**。
    ///
    /// 🔴 **颜色不归它管**（见 `titleColor`）—— 一个属性只有一个写者。
    private func showPlaybackChrome(highlighted: Bool, isPlaying: Bool) {
        playingBars.isHidden = !highlighted
        playingBars.setPlaying(highlighted && isPlaying)
        textLeading?.update(offset: highlighted ? Metrics.currentTrackInfoLeading : Metrics.infoLeading)
    }

    /// 副标题右边那一小排：**音质那两枚**（格式标记 ＋ 档位徽章）**或者**「不在本机」那一枚。
    ///
    /// 🔴 **两者互斥，不并列** —— 一行只该有一个重点，而「这首播不了」比「它是 44.1kHz」
    /// 重要得多；三枚小标并排在小屏上也会挤成一团。
    /// 音质本身没丢：编辑歌曲信息页照常显示它。
    ///
    /// ⚠️ 没有音质（开关关着 / 这首歌读不到格式名）⇒ **两样一起藏**：它们俩是**一件事的
    /// 两半**（`AudioQualityTag` 捆着），只藏一个会留半截出来。
    ///
    /// ⚠️ 藏用 `isHidden` 就够，**不用自己去挪约束** —— 它们都在 `subtitleRow` 里，
    /// `UIStackView` 会把藏起来的那一格**连同它左右的间距**一起收掉。
    private func showTags(_ tag: AudioQualityTag?, isMissing: Bool) {
        missingTag.isHidden = !isMissing
        if isMissing { missingTag.show(Self.missingTagText) }
        formatTag.isHidden = isMissing || tag == nil
        qualityBadge.isHidden = isMissing || tag == nil
        guard !isMissing, let tag else { return }
        // ⚠️ **不给格式名拼尾随空格**（`formatLabel.text = formatName + " "` 那种）——
        // 那是拿一个**空格字符**当右边距：右边空多少全看那个空格在那个字号下有多宽，
        // 左边还一点不留。那圈留白现在由 `FormatTag` 自己的内边距给
        //（左右对称的 3，见 `FormatTag.Metrics.textInsets`）。
        formatTag.show(tag.format)
        qualityBadge.show(tag.level)
    }

    /// 「不在本机」那四个字 —— **只此一处**。
    private static let missingTagText = "不在本机"

    /// 缺失行封面的透明度 —— 压下去但还看得见。
    private static let missingArtworkAlpha: CGFloat = 0.35

    /// 「耳机 + 次数」：有值就画，没有就藏，并把文字右缘挪回常态。
    private func showPlayCount(_ count: Int?) {
        guard let count else {
            playCountView.isHidden = true
            textTrailing?.update(offset: -Metrics.trailDefault)
            return
        }
        playCountView.isHidden = false
        playCountView.setCount(count)
        textTrailing?.update(offset: -Metrics.trailWithPlayCount)
    }

    /// 行尾那一格 —— 一颗「更多」键，或者一枚勾选标记。
    ///
    /// 🔴 **两种状态共用同一颗按钮、同一个位置、同一个宽度**
    /// （`SongNormalCell` 切进选择模式时换的就是 `moreBtn` 的图，不是另摆一个视图）。
    /// 各摆一个视图的话，切换模式时文字那一列会跟着跳一下。
    ///
    /// ⚠️ 选择模式下这一枚**主动关掉点击**：点它不该有任何反应，点**整行**才算是勾 / 取消勾
    /// （`moreBtn.isUserInteractionEnabled = !isSelectStyle`）。
    /// 不关的话，用户点右边缘那一下会被这颗按钮吃掉，而它已经不带菜单了 —— 就是"点了没反应"。
    private func showAccessory(_ accessory: SongRowAccessory) {
        switch accessory {
        case .menu(let action):
            moreButtonWidth?.update(offset: Metrics.moreButtonWidth)
            moreButton.menu = makeMenu(action)
            moreButton.showsMenuAsPrimaryAction = true
            moreButton.isUserInteractionEnabled = true
            moreButton.tintColor = AppColor.subtitle
            showAccessoryIcon("ellipsis", weight: .medium)

        case .selection(let isSelected):
            moreButtonWidth?.update(offset: Metrics.moreButtonWidth)
            // ⚠️ 菜单要**摘干净** —— 只关 `showsMenuAsPrimaryAction` 而留着 `menu`，
            // 长按那一趟还是会弹出来。
            moreButton.menu = nil
            moreButton.showsMenuAsPrimaryAction = false
            moreButton.isUserInteractionEnabled = false
            // 两种状态都用强调色、17pt、semibold；只切换图形，不使用 selected 状态图。
            moreButton.tintColor = AppColor.accent
            showAccessoryIcon(
                isSelected ? "checkmark" : "plus.circle",
                weight: .semibold,
                pointSize: Metrics.selectionIconPointSize
            )

        case .none:
            // 手动排序：拖柄占右边，行尾「更多」收成 0 宽，别跟它抢位。
            moreButtonWidth?.update(offset: 0)
            moreButton.menu = nil
            moreButton.showsMenuAsPrimaryAction = false
            moreButton.isUserInteractionEnabled = false
            moreButton.setImage(nil, for: .normal)
        }
    }

    /// 换行尾那颗图 —— **尺寸连同图一起给按钮**（`.custom` 按钮不做二次处理，给多大画多大）。
    ///
    /// - Parameter pointSize: 这颗图多大。不给就是「更多」那一档（见 `Metrics.moreIconPointSize`）——
    ///   选择模式那两枚有自己的一档，得单独传（见 `Metrics.selectionIconPointSize`）。
    private func showAccessoryIcon(
        _ name: String,
        weight: UIImage.SymbolWeight,
        pointSize: CGFloat = Metrics.moreIconPointSize
    ) {
        // 只在 normal 状态替换这一颗按钮的当前图片；不维护 selected / highlighted 状态图。
        moreButton.setImage(
            UIImage(
                systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: pointSize,
                    weight: weight
                )
            ),
            for: .normal
        )
    }

    // MARK: - 私有 · 建立

    private func setupAppearance() {
        backgroundColor = AppColor.pageBackground
        contentView.backgroundColor = .clear

        // 选中时那一行垫在底下的颜色 —— 铺在**内容层下面**，所以上面那层必须透明才看得见。
        // ⚠️ 只管**编辑模式**（非编辑模式下表格那边关掉了选中，见 `layoutTableView()`）。
        let selectedBackground = UIView()
        selectedBackground.backgroundColor = AppColor.selection
        selectedBackgroundView = selectedBackground

        separatorInset = UIEdgeInsets(
            top: 0,
            left: Metrics.separatorInset,
            bottom: 0,
            right: 0
        )

        artworkView.backgroundColor = AppColor.surface
        artworkView.layer.cornerRadius = Metrics.artworkCornerRadius
        artworkView.clipsToBounds = true
        artworkView.contentMode = .scaleAspectFill

        playingBars.isHidden = true

        titleLabel.font = AppFont.songTitle
        titleLabel.textColor = AppColor.title
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = AppFont.songSubtitle
        subtitleLabel.textColor = AppColor.subtitle
        subtitleLabel.lineBreakMode = .byTruncatingTail

        // 🔴 副标题那一行是**横排三件**：艺人（可以截断）＋ 格式标记 ＋ 音质徽章。
        //
        // ⚠️ 为什么不"把标记和徽章挂在艺人文字的右边"（`formatLabel.leading = artistLabel.trailing + 4`、
        // 徽章再接在标记后面）：那样它们落在哪儿由**艺人名字有多长**决定 —— 名字一长就顶到行尾那个
        // 「更多」键上去了（那种写法没给右边留任何约束）。
        // 横排里让**艺人**去截断、标记和徽章保持原样，才是「贴在艺人行右侧」该有的样子。
        subtitleRow.axis = .horizontal
        subtitleRow.alignment = .center
        subtitleRow.spacing = Metrics.artistToFormatGap
        // ⚠️ 标记和徽章之间那条缝（3）跟前面那条（4）**不是一个数**，所以只能单独设 ——
        // 那一条在 `setupHierarchy()` 里、把 `formatTag` 加进这一行**之后**设。
        // 🔴 **顺序不能反**：`setCustomSpacing(_:after:)` 只对**已经在 `arrangedSubviews` 里**的
        // 视图生效，早一步设等于什么都没设（间距静默地保持 `spacing` 那个 4）。

        // ⚠️ 竖排是 `.leading`：每一行只占自己内容那么宽 —— 副标题那一行于是
        // "艺人 ＋ 标记 ＋ 徽章"挤成一串靠左，**格式标记紧跟在艺人文字后面**。
        //
        // 🔴 别改成 `.fill`：那样副标题那一行会被拉满整条宽度，
        // 横排里"吃掉剩余空间"的是**艺人文字**（它的抗拉伸优先级最低）⇒ 标记和徽章被一路
        // 顶到行尾，**位置就不对了**。
        //
        // 🔴 但 `.leading` 有一件事得自己补：UIStackView 在 `.leading` 下**不给**每一行任何
        // 宽度上限，内容比这一列还宽就**直接溢出去**。这正是把标记挂在
        // 艺人文字右边（`formatLabel.leading = artistLabel.trailing + 4`）且**右边一条约束都没有**的坑：
        // 艺人名一长，标记和徽章就压到行尾那个「更多」键上去了。**这个毛病不学**。
        // ⇒ 每一行都钉一条"不许超过这一列"（见 `setupConstraints`），超了让
        // **这一行自己的文字**去截断（`titleLabel` / `subtitleLabel` 都是 `.byTruncatingTail`）。
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = Metrics.textSpacing

        // 默认画「更多」—— 真摆什么由 `showAccessory` 定，这一句只是让它在配过内容之前
        // 也是颗像样的按钮，而不是一张空白（行被复用、还没轮到 `show` 的那一帧）。
        // 尺寸连同图一起给（`.custom` 按钮不做二次处理，给多大画多大）。
        showAccessoryIcon("ellipsis", weight: .medium)
        moreButton.tintColor = AppColor.subtitle
        moreButton.showsMenuAsPrimaryAction = true
    }

    private func setupHierarchy() {
        contentView.addSubview(artworkView)
        contentView.addSubview(playingBars)
        contentView.addSubview(textStack)
        contentView.addSubview(playCountView)
        contentView.addSubview(moreButton)

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleRow)
        subtitleRow.addArrangedSubview(subtitleLabel)
        subtitleRow.addArrangedSubview(formatTag)
        subtitleRow.addArrangedSubview(qualityBadge)
        subtitleRow.addArrangedSubview(missingTag)

        // 🔴 **必须在 `formatTag` 进了这一行之后设** —— 早一步设等于没设（见 `setupAppearance`）。
        subtitleRow.setCustomSpacing(Metrics.formatToBadgeGap, after: formatTag)

        // ⚠️ 默认全都藏：**没配过内容之前不该露出半截空的**。
        // 真的配了内容由 `show(...)` 决定（见 `showTags`）。
        formatTag.isHidden = true
        qualityBadge.isHidden = true
        missingTag.isHidden = true
        playCountView.isHidden = true
    }

    private func setupConstraints() {
        artworkView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(AppMetrics.s15)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(Self.artworkSide)
        }

        playingBars.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalTo(artworkView.snp.trailing).offset(Metrics.infoLeading)
            make.width.height.equalTo(Metrics.playingBarsSide)
        }

        moreButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-AppMetrics.s15)
            make.top.bottom.equalToSuperview()
            moreButtonWidth = make.width.equalTo(Metrics.moreButtonWidth).constraint
        }

        playCountView.snp.makeConstraints { make in
            make.trailing.equalTo(moreButton.snp.leading).offset(-Metrics.trailDefault)
            make.top.bottom.equalToSuperview()
        }

        textStack.snp.makeConstraints { make in
            textLeading = make.leading.equalTo(artworkView.snp.trailing).offset(Metrics.infoLeading).constraint
            textTrailing = make.trailing.equalTo(moreButton.snp.leading).offset(-Metrics.trailDefault).constraint
            make.centerY.equalToSuperview()
            // 上下留出最小边距 —— 系统文字放大到撑满时，行高跟着长（见下面的高度下限）。
            make.top.greaterThanOrEqualToSuperview().offset(AppMetrics.s8)
            make.bottom.lessThanOrEqualToSuperview().offset(-AppMetrics.s8)
        }

        // 🔴 竖排里每一行都**不许越过这一列的右边界** —— `.leading` 对齐不会自动给这一条，
        // 不给的话长文本直接画到行尾那个「更多」键上（见 `setupAppearance` 那段说明）。
        // 被压到上限时截断的是**这一行自己的文字**（它们的抗压缩优先级最低），
        // 格式标记和音质徽章是 `.required`，永远保持完整。
        titleLabel.snp.makeConstraints { make in
            make.width.lessThanOrEqualToSuperview()
        }
        subtitleRow.snp.makeConstraints { make in
            make.width.lessThanOrEqualToSuperview()
        }

        // 行高的**下限**（不是固定值）：字没放大时就是它，放大了让内容自己撑开。
        contentView.heightAnchor
            .constraint(greaterThanOrEqualToConstant: Self.minimumHeight)
            .isActive = true
    }

    // MARK: - 私有 · 内容

    /// 封面：有图用图，没图用音符占位。
    ///
    /// ⚠️ 这里**同步读图**（取图那头有内存缓存，命中时很快）。
    /// 不命中那一下是读盘 + **缩略图解码**（只解这一格要的那点像素，不是整张）——
    /// 页面那边还开了**预取**，滚动时基本都命中缓存。
    ///
    /// ⚠️ 尺寸和倍数要跟行里画的格子**完全对上**，否则预取的那份用不上、等于白读一次。
    ///
    /// 🔴 **`artworkView.alpha` 只在这一处写**（封面这一格的样貌全归这个函数管）：
    /// 文件不在本机就压透明 —— 但**不是换成"没有封面"**，图还在（封面文件是另一份，
    /// `ArtworkStore` 管），只是这首歌现在播不了，把它画成"没封面"是另一件事。
    /// ⚠️ 两路都要写：cell 会复用，上一行要是缺失行，不还原就一直是半透明的。
    private func showArtwork(_ artworkPath: String?, isMissing: Bool) {
        artworkView.alpha = isMissing ? Self.missingArtworkAlpha : 1
        if let image = artworkProvider?(
            artworkPath,
            CGSize(width: Self.artworkSide, height: Self.artworkSide),
            // 这一行自己的倍数 —— 不用 `UITraitCollection.current`（分屏时可能拿错）。
            traitCollection.displayScale
        ) {
            artworkView.image = image
            artworkView.contentMode = .scaleAspectFill
            artworkView.tintColor = nil
        } else {
            artworkView.image = UIImage(systemName: "music.note")
            artworkView.contentMode = .center
            artworkView.tintColor = AppColor.subtitle
        }
    }

    /// 行尾菜单。
    ///
    /// ⚠️ 一组动作也走 `UIMenu`：图标和破坏色的**长相**归行，"这一项叫什么、点了干什么"归页面。
    private func makeMenu(_ actions: SongRowActions) -> UIMenu {
        let edit = UIAction(
            title: "编辑歌曲信息",
            image: UIImage(systemName: "pencil")
        ) { _ in actions.onEdit() }

        let playNext = UIAction(
            title: "下一首播放",
            image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
        ) { _ in actions.onPlayNext() }

        let addToPlaylist = UIAction(
            title: "添加到播放列表",
            image: UIImage(systemName: "text.badge.plus")
        ) { _ in actions.onAddToPlaylist() }

        let share = UIAction(
            title: "共享",
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            guard let self else { return }
            // 传整行，popover 指向行中间
            actions.onShare(self)
        }

        var top: [UIMenuElement] = [edit, playNext, addToPlaylist]
        if let favorite = actions.favorite {
            top.append(
                UIAction(
                    title: favorite.isFavorite ? "取消喜爱" : "喜爱",
                    image: UIImage(systemName: favorite.isFavorite ? "heart.slash.fill" : "heart")
                ) { _ in favorite.toggle() }
            )
        }
        top.append(share)

        let main = UIAction(
            title: actions.mainAction.title,
            image: UIImage(systemName: actions.mainAction.systemImage),
            attributes: actions.mainAction.isDestructive ? .destructive : []
        ) { _ in actions.mainAction.handler() }

        return UIMenu(children: [
            UIMenu(options: .displayInline, children: top),
            UIMenu(options: .displayInline, children: [main])
        ])
    }
}

// MARK: - 格式标记

/// 列表行里那一小枚**格式名**（`FLAC` / `ALAC` / `MP3`）—— 细描边的小圆角标签。
///
/// 🔴 **它只画**：名字是外面给的，「这首歌是什么格式」不归它管
/// （那是 `Track.audioQualityFormatName`）。
///
/// ⚠️ 它跟 `QualityBadge` 是**一对**：同一行里挨着站 —— **左右内边距和圆角刻意取成一样**
///（都是 3 / 2），两枚并排时左右留白和弧度对得上。**它俩只有"画什么"不一样**
///（一个描边、一个渐变底），以及上下那点差（渐变底要呼吸、描边不用）。
///
/// ⚠️ 只有列表行用它 ⇒ 就躺在这一页的文件里（`private`，外面根本看不见它），
/// 不往 `Components/` 提 —— 那一层是放"多个页面都用"的零件的。
private final class FormatTag: UIView {

    /// 这一枚自己的尺寸。
    ///
    /// ⚠️ 跟徽章一样先放这儿、**不往 `AppMetrics` 放**：只有这一个地方用。
    private enum Metrics {

        /// 圆角 **2** —— 跟徽章同一个数。
        static let cornerRadius: CGFloat = 2

        /// 描边 **0.5** —— `formatBorderWidth`。
        static let borderWidth: CGFloat = 0.5

        /// 字外面那圈内边距 —— **上下 0 · 左右 3**。
        ///
        /// 🔴 **左右那 3 是我们补的**：这一枚本来**没有任何内边距**，
        /// 右边那点空靠**在格式名后面多拼一个空格字符**撑出来
        ///（`formatLabel.text = formatName + " "`）—— 那是拿字当布局用：
        /// 右边空多少取决于**空格在那个字号下有多宽**，左边还一点不留（描边贴着第一个字母）。
        /// 这是那个毛病，不学。
        /// ⇒ 改成**左右对称的 3**，跟旁边那枚徽章（`1, 3, 1, 3`）同一组数 ——
        /// 两枚并排时才像一对。
        ///
        /// ⚠️ 上下仍是 **0**：这一枚是描边、里面就一行字，高度就该是那行字那么高。
        /// 徽章上下那 1 是**渐变底**自己要的呼吸，别抄过来。
        static let textInsets = UIEdgeInsets(top: 0, left: 3, bottom: 0, right: 3)
    }

    private let textLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    /// 描边色**每次布局都重设一遍**。
    ///
    /// 🔴 这一处**不能用「两层视图拼一条边」那套**（外层画卷边色、内层留一点空隙填底色）：
    /// 那套要求中间填一块**不透明**的底色，而这一枚贴在行里 —— 行被选中时高亮色要**透过来**，
    /// 中间必须是透明的 ⇒ 只能用 `layer.borderColor`。
    ///
    /// ⚠️ 而 `layer.borderColor` 是 `CGColor`，赋值那一刻就把当前深浅取死了
    ///（那样写切深浅时这圈边会冻住）—— 在这里**每次重设**就不冻：
    /// 取色走 `resolvedColor(with: traitCollection)`，用的就是这个视图当下的外观；
    /// 而外观一变（`AppAppearance` 改窗口的 `overrideUserInterfaceStyle`）UIKit 会重走一遍布局。
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.borderColor = AppColor.subtitle.resolvedColor(with: traitCollection).cgColor
    }

    /// 跟徽章一样**自己知道自己多大** —— 里面那行字，加上左右那圈内边距。
    ///
    /// 🔴 必须有它 —— 容器（`UIStackView`）是按**内容尺寸**给子视图分地方的，
    /// 一个没有内容尺寸的裸 `UIView` 放进去，宽度就没有主张，那一行会跟着错位。
    override var intrinsicContentSize: CGSize {
        let text = textLabel.intrinsicContentSize
        return CGSize(
            width: text.width + Metrics.textInsets.left + Metrics.textInsets.right,
            height: text.height + Metrics.textInsets.top + Metrics.textInsets.bottom
        )
    }

    // MARK: - 对外

    /// 换成要显示的字（`FLAC` / `ALAC` 这种）。
    ///
    /// ⚠️ **外面只管给名字**：右边那点空由这一枚自己的内边距给 ——
    /// 别再往名字后面拼空格（见 `Metrics.textInsets` 和 `SongTableCell.showTags`）。
    func show(_ text: String) {
        textLabel.text = text
        // 字换了 ⇒ 「自己多大」要重算（`FLAC` 和 `MP3` 不一样宽）。
        invalidateIntrinsicContentSize()
    }

    // MARK: - 装配

    private func buildSubviews() {
        layer.cornerRadius = Metrics.cornerRadius
        layer.borderWidth = Metrics.borderWidth
        // 描边是骑在边界上画的（一半在外侧）—— 裁一下四角才圆得干净。
        clipsToBounds = true

        textLabel.font = AppFont.formatTag
        textLabel.textColor = AppColor.subtitle
        textLabel.textAlignment = .center
        addSubview(textLabel)

        // 跟徽章同一条：**这一枚多大就多大**，横排里该伸缩的是旁边那行艺人文字。
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        // 这一枚多大**由字撑出来**：字 ＋ 左右那圈内边距（`intrinsicContentSize` 也是这么算的）。
        // 🔴 内边距**左右对称** —— 不做"右边拼个空格、左边贴着描边"那一套。
        textLabel.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(Metrics.textInsets)
        }
    }
}

// MARK: - 播放次数

/// 列表行右侧「耳机 + 次数」—— 只画，开不开由外面的 `SongRow.playCount` 决定。
private final class PlayCountView: UIView {

    private enum Metrics {
        static let gap: CGFloat = 3
    }

    private let headphoneView = UIImageView()
    private let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 字号跟数字同档（`AppFont.songRowPlayCount` = 11）；图标 pointSize 跟字号对齐。
        let pointSize = AppFont.songRowPlayCount.pointSize
        let symbol = UIImage.SymbolConfiguration(pointSize: pointSize)
        headphoneView.image = UIImage(systemName: "headphones", withConfiguration: symbol)
        headphoneView.tintColor = AppColor.subtitle
        headphoneView.contentMode = .scaleAspectFit

        countLabel.font = AppFont.songRowPlayCount
        countLabel.textColor = AppColor.subtitle

        addSubview(headphoneView)
        addSubview(countLabel)
        headphoneView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalToSuperview()
        }
        countLabel.snp.makeConstraints { make in
            make.leading.equalTo(headphoneView.snp.trailing).offset(Metrics.gap)
            make.centerY.equalToSuperview()
            make.trailing.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    func setCount(_ count: Int) {
        countLabel.text = "\(count)"
    }
}

import SnapKit
import UIKit

/// 歌单列表的一行：封面 + 名字 + 「N 首歌」+ 行尾更多菜单。
///
/// 🔴 它**只画**：拿到的是排好版的一行内容（`PlaylistRow`），不查数据、不做判断 ——
/// 曲目数、封面画哪一档都在 `PlaylistsViewModel` 里定好了。
final class PlaylistTableCell: UITableViewCell {

    static let reuseIdentifier = "PlaylistTableCell"

    /// 行高的**下限** —— 字没放大时就是它，放大了让内容自己撑开。
    ///
    /// ⚠️ 放在 `Metrics` 外面是有意的：列表要拿它当**估算行高**（`estimatedRowHeight`），
    /// 那是页面的事，得看得见。
    static let minimumHeight: CGFloat = 76

    /// 这一行内部用到的尺寸。
    ///
    /// ⚠️ 跟曲库页那一行同一条规矩：**只有这一个地方用的，就不往 `AppMetrics` 放** ——
    /// 令牌表是给"多个地方共用"的值用的，塞满了单点数字就没人看得懂它到底在管什么。
    private enum Metrics {

        /// 封面那一格：**54 × 54**。
        static let artworkSide: CGFloat = 54

        /// 封面圆角 **6**。
        static let artworkCornerRadius: CGFloat = 6

        /// 封面距左边 **15**（跟曲库页那一行同一个数）。
        static let artworkLeading: CGFloat = AppMetrics.s15

        /// 封面到文字 **12**。
        static let artworkToTextGap: CGFloat = AppMetrics.s12

        /// 文字到行尾「更多」键 —— **4**。
        ///
        /// ⚠️ 比上面那条缝（12）小得多，**不是笔误**：文字这一列要尽量占满，
        /// 而「更多」键自己还有 44 宽的点按区兜着（它两边本来就有富余）。
        static let textToMoreGap: CGFloat = 4

        /// 行尾「更多」键的点击区 —— **44 × 44**。
        static let moreButtonSide: CGFloat = 44

        /// 「更多」键距右缘 **12**。
        static let moreButtonTrailing: CGFloat = AppMetrics.s12

        /// 添加模式的加号 / 勾图标点大小 —— **17 semibold**。
        static let selectionIconPointSize: CGFloat = 17

        /// 「更多」图标点大小 —— **20 中等**。
        static let moreIconPointSize: CGFloat = 20

        /// 名字和副标题之间那条缝 **6**。
        static let textSpacing: CGFloat = 6

        /// 分隔线的左缩进 —— 对齐到**文字的左边缘**。
        ///
        /// ⚠️ 必须显式设：`UITableViewCell` 的默认缩进是 16，不是"对齐文字"。
        ///
        /// 🔴 **算出来的，不写死**：位置 = 左内边距 + 封面 + 封面到文字那条缝。
        /// 写死一个数的话，改封面大小那天，分隔线就跟文字错开了 —— 而且错开一点点最难看。
        /// ⚠️ 参考实现里这一处是写死的 82，而它那三个数加起来是 81 —— **差 1 点是它自己没对齐**，
        /// 不是我们抄错。这里跟着那三个数走，天然对得上。
        static var separatorInset: CGFloat {
            artworkLeading + artworkSide + artworkToTextGap
        }
    }

    // MARK: - 零件

    private let coverView = PlaylistCoverView()

    // MARK: - 注入

    /// 取图的动作 —— 页面从装配层拿到再递给这一行（这一行不认识封面存在哪）。
    var artworkProvider: ArtworkProvider? {
        didSet { coverView.artworkProvider = artworkProvider }
    }
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    /// 行尾「更多」—— 用 `.custom`：`.system` 会按按钮自己的度量去摆这张图，
    /// 把我们给的 `pointSize` 放大；`.custom` 不做处理，图按原尺寸画。
    private let moreButton = UIButton(type: .custom)

    /// 名字一行、副标题一行，竖着摞 —— 两行之间的间距由它管。
    private let textStack = UIStackView()

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

    // MARK: - 配置

    /// 把一行内容摆到这一行上。
    ///
    /// - Parameters:
    ///   - onChangeCover: 点「修改封面图片」。
    ///   - onGenerateCover: 点「生成封面」。
    ///   - onRename: 点「重新命名」。
    ///   - onAddToPlaylist: 点「添加到播放列表」（把本歌单里的歌批量加进别的歌单）。
    ///   - onDelete: 点「删除播放列表」。
    ///
    /// ⚠️ 动作都**只往上转**：确认、挑图、真写库都在页面那边（`+Actions`），
    /// 行的职责只是"告诉外面用户点了哪一项"。
    func show(
        _ row: PlaylistRow,
        onChangeCover: @escaping () -> Void,
        onGenerateCover: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onAddToPlaylist: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        showContent(row)
        backgroundColor = AppColor.pageBackground
        contentView.backgroundColor = .clear
        moreButton.menu = makeMenu(
            row,
            onChangeCover: onChangeCover,
            onGenerateCover: onGenerateCover,
            onRename: onRename,
            onAddToPlaylist: onAddToPlaylist,
            onDelete: onDelete
        )
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.isUserInteractionEnabled = true
        moreButton.tintColor = AppColor.subtitle
        // 编辑态（手动排序）里「更多」要藏起来 —— 那会儿整行只干一件事：被拖。
        moreButton.isHidden = isEditing
    }

    /// 歌曲页多选「添加到播放列表」时的行尾状态。
    ///
    /// 复用同一行，只把「更多」换成不可点击的加号 / 勾；点整行由页面负责加入歌曲。
    func show(_ row: PlaylistRow, addingTracks: Bool) {
        showContent(row)
        // 添加模式跟挑歌页一样，行本身透明，让列表的 systemGroupedBackground 透出来。
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        moreButton.menu = nil
        moreButton.showsMenuAsPrimaryAction = false
        moreButton.isUserInteractionEnabled = false
        moreButton.isHidden = false
        moreButton.tintColor = AppColor.accent
        let symbol = addingTracks ? "checkmark" : "plus.circle"
        let configuration = UIImage.SymbolConfiguration(
            pointSize: Metrics.selectionIconPointSize,
            weight: .semibold
        )
        moreButton.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
    }

    private func showContent(_ row: PlaylistRow) {
        titleLabel.text = row.title
        subtitleLabel.text = row.subtitle
        coverView.show(row.cover)
    }

    /// 进 / 出编辑态时，行尾那个「更多」跟着藏 / 现。
    ///
    /// ⚠️ 编辑态里没有"更多菜单"这回事：那一行此刻的用途是**被拖**，
    /// 菜单里那几项（改名 / 删除）在拖拽过程中点不到、也不该点到。
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        moreButton.isHidden = editing
    }

    // MARK: - 私有 · 建立

    private func setupAppearance() {
        backgroundColor = AppColor.pageBackground
        contentView.backgroundColor = .clear

        // 选中时那一行垫在底下的颜色 —— 铺在**内容层下面**，所以上面那层必须透明才看得见。
        let selectedBackground = UIView()
        selectedBackground.backgroundColor = AppColor.selection
        selectedBackgroundView = selectedBackground

        separatorInset = UIEdgeInsets(
            top: 0,
            left: Metrics.separatorInset,
            bottom: 0,
            right: 0
        )

        // 🔴 编辑态那两件（**编辑样式**、**内容缩不缩进**）**不在这儿** ——
        // 它们都是 `UITableViewDelegate` 的方法（`editingStyleForRowAt` /
        // `shouldIndentWhileEditingRowAt`），见 `PlaylistsViewController+List`。
        // `editingStyle` 更是个**只读**属性，想设在行身上也编译不过。
        // 行身上只剩一件编辑态的事：把行尾「更多」藏起来（`setEditing` 里）。

        coverView.layer.cornerRadius = Metrics.artworkCornerRadius

        titleLabel.font = AppFont.playlistTitle
        titleLabel.textColor = AppColor.title
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = AppFont.playlistSubtitle
        subtitleLabel.textColor = AppColor.subtitle
        subtitleLabel.lineBreakMode = .byTruncatingTail

        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = Metrics.textSpacing

        let moreSymbol = UIImage.SymbolConfiguration(
            pointSize: Metrics.moreIconPointSize,
            weight: .medium
        )
        moreButton.setImage(
            UIImage(systemName: "ellipsis", withConfiguration: moreSymbol),
            for: .normal
        )
        moreButton.tintColor = AppColor.subtitle
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.accessibilityLabel = "更多"
    }

    private func setupHierarchy() {
        contentView.addSubview(coverView)
        contentView.addSubview(textStack)
        contentView.addSubview(moreButton)

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
    }

    private func setupConstraints() {
        coverView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(Metrics.artworkLeading)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(Metrics.artworkSide)
        }

        moreButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-Metrics.moreButtonTrailing)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(Metrics.moreButtonSide)
        }

        textStack.snp.makeConstraints { make in
            make.leading.equalTo(coverView.snp.trailing).offset(Metrics.artworkToTextGap)
            make.trailing.equalTo(moreButton.snp.leading).offset(-Metrics.textToMoreGap)
            make.centerY.equalToSuperview()
            // 上下留出最小边距 —— 系统文字放大到撑满时，行高跟着长（见下面的高度下限）。
            make.top.greaterThanOrEqualToSuperview().offset(AppMetrics.s8)
            make.bottom.lessThanOrEqualToSuperview().offset(-AppMetrics.s8)
        }

        // 🔴 竖排里每一行都**不许越过这一列的右边界** —— `.leading` 对齐不会自动给这一条，
        // 不给的话长歌单名直接画到行尾那个「更多」键上（曲库页踩过这个坑，见 `SongTableCell`）。
        // 被压到上限时截断的是这一行自己的文字。
        titleLabel.snp.makeConstraints { make in
            make.width.lessThanOrEqualToSuperview()
        }
        subtitleLabel.snp.makeConstraints { make in
            make.width.lessThanOrEqualToSuperview()
        }

        // 行高的**下限**（不是固定值）：字没放大时就是它，放大了让内容自己撑开。
        contentView.heightAnchor
            .constraint(greaterThanOrEqualToConstant: Self.minimumHeight)
            .isActive = true
    }

    // MARK: - 私有 · 内容

    /// 行尾菜单 —— 五项（`PlaylistTableCell.swift:85-88`），**没有**「全部播放」
    ///（播一个歌单走「点行进详情 → 播放」）。
    ///
    /// ⚠️ 分成两组（各套一层 `.displayInline`）：**删除单独一组**，
    /// 跟上面那几项之间由系统画一条分割线 —— 它是唯一不可逆的一项。
    ///
    /// 🔴 「最爱的歌曲」只有「删除」置灰（不是藏）—— 它是收藏入口，删了没地方看。
    /// 改名可以。
    private func makeMenu(
        _ row: PlaylistRow,
        onChangeCover: @escaping () -> Void,
        onGenerateCover: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onAddToPlaylist: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> UIMenu {
        let ordinary = UIMenu(options: .displayInline, children: [
            UIAction(title: "修改封面图片", image: UIImage(systemName: "photo")) { _ in onChangeCover() },
            UIAction(title: "生成封面", image: UIImage(systemName: "square.grid.2x2")) { _ in onGenerateCover() },
            UIAction(title: "重新命名", image: UIImage(systemName: "pencil")) { _ in onRename() },
            UIAction(title: "添加到播放列表", image: UIImage(systemName: "text.badge.plus")) { _ in
                onAddToPlaylist()
            },
        ])

        let delete = UIAction(
            title: "删除播放列表",
            image: UIImage(systemName: "trash"),
            attributes: row.isFavorites ? [.destructive, .disabled] : [.destructive]
        ) { _ in onDelete() }

        return UIMenu(children: [ordinary, UIMenu(options: .displayInline, children: [delete])])
    }
}

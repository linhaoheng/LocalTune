import SnapKit
import UIKit

/// 均衡器。效果：黑皮、横滑卡、前级、十条竖条。没有开关，没有「关闭」卡。
///
/// 🔴 这一页按效果重写、不照常见做法：页不存 gains，进页不改成哈曼，顶栏按字撑开，底走令牌不是 `.black`。
final class EqualizerViewController: BaseViewController, UICollectionViewDataSource, UICollectionViewDelegate {

    private let viewModel: EqualizerViewModel
    private let saveButton = PressableButton()
    private let resetButton = PressableButton()
    private let titleLabel = UILabel()
    private let preampRow = EQPreampRow()
    private let bandsStack = UIStackView()
    private var bandViews: [EQBandColumn] = []
    private var cards: [EQPresetCard] = []

    private lazy var presetList: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = AppMetrics.equalizerCardSize
        layout.minimumLineSpacing = AppMetrics.equalizerCardSpacing
        layout.sectionInset = UIEdgeInsets(
            top: AppMetrics.equalizerCardInset,
            left: AppMetrics.equalizerCardInset,
            bottom: AppMetrics.equalizerCardInset,
            right: AppMetrics.equalizerCardInset
        )
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.dataSource = self
        view.delegate = self
        view.register(EQPresetCell.self, forCellWithReuseIdentifier: EQPresetCell.reuseID)
        return view
    }()

    init(viewModel: EqualizerViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        prefersLargeTitles = false
        largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) {
        // 本页只由代码构造 —— 从 nib / storyboard 解档是写错了：调试期当场停下，正式版返回 nil。
        assertionFailure("EqualizerViewController 只由代码构造，不该走 init(coder:)")
        return nil
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 🔴 **这一页不碰导航栏、也不改自己的外观档位** —— 那两样归这条栈的「表面档位」：
        // `AppRouter.presentEqualizer` 给的是 `.nowPlaying`（黑皮 ＋ 强制深色 ＋ 藏栏）。
        // ⚠️ 别在这儿加回来 —— 页面里再设一遍就是同一件事两个写者。
        // 页面**自己的**底色留在这儿：那是这一页在画自己，不是导航栈的事。
        view.backgroundColor = AppColor.nowPlayingBackground
        buildHeader()
        buildBody()
        bind()
    }

    private func buildHeader() {
        styleAction(saveButton, title: "保存自定义", action: #selector(saveTapped))
        styleAction(resetButton, title: "重置", action: #selector(resetTapped))
        titleLabel.text = "均衡器设置"
        titleLabel.font = AppFont.equalizerTitle
        titleLabel.textColor = AppColor.nowPlayingSolid
        titleLabel.textAlignment = .center
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        view.addSubview(saveButton)
        view.addSubview(titleLabel)
        view.addSubview(resetButton)
        saveButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(AppMetrics.equalizerHeaderInset)
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.height.equalTo(AppMetrics.equalizerHeaderHeight)
        }
        resetButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-AppMetrics.equalizerHeaderInset)
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.height.equalTo(AppMetrics.equalizerHeaderHeight)
        }
        titleLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.height.equalTo(AppMetrics.equalizerHeaderHeight)
            make.leading.greaterThanOrEqualTo(saveButton.snp.trailing)
                .offset(AppMetrics.equalizerHeaderGap)
            make.trailing.lessThanOrEqualTo(resetButton.snp.leading)
                .offset(-AppMetrics.equalizerHeaderGap)
        }
    }

    private func styleAction(_ button: PressableButton, title: String, action: Selector) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.pressScale = 0.9
        // 字色 / 字号钉死；灰只压整键 alpha（0.5）。不用 pinColors：
        // 禁用时撤掉 transformer 会让系统改字属性，键会变大。
        let text = AppColor.overlayTextSecondary
        button.configurationUpdateHandler = { btn in
            guard var updated = btn.configuration else { return }
            updated.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.foregroundColor = text
                outgoing.font = AppFont.equalizerHeaderAction
                return outgoing
            }
            btn.configuration = updated
            btn.alpha = btn.isEnabled ? 1 : AppMetrics.equalizerHeaderActionDisabledAlpha
        }
        button.setNeedsUpdateConfiguration()
        button.addTarget(self, action: action, for: .touchUpInside)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// 从上到下：卡 → 前级 → 十条。前级不进竖条那一排。
    private func buildBody() {
        preampRow.onChange = { [weak self] value in
            self?.viewModel.setPreamp(value)
        }

        bandsStack.axis = .horizontal
        bandsStack.distribution = .fillEqually
        bandsStack.alignment = .fill
        bandsStack.backgroundColor = AppColor.nowPlayingBackground
        for index in 0..<EQSpec.bandCount {
            let column = EQBandColumn(title: EQSpec.labels[index])
            column.onChange = { [weak self] value in
                self?.viewModel.setBand(index: index, gain: value)
            }
            bandViews.append(column)
            bandsStack.addArrangedSubview(column)
        }

        view.addSubview(presetList)
        view.addSubview(preampRow)
        view.addSubview(bandsStack)
        presetList.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(AppMetrics.equalizerPresetTop)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(AppMetrics.equalizerPresetHeight)
        }
        preampRow.snp.makeConstraints { make in
            make.top.equalTo(presetList.snp.bottom).offset(AppMetrics.equalizerPreampTop)
            make.leading.equalToSuperview().offset(AppMetrics.equalizerPreampInset)
            make.trailing.equalToSuperview().offset(-AppMetrics.equalizerPreampInset)
            make.height.equalTo(AppMetrics.equalizerPreampHeight)
        }
        bandsStack.snp.makeConstraints { make in
            make.top.equalTo(preampRow.snp.bottom).offset(AppMetrics.equalizerBandsTop)
            make.leading.equalToSuperview().offset(AppMetrics.equalizerBandsInset)
            make.trailing.equalToSuperview().offset(-AppMetrics.equalizerBandsInset)
            make.height.equalTo(AppMetrics.equalizerBandsHeight)
        }
    }

    private func bind() {
        viewModel.content
            .subscribe(onNext: { [weak self] content in
                self?.show(content)
            })
            .disposed(by: disposeBag)
    }

    private func show(_ content: EqualizerViewModel.Content) {
        let idsChanged = cards.map(Self.cardID) != content.cards.map(Self.cardID)
        cards = content.cards
        if idsChanged {
            presetList.reloadData()
        } else {
            for cell in presetList.visibleCells {
                guard let cell = cell as? EQPresetCell,
                      let item = presetList.indexPath(for: cell)?.item,
                      item < cards.count
                else { continue }
                paint(cell, cards[item], selection: content.selection)
            }
        }
        for (index, column) in bandViews.enumerated() where index < content.gains.bands.count {
            column.setGain(content.gains.bands[index])
        }
        preampRow.setGain(content.gains.preamp)
        saveButton.isEnabled = content.canSave
    }

    private func paint(_ cell: EQPresetCell, _ card: EQPresetCard, selection: EQSelection) {
        cell.show(
            title: EqualizerViewModel.title(of: card),
            selected: EqualizerViewModel.isSelected(card, selection: selection),
            showsIcon: EqualizerViewModel.showsUserIcon(card)
        )
    }

    private static func cardID(_ card: EQPresetCard) -> String {
        switch card {
        case .custom: "custom"
        case .user(let item): item.id
        case .builtIn(let preset): preset.rawValue
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        cards.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let dequeued = collectionView.dequeueReusableCell(
            withReuseIdentifier: EQPresetCell.reuseID,
            for: indexPath
        )
        guard let cell = dequeued as? EQPresetCell else {
            assertionFailure("这一格必须是注册过的 EQPresetCell")
            return dequeued
        }
        paint(cell, cards[indexPath.item], selection: viewModel.contentNow.selection)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        viewModel.select(cards[indexPath.item])
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let id = EqualizerViewModel.userPresetID(of: cards[indexPath.item]) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let delete = UIAction(
                title: "删除",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                self?.viewModel.deleteUserPreset(id: id)
            }
            return UIMenu(children: [delete])
        }
    }

    @objc private func saveTapped() {
        guard viewModel.contentNow.canSave else { return }
        // ⚠️ 均衡器页是常暗页面 —— 弹的框也套深色，别让系统白框刺眼。
        AppAlert.prompt(
            from: self,
            title: "保存自定义",
            message: "输入均衡器配置名称",
            clearButtonMode: .never,
            returnKeyType: .done,
            autocorrectionType: .no,
            confirmTitle: "保存",
            onConfirm: { [weak self] name in
                let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.viewModel.save(name: name)
            },
            interfaceStyle: .dark
        )
    }

    @objc private func resetTapped() {
        viewModel.reset()
    }
}

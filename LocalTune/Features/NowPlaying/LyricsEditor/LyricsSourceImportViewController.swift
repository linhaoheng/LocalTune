import SnapKit
import UIKit

/// 「导入歌词源」页 —— 从「歌词源」页的「导入歌词源」**弹出来**（模态整页）。
///
/// ## 形态：一张分组表单（照 primuse 的「导入刮削源」）
///
/// ```
/// 粘贴配置    ← 一个大输入框（等宽 14 · 导入 200 / 编辑撑满整页，框里自己滚）
/// 错误        ← 只在出错时在：红字多行（此时框退回 200 / 300，表可以滚）
/// （仅预览）   ← 一行：仅为预览，尚未导入。点「确认导入」才会添加；取消则丢弃。
/// 导入前预览   ← 源 / 配置 / 能力 / 请求 / 网络域名（标签）/ 四个勾 / 橘黄警告
/// ```
///
/// 🔴 **框高固定**：导入页 200、编辑页 300（两档都在 `AppMetrics` 里），框自己滚。
/// 编辑页曾经是"撑满整页"（按表格可视区现算），撑满时外层表没有滚动余量、只剩框一个
/// 滚动容器；现在统一退回固定高度，表照常滚、框内自己滚。
///
/// 🔴 **预览一成功，输入段整段消失**：输入框和摘要同屏会让人误以为"预览 = 已导入"，
/// 也容易被键盘顶掉一半。右上那颗键**在同一个位置换字**：「预览」→「确认导入」。
///
/// 🔴 **改一个字，上一份预览就作废**：回输入态、清错误、按钮变回「预览」。
/// 不许出现"看着旧的预览、导进新的文本"。
///
/// ## 它不认识的东西
///
/// - **不认存储**：`LyricsSourceFileStore` 只管读写；导入完把配置交出去（`onImported`），
///   "选中并退回取词页"是外面的事。
/// - **不拼摘要、不拼校验文案**：摘要由 `LyricsSourceImportSummary` 算，
///   校验由 `LyricsSourceConfigIssue` 一条一句给 —— 页面只负责摆。
/// - **不做「从文件导入」**：配置文件不是我们导出的，从别的 App 的文件里挑多一步、还多一份
///   文件权限 —— 只要粘贴 JSON 与 HTTPS 地址两条（见设计文档 §F.2.4）。
///
/// ## 编辑模式（`editingID` 非空）
///
/// 同一张表单，两处不同：
///
/// - 输入框预填**主文件原文**（`LyricsSourceFileStore.rawText`）—— 不是把配置 encode 回去，
///   那样会把合回内存的 secrets 写进主文件，也会重排用户自己的排版；
/// - **id 锁死**：id 是文件名，也是取词页记住的选择；改了就是"另存为新源"，旧文件会成孤儿
///   （`save` 只写不删）。所以预览时一发现 id 变了就报错，不静默新建。
///
/// 保存走的是同一个 `save`（按 id 覆盖），所以数据层不需要为编辑单开一条路。
final class LyricsSourceImportViewController: BaseViewController {

    // MARK: - 依赖

    private let store: LyricsSourceFileStore
    /// 非空 ⇒ 编辑模式，值是**被编辑的那个 id**。
    private let editingID: String?
    private let onImported: (LyricsSourceConfig) -> Void

    // MARK: - 状态

    /// 预览通过的那一份；`nil` ＝ 还没预览（或刚改过文本）。
    private var preview: LyricsSourceConfig?
    /// 预览里要摆的那一份摘要；跟着 `preview` 一起算好，画的时候不再算。
    private var summary: LyricsSourceImportSummary?
    /// 配置是从哪个地址下回来的（粘贴的给 `nil`）—— 预览里「源」那一行要用。
    private var previewSourceHost: String?
    /// 出错那一句（可能多行）；`nil` ＝ 没错。
    private var errorMessage: String?
    private var isLoadingRemote = false

    // MARK: - 零件

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// 输入那一格 —— **自建、不复用**：整张表只有这一行输入，复用反而要处理
    /// "textView 被搬来搬去"和"正在打的字被摘掉"两件事。
    ///
    /// 高度就由这里的 `minHeight` 定：导入 200、编辑 300。
    private lazy var editorCell: LyricsSourceImportEditorCell = {
        let cell = LyricsSourceImportEditorCell(
            style: .default,
            reuseIdentifier: nil,
            minHeight: editingID == nil
                ? AppMetrics.lyricsSourceImportEditorHeight
                : AppMetrics.lyricsSourceImportEditorHeightEditing
        )
        cell.textView.delegate = self
        return cell
    }()

    private static let reviewReuseID = "lyricsSourceReview"
    private static let bannerReuseID = "lyricsSourceBanner"
    private static let errorReuseID = "lyricsSourceImportError"

    private static let remoteLimitBytes = 64 * 1024

    /// 表里现在有哪几段 —— 哪段在，由状态决定。
    private enum Section: Equatable {
        case input
        case error
        /// 「仅为预览」那独立一段（在预览摘要**上面**）。
        case banner
        /// 摘要本身。
        case review
    }

    // MARK: - 建立

    init(
        store: LyricsSourceFileStore,
        editingID: String? = nil,
        onImported: @escaping (LyricsSourceConfig) -> Void
    ) {
        self.store = store
        self.editingID = editingID
        self.onImported = onImported
        super.init(nibName: nil, bundle: nil)
        title = editingID == nil ? "导入歌词源" : "编辑歌词源"
        largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpTable()
        setUpNavigation()
        prefillIfEditing()
    }

    /// 编辑模式：把主文件原文塞进输入框。
    ///
    /// ⚠️ 程序化赋值**不会**走 `textViewDidChange`，占位符要自己收起来。
    private func prefillIfEditing() {
        guard let editingID, let text = store.rawText(id: editingID) else { return }
        editorCell.textView.text = text
        editorCell.placeholderLabel.isHidden = true
        // 整份赋值是"批量写入"，`contentSize` 要等一次布局才更新；不等它更新，
        // 框里就没有滚动范围 —— 一进页面拖不动（见 `refreshScrollRange`）。
        refreshScrollRange(editorCell.textView)
    }

    /// 逼一次布局，让刚批量写进去的字**算出** `contentSize`。
    ///
    /// 🔴 **"框滑不动"的真正原因**：`UITextView` 的滚动范围取自 `contentSize`，而 `.text =`
    /// （粘贴、程序化赋值）这种批量写入**不会**顺手更新它 —— 只有逐字符的编辑（打字、删字）
    /// 才会连带刷新。所以粘贴完框里其实还没有滚动范围，拖不动；删掉一行就又好了。
    ///
    /// 之前撑满整页时看不出来，是因为 `refreshEditorRowHeight` 每次都 `beginUpdates/endUpdates`
    /// 顺手逼了一次布局；改成固定高度后那一段删了，这个副作用也跟着没了。
    private func refreshScrollRange(_ textView: UITextView) {
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        // 有些系统版本要等这一轮 runloop 收尾才把 `contentSize` 算稳（粘贴上千字符时见过），
        // 再补一次；代价只是一次布局，不涉及重绘。
        DispatchQueue.main.async { [weak textView] in
            textView?.layoutIfNeeded()
        }
    }

    // MARK: - 布局

    private func setUpTable() {
        // 分组表单的底：跟 `.grouped` 档的导航栏同一个系统色（见 `AppColor.groupedPageBackground`）。
        view.backgroundColor = AppColor.groupedPageBackground
        tableView.backgroundColor = AppColor.groupedPageBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = AppMetrics.lyricsSourceImportEstimatedRowHeight
        // 一拖列表就把键盘收掉 —— 粘完配置该看预览了。
        tableView.keyboardDismissMode = .interactive
        tableView.contentInset = UIEdgeInsets(
            top: 0,
            left: 0,
            bottom: AppMetrics.lyricsSourceImportBottomInset,
            right: 0
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.bannerReuseID)
        tableView.register(LyricsSourceImportReviewCell.self, forCellReuseIdentifier: Self.reviewReuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.errorReuseID)

        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            // 键盘一出来就缩到键盘上面 —— 输入区跟着让位，不用自己算 inset。
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }
    }

    private func setUpNavigation() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )
        updateNavigationItem()
    }

    /// 右上那颗键：没预览 ⇒「预览」；预览过 ⇒「确认导入」；下载中 ⇒ 一颗圈。
    ///
    /// ⚠️ **同一位置换字**，不并排加第二颗键 —— 用户不用先找"我现在该按哪一颗"。
    private func updateNavigationItem() {
        guard !isLoadingRemote else {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
            return
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            // 编辑模式叫「保存」——「确认导入」在编辑语境里是错的，它本来就在库里。
            title: preview == nil ? "预览" : (editingID == nil ? "确认导入" : "保存"),
            style: .done,
            target: self,
            action: #selector(nextTapped)
        )
    }

    // MARK: - 段

    /// 现在表里有哪几段 —— **唯一的判据**，行数与段头段脚都从这里取。
    private var sections: [Section] {
        if summary != nil { return [.banner, .review] }
        if errorMessage != nil { return [.input, .error] }
        return [.input]
    }

    /// 状态一变就整表重来。
    ///
    /// ⚠️ 用 `reloadData()` 而不是差量：段的数量和身份都在变（输入段整个消失），
    /// 差量算出来的结果和"重来"一样，却多一份容易写错的对账。
    private func reloadSections() {
        tableView.reloadData()
        updateNavigationItem()
    }

    // MARK: - 动作

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    /// 预览 → 确认导入，同一颗键走两步（照 primuse）。
    @objc private func nextTapped() {
        if let preview {
            importPreview(preview)
        } else {
            startPreview()
        }
    }

    private func startPreview() {
        let text = editorCell.textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoadingRemote else { return }

        if text.hasPrefix("{") {
            // 粘贴进来的：预览里「源」那一行写「粘贴的 JSON」。
            previewSourceHost = nil
            preview(json: Data(text.utf8))
            return
        }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https" else {
            showError("只支持 JSON 文本或 HTTPS 地址")
            return
        }
        loadRemote(url)
    }

    private func loadRemote(_ url: URL) {
        isLoadingRemote = true
        updateNavigationItem()
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingRemote = false
                self.updateNavigationItem()
                guard let data, error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    self.showError("配置下载失败")
                    return
                }
                guard data.count <= Self.remoteLimitBytes else {
                    self.showError("配置太大（上限 64 KB）")
                    return
                }
                self.previewSourceHost = url.host
                self.preview(json: data)
            }
        }.resume()
    }

    private func preview(json data: Data) {
        let config: LyricsSourceConfig
        do {
            config = try JSONDecoder().decode(LyricsSourceConfig.self, from: data)
        } catch {
            showError(lyricsSourceDecodeMessage(for: error))
            return
        }
        // 🔴 编辑时 id 锁死：id 是文件名，也是取词页记住的选择。
        //    改了 id ⇒ `save` 会写成另一个文件、旧的成孤儿（它只写不删）。
        if let editingID, config.id != editingID {
            showError("编辑时不能改 id（原来是「\(editingID)」）。id 同时是文件名，改了会多出一个源。要另存为新源，请回歌词源页重新导入。")
            return
        }
        let issues = config.issues
        guard issues.isEmpty else {
            showError(issues.map(lyricsSourceIssueMessage).joined(separator: "\n"))
            return
        }

        // 预览成了：输入段整段收起，只剩"仅为预览"＋"导入前预览"。
        editorCell.textView.resignFirstResponder()
        preview = config
        summary = LyricsSourceImportSummary(config: config, sourceHost: previewSourceHost)
        errorMessage = nil
        reloadSections()
    }

    private func importPreview(_ config: LyricsSourceConfig) {
        do {
            try store.save(config)
        } catch {
            showError("保存配置失败")
            return
        }
        let onImported = self.onImported
        dismiss(animated: true) { onImported(config) }
    }

    private func showError(_ message: String) {
        preview = nil
        summary = nil
        previewSourceHost = nil
        errorMessage = message
        reloadSections()
    }
}

// MARK: - 输入

extension LyricsSourceImportViewController: UITextViewDelegate {

    func textViewDidChange(_ textView: UITextView) {
        editorCell.placeholderLabel.isHidden = textView.hasText
        // 粘贴走的就是这里，但它和打字不一样：一次批量写入，滚动范围得自己催（见 `refreshScrollRange`）。
        refreshScrollRange(textView)
        // 🔴 文本一改，上一份预览就作废 —— 回输入态，按钮也变回「预览」。
        guard preview != nil || errorMessage != nil else { return }
        preview = nil
        summary = nil
        previewSourceHost = nil
        errorMessage = nil
        reloadSections()
    }
}

// MARK: - 表格

extension LyricsSourceImportViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // 每一段都只有一行 —— 摘要那一行自己是一整个竖排（不拆成多行 cell）。
        return 1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .input: return "粘贴配置"
        case .error: return nil
        case .banner: return nil
        case .review: return "导入前预览"
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .input:
            return "粘贴歌词源 JSON 或 HTTPS 配置地址，系统会自动识别。"
        case .error:
            return nil
        case .banner:
            return nil
        case .review:
            return "导入后，该歌词源在取词时会连接上述域名；带脚本的源会在本机执行它的 JavaScript。"
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .input:
            return editorCell

        case .error:
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.errorReuseID, for: indexPath)
            var content = UIListContentConfiguration.cell()
            content.text = errorMessage
            content.textProperties.font = AppFont.songSubtitle
            content.textProperties.color = AppColor.destructive
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            cell.backgroundColor = .secondarySystemGroupedBackground
            return cell

        case .banner:
            return bannerCell(tableView, at: indexPath)

        case .review:
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.reviewReuseID, for: indexPath)
            if let cell = cell as? LyricsSourceImportReviewCell, let summary {
                cell.show(summary)
            }
            return cell
        }
    }

    /// 「仅为预览，尚未导入」那一行 —— **自己一段**，在摘要上面（照 primuse）。
    private func bannerCell(_ tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.bannerReuseID, for: indexPath)
        var content = UIListContentConfiguration.cell()
        content.text = editingID == nil
            ? "仅为预览，尚未导入。点「确认导入」才会添加；取消则丢弃。"
            : "仅为预览，尚未保存。点「保存」才会覆盖原来的配置；取消则丢弃改动。"
        content.image = UIImage(systemName: "eye.circle")
        content.textProperties.font = AppFont.songSubtitle
        content.textProperties.color = AppColor.secondaryText
        content.textProperties.numberOfLines = 0
        content.imageProperties.tintColor = AppColor.subtitle
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.backgroundColor = .secondarySystemGroupedBackground
        return cell
    }
}

// MARK: - 文案（本页专用）

private func lyricsSourceDecodeMessage(for error: Error) -> String {
    // 规则里写了不认识的键 —— 这条比"字段读不出来"具体，先接住。
    if let rule = error as? LyricsRuleError { return rule.message }
    guard let error = error as? DecodingError else {
        return "配置读不出来：\(error.localizedDescription)"
    }
    switch error {
    case let .keyNotFound(key, context):
        return "缺少字段 \(lyricsSourceFieldPath(context.codingPath + [key]))"
    case let .valueNotFound(_, context):
        return "字段没有值：\(lyricsSourceFieldPath(context.codingPath))"
    case let .typeMismatch(_, context):
        return "字段类型不对：\(lyricsSourceFieldPath(context.codingPath))"
    case let .dataCorrupted(context):
        if let rule = context.underlyingError as? LyricsRuleError { return rule.message }
        let path = lyricsSourceFieldPath(context.codingPath)
        return path == "(根)" ? "JSON 语法不对" : "字段读不出来：\(path)"
    @unknown default:
        return "配置读不出来"
    }
}

private func lyricsSourceFieldPath(_ path: [CodingKey]) -> String {
    let text = path.map(\.stringValue).joined(separator: ".")
    return text.isEmpty ? "(根)" : text
}

private func lyricsSourceIssueMessage(_ issue: LyricsSourceConfigIssue) -> String {
    switch issue {
    case .invalidID: return "id 只能是 1–64 位字母/数字/._-"
    case .emptyName: return "name 不能为空"
    case .emptyCapabilities: return "capabilities 不能为空"
    case .missingSearch: return "缺少 search"
    case .missingLyrics: return "缺少 lyrics"
    case .tlsBypassNotSupported: return "不支持 sslTrustDomains（本 App 不绕过 TLS 校验）"
    case let .urlNotHTTPS(endpoint): return "\(endpoint).url 必须是 https"
    case let .unsupportedMethod(endpoint): return "\(endpoint).method 只支持 GET/POST"
    case let .missingScript(endpoint): return "\(endpoint).script 不能为空"
    case let .scriptTooLong(endpoint): return "\(endpoint).script 太长"
    case .emptyRuleKeyword: return "rules 里的词条不能为空（空串会删掉所有行）"
    case .ruleKeywordTooShort: return "rules 里 scope 为 line 的词条至少 \(LyricsSourceConfig.minLineRuleKeywordLength) 个字（整行比，单字会把歌词正文删光）"
    case .ruleKeywordHasColon: return "rules 里的词条不要带冒号（判据只看冒号前那截，带冒号反而一条都删不掉）"
    case .ruleKeywordTooLong: return "rules 里的词条最长 \(LyricsSourceConfig.maxRuleKeywordLength) 个字"
    case .tooManyRuleKeywords: return "rules 里的词条最多 \(LyricsSourceConfig.maxRuleKeywordCount) 条"
    case .ruleMinHitsOutOfRange: return "rules 里的 minHits 要落在 1 到这条规则的词条数之间（比词条数还大就永远命中不了）"
    }
}

// MARK: - 输入那一格

/// 粘贴配置的那一格：一个等宽多行输入框 ＋ 一行占位。
///
/// ⚠️ **不复用**（整张表只有这一行），所以 `textView` 不会被搬来搬去，
/// 正在打的字也不会因为滚出屏幕被摘掉。
private final class LyricsSourceImportEditorCell: UITableViewCell {

    let textView = UITextView()
    let placeholderLabel = UILabel()

    /// 框的**最小**高度：导入 200、编辑 300。
    ///
    /// 编辑页 300、导入页 200 —— 高度就由这条约束定，页面不再另行计算。
    ///
    /// ⚠️ **不重写 `init(style:reuseIdentifier:)`**：本类自己定义了指定构造器，
    /// 父类那几个构造器就不再继承 —— 这个 cell 只由本页手工造，用不到它们。
    init(style: UITableViewCell.CellStyle, reuseIdentifier: String?, minHeight: CGFloat) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .secondarySystemGroupedBackground

        textView.font = AppFont.lyricsEditorSource
        textView.textColor = AppColor.title
        textView.backgroundColor = .clear
        // 🔴 **自己滚**：框高固定（导入 200 / 编辑 300），整份配置装不下 ⇒ 只有框一个滚动容器。
        textView.isScrollEnabled = true
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.tintColor = AppColor.accent
        // 左右不给自己留内边距 —— 那 16 由 cell 的 `ContentInset` 给，文字才跟系统的行对齐。
        textView.textContainerInset = UIEdgeInsets(
            top: AppMetrics.lyricsSourceImportEditorInset,
            left: 0,
            bottom: AppMetrics.lyricsSourceImportEditorInset,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        contentView.addSubview(textView)
        textView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(AppMetrics.lyricsSourceImportEditorInset)
            make.leading.trailing.equalToSuperview().inset(AppMetrics.lyricsSourceImportContentInset)
            // 🔴 **等于，不是"大于等于"**：写成 `>=` 时，`UITextView` 会按内容高度把行撑高
            // ⇒ 框和内容一样高、没有可滚的余量，整页也就滑不动了（真机上就是"框卡死"）。
            // 钉成等号后行高恒为 `minHeight + 上下内边距`，多出来的字交给框自己滚。
            make.height.equalTo(minHeight)
        }

        placeholderLabel.text = "粘贴配置 JSON，或填一个 HTTPS 配置地址"
        placeholderLabel.font = AppFont.songSubtitle
        placeholderLabel.textColor = AppColor.subtitle
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false
        textView.addSubview(placeholderLabel)
        // 占位跟输入文字同一条基线（`textContainerInset.top`）＋ 同一条左沿。
        placeholderLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(AppMetrics.lyricsSourceImportEditorInset)
            make.leading.trailing.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }
}

// MARK: - 预览那一格

/// 预览摘要 —— 一整块竖排，**一项一项照 primuse 的 `ScraperImportSummaryView`**：
///
/// ```
/// 源            粘贴的 JSON / 主机名
/// 配置          名称 (id)
/// 能力          lyrics、lyricsWordLevel
/// 请求          2 个端点，GET, POST
/// 网络域名      [a.com] [b.com]      ← 等宽小标签，每行最多 3 个
/// [✓ 请求头] [✓ Cookie] [✓ 密钥] [✓ JavaScript]
/// ⚠ 未检测到固定的网络域名…          ← 橘黄
/// ```
///
/// ⚠️ **整块是一个 cell**（不是一行一个 cell）：这七块之间是 12 的间距，
/// 而 cell 与 cell 之间会被系统分隔线切开 —— 拆成多行就不是 pri 那个样子了。
private final class LyricsSourceImportReviewCell: UITableViewCell {

    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .secondarySystemGroupedBackground

        stack.axis = .vertical
        stack.spacing = AppMetrics.lyricsSourceImportSummaryRowSpacing
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(
            top: AppMetrics.lyricsSourceImportSummaryVerticalInset,
            left: AppMetrics.lyricsSourceImportContentInset,
            bottom: AppMetrics.lyricsSourceImportSummaryVerticalInset,
            right: AppMetrics.lyricsSourceImportContentInset
        )
        contentView.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    func show(_ summary: LyricsSourceImportSummary) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(row(title: "源", value: summary.sourceDescription))
        stack.addArrangedSubview(row(title: "配置", value: summary.configLine))
        stack.addArrangedSubview(row(title: "能力", value: summary.capabilitiesLine))
        stack.addArrangedSubview(row(title: "请求", value: summary.requestsLine))
        if !summary.domains.isEmpty {
            stack.addArrangedSubview(tagGroup(title: "网络域名", values: summary.domains))
        }
        stack.addArrangedSubview(badgeRow(summary))
        for warning in summary.warnings {
            stack.addArrangedSubview(warningLine(warning))
        }
    }

    // MARK: - 一行：小标题在上、值在下

    private func row(title: String, value: String) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = AppFont.songSubtitle
        titleLabel.textColor = AppColor.subtitle

        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = AppFont.editorFieldValue
        valueLabel.textColor = AppColor.title
        valueLabel.numberOfLines = 0

        let box = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        box.axis = .vertical
        box.spacing = AppMetrics.lyricsSourceImportSummaryTitleSpacing
        return box
    }

    // MARK: - 网络域名：等宽小标签，每行最多三个

    private func tagGroup(title: String, values: [String]) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = AppFont.songSubtitle
        titleLabel.textColor = AppColor.subtitle

        let lines = UIStackView()
        lines.axis = .vertical
        lines.spacing = AppMetrics.lyricsSourceImportTagSpacing
        for chunk in values.chunked(maxItems: AppMetrics.lyricsSourceImportTagsPerRow) {
            // 每行末尾也塞撑杆：一行不满三个时，标签不能被拉宽去填满。
            var views = chunk.map(tag)
            views.append(spacer())
            let line = UIStackView(arrangedSubviews: views)
            line.axis = .horizontal
            line.spacing = AppMetrics.lyricsSourceImportTagSpacing
            lines.addArrangedSubview(line)
        }

        let box = UIStackView(arrangedSubviews: [titleLabel, lines])
        box.axis = .vertical
        box.spacing = AppMetrics.lyricsSourceImportTagSpacing
        return box
    }

    /// 一个域名标签：等宽 11 ＋ 浅底 ＋ 圆角 6。
    ///
    /// ⚠️ 横向的 hugging / 抗压缩都设成 `required` —— 否则 `UIStackView` 会把
    /// 最后一个标签**拉宽**去填满整行，色块跟着变长，看着就不像标签了。
    private func tag(_ text: String) -> UIView {
        let label = LyricsSourceTagLabel()
        label.text = text
        label.font = AppFont.sourceDomainTag
        label.textColor = AppColor.title
        label.backgroundColor = AppColor.surface
        label.layer.cornerRadius = AppMetrics.lyricsSourceImportTagCornerRadius
        label.layer.masksToBounds = true
        label.textInsets = UIEdgeInsets(
            top: AppMetrics.lyricsSourceImportTagVerticalPadding,
            left: AppMetrics.lyricsSourceImportTagHorizontalPadding,
            bottom: AppMetrics.lyricsSourceImportTagVerticalPadding,
            right: AppMetrics.lyricsSourceImportTagHorizontalPadding
        )
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    // MARK: - 四个勾：请求头 / Cookie / 密钥 / JavaScript

    private func badgeRow(_ summary: LyricsSourceImportSummary) -> UIView {
        let items: [(String, Bool)] = [
            ("请求头", summary.includesHeaders),
            ("Cookie", summary.includesCookie),
            ("密钥", summary.includesSecrets),
            ("JavaScript", summary.includesJavaScript)
        ]
        var views = items.map { badge(title: $0.0, enabled: $0.1) }
        // 🔴 末尾塞一根**撑杆**：不塞的话横向 stack 会把四个徽章按比例拉宽去填满整行，
        // 看着就是"第一个和第二个隔了老远"。撑杆把剩下的地方全吃掉。
        views.append(spacer())
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.spacing = AppMetrics.lyricsSourceImportBadgeSpacing
        return row
    }

    /// 一根只负责占地方的撑杆（本身不可见、不画东西）。
    private func spacer() -> UIView {
        let view = UIView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    /// 一个勾：`checkmark.circle.fill`（有）/ `circle`（没有）；有是深色、没有是灰色。
    private func badge(title: String, enabled: Bool) -> UIView {
        let icon = UIImageView(
            image: UIImage(systemName: enabled ? "checkmark.circle.fill" : "circle")
        )
        icon.tintColor = enabled ? AppColor.title : AppColor.subtitle
        icon.contentMode = .scaleAspectFit
        icon.snp.makeConstraints { make in
            make.width.height.equalTo(AppMetrics.lyricsSourceImportBadgeIconSide)
        }

        let label = UILabel()
        label.text = title
        label.font = AppFont.songSubtitle
        label.textColor = enabled ? AppColor.title : AppColor.subtitle
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let box = UIStackView(arrangedSubviews: [icon, label])
        box.axis = .horizontal
        box.spacing = AppMetrics.lyricsSourceImportBadgeIconSpacing
        box.alignment = .center
        box.setContentHuggingPriority(.required, for: .horizontal)
        return box
    }

    // MARK: - 橘黄警告

    private func warningLine(_ text: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
        icon.tintColor = AppColor.warning
        icon.contentMode = .scaleAspectFit
        icon.snp.makeConstraints { make in
            make.width.height.equalTo(AppMetrics.lyricsSourceImportBadgeIconSide)
        }

        let label = UILabel()
        label.text = text
        label.font = AppFont.songSubtitle
        label.textColor = AppColor.warning
        label.numberOfLines = 0

        let box = UIStackView(arrangedSubviews: [icon, label])
        box.axis = .horizontal
        box.spacing = AppMetrics.lyricsSourceImportBadgeIconSpacing
        // 折成两行时，图标要贴第一行，不能垂直居中。
        box.alignment = .top
        return box
    }
}

/// 带内边距的标签 —— `UILabel` 自己不带 inset，色块会贴着字。
private final class LyricsSourceTagLabel: UILabel {

    var textInsets: UIEdgeInsets = .zero

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
    }
}

// MARK: - 切行

private extension Array {

    /// 每 `maxItems` 个切一行（照 primuse 的 `chunked(maxItems:)`）。
    func chunked(maxItems: Int) -> [[Element]] {
        guard maxItems > 0 else { return [self] }
        var result: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: maxItems, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<next]))
            index = next
        }
        return result
    }
}

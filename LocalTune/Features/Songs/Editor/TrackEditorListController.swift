import UIKit

/// 编辑页表格协作者：两段（文件信息 · 元数据标签），**没有「歌词文件」行**。
///
/// 页面私有协作者：十几个输入框和歌词框就是**表格的内容**，跟行走在这儿；
/// 快照里字段的回填、打字推 VM、失焦补推、回车跳下一格，全在这一层。
@MainActor
final class TrackEditorListController: NSObject {

    private enum TagKind: Int, CaseIterable {
        case title
        case album
        case albumArtist
        case artist
        case composer
        case genre
        case lyrics
        case releaseDate
        case discNumber
        case discTotal
        case trackNumber
        case trackTotal
        case comment

        var title: String {
            switch self {
            case .title: return "标题"
            case .album: return "专辑名"
            case .albumArtist: return "专辑艺人"
            case .artist: return "艺人"
            case .composer: return "作曲者"
            case .genre: return "类型"
            case .lyrics: return "歌词"
            case .releaseDate: return "发布日期"
            case .discNumber: return "光盘编号"
            case .discTotal: return "光盘总数"
            case .trackNumber: return "曲目编号"
            case .trackTotal: return "曲目总数"
            case .comment: return "注释"
            }
        }
    }

    // MARK: - 依赖

    private let viewModel: TrackEditorViewModel

    private unowned let tableView: UITableView

    // MARK: - 字段（表格的内容）

    private let titleField = UITextField()
    private let albumField = UITextField()
    private let albumArtistField = UITextField()
    private let artistField = UITextField()
    private let composerField = UITextField()
    private let genreField = UITextField()
    private let releaseDateField = UITextField()
    private let discNumberField = UITextField()
    private let discTotalField = UITextField()
    private let trackNumberField = UITextField()
    private let trackTotalField = UITextField()
    private let commentField = UITextField()
    private let lyricsView = TrackEditorGrowingTextView()

    /// 最新一份快照 —— 配行时用。
    private var latestSnapshot: TrackEditorViewModel.Snapshot?

    init(viewModel: TrackEditorViewModel, tableView: UITableView) {
        self.viewModel = viewModel
        self.tableView = tableView
        super.init()
        configureFieldKeyboards()
        wireFieldEditingChanged()
        // 表格的两个角色在构造时认领 —— 挂接和"这个对象存在"是同一件事，
        // 装配方没有"建了它、忘了挂"的机会。
        tableView.dataSource = self
        tableView.delegate = self
    }

    // MARK: - 快照落表

    /// 字段回填 + 文件信息段重载（导航栏按钮、封面的部分归页面自己）。
    func apply(_ snapshot: TrackEditorViewModel.Snapshot) {
        let fileRowsChanged = latestSnapshot?.fileRows != snapshot.fileRows
        latestSnapshot = snapshot

        // 正在编辑的框不要被快照盖掉光标位置；只在外部推来的值（封面保存后等）才回填。
        if titleField.isFirstResponder == false { titleField.text = snapshot.title }
        if albumField.isFirstResponder == false { albumField.text = snapshot.album }
        if albumArtistField.isFirstResponder == false { albumArtistField.text = snapshot.albumArtist }
        if artistField.isFirstResponder == false { artistField.text = snapshot.artist }
        if composerField.isFirstResponder == false { composerField.text = snapshot.composer }
        if genreField.isFirstResponder == false { genreField.text = snapshot.genre }
        if releaseDateField.isFirstResponder == false { releaseDateField.text = snapshot.releaseDate }
        if discNumberField.isFirstResponder == false { discNumberField.text = snapshot.discNumber }
        if discTotalField.isFirstResponder == false { discTotalField.text = snapshot.discTotal }
        if trackNumberField.isFirstResponder == false { trackNumberField.text = snapshot.trackNumber }
        if trackTotalField.isFirstResponder == false { trackTotalField.text = snapshot.trackTotal }
        if commentField.isFirstResponder == false { commentField.text = snapshot.comment }
        if lyricsView.isFirstResponder == false, lyricsView.text != snapshot.lyrics {
            lyricsView.text = snapshot.lyrics
        }

        if fileRowsChanged {
            tableView.reloadSections(IndexSet(integer: 0), with: .none)
        }
    }

    /// 把还在输入框里、还没结束编辑的字推给 VM —— 保存 / 取消 / 下拉关闭前都得先走这一步。
    func flushFieldsToViewModel() {
        viewModel.updateTitle(titleField.text ?? "")
        viewModel.updateAlbum(albumField.text ?? "")
        viewModel.updateAlbumArtist(albumArtistField.text ?? "")
        viewModel.updateArtist(artistField.text ?? "")
        viewModel.updateComposer(composerField.text ?? "")
        viewModel.updateGenre(genreField.text ?? "")
        viewModel.updateLyrics(lyricsView.text ?? "")
        viewModel.updateReleaseDate(releaseDateField.text ?? "")
        viewModel.updateDiscNumber(discNumberField.text ?? "")
        viewModel.updateDiscTotal(discTotalField.text ?? "")
        viewModel.updateTrackNumber(trackNumberField.text ?? "")
        viewModel.updateTrackTotal(trackTotalField.text ?? "")
        viewModel.updateComment(commentField.text ?? "")
    }

    // MARK: - 私有 · 字段装配

    private func configureFieldKeyboards() {
        discNumberField.keyboardType = .numberPad
        discTotalField.keyboardType = .numberPad
        trackNumberField.keyboardType = .numberPad
        trackTotalField.keyboardType = .numberPad
        releaseDateField.keyboardType = .numberPad
    }

    /// 打字过程中就推到 VM，这样「保存」键能跟着 `hasChanges` 亮/灰，不用等失焦。
    private func wireFieldEditingChanged() {
        let fields = [
            titleField, albumField, albumArtistField, artistField, composerField, genreField,
            releaseDateField, discNumberField, discTotalField, trackNumberField, trackTotalField,
            commentField,
        ]
        for field in fields {
            field.addTarget(self, action: #selector(fieldEditingChanged(_:)), for: .editingChanged)
        }
    }

    @objc private func fieldEditingChanged(_ textField: UITextField) {
        pushFieldValue(textField)
    }

    /// 把某个输入框的当前字交给 VM（失焦时也走同一处）。
    private func pushFieldValue(_ textField: UITextField) {
        let text = textField.text ?? ""
        switch textField {
        case titleField: viewModel.updateTitle(text)
        case albumField: viewModel.updateAlbum(text)
        case albumArtistField: viewModel.updateAlbumArtist(text)
        case artistField: viewModel.updateArtist(text)
        case composerField: viewModel.updateComposer(text)
        case genreField: viewModel.updateGenre(text)
        case releaseDateField: viewModel.updateReleaseDate(text)
        case discNumberField: viewModel.updateDiscNumber(text)
        case discTotalField: viewModel.updateDiscTotal(text)
        case trackNumberField: viewModel.updateTrackNumber(text)
        case trackTotalField: viewModel.updateTrackTotal(text)
        case commentField: viewModel.updateComment(text)
        default: break
        }
    }
}

// MARK: - 数据源 / 代理

extension TrackEditorListController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? (latestSnapshot?.fileRows.count ?? 0) : TagKind.allCases.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "文件信息" : "元数据标签"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: TrackEditorCell.Info.reuseID,
                for: indexPath
            ) as? TrackEditorCell.Info
            ?? TrackEditorCell.Info(style: .default, reuseIdentifier: TrackEditorCell.Info.reuseID)
            let row = latestSnapshot?.fileRows[indexPath.row]
            cell.show(title: row?.title ?? "", value: row?.value ?? "")
            return cell
        }

        let kind = TagKind.allCases[indexPath.row]
        switch kind {
        case .lyrics:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: TrackEditorCell.Lyrics.reuseID,
                for: indexPath
            ) as? TrackEditorCell.Lyrics
            ?? TrackEditorCell.Lyrics(style: .default, reuseIdentifier: TrackEditorCell.Lyrics.reuseID)
            lyricsView.delegate = self
            cell.show(title: kind.title, textView: lyricsView)
            return cell
        case .title:
            return fieldCell(indexPath, kind: kind, field: titleField)
        case .album:
            return fieldCell(indexPath, kind: kind, field: albumField)
        case .albumArtist:
            return fieldCell(indexPath, kind: kind, field: albumArtistField)
        case .artist:
            return fieldCell(indexPath, kind: kind, field: artistField)
        case .composer:
            return fieldCell(indexPath, kind: kind, field: composerField)
        case .genre:
            return fieldCell(indexPath, kind: kind, field: genreField)
        case .releaseDate:
            return fieldCell(indexPath, kind: kind, field: releaseDateField)
        case .discNumber:
            return fieldCell(indexPath, kind: kind, field: discNumberField)
        case .discTotal:
            return fieldCell(indexPath, kind: kind, field: discTotalField)
        case .trackNumber:
            return fieldCell(indexPath, kind: kind, field: trackNumberField)
        case .trackTotal:
            return fieldCell(indexPath, kind: kind, field: trackTotalField)
        case .comment:
            return fieldCell(indexPath, kind: kind, field: commentField)
        }
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        nil
    }

    // MARK: - 私有

    private func fieldCell(
        _ indexPath: IndexPath,
        kind: TagKind,
        field: UITextField
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: TrackEditorCell.Field.reuseID,
            for: indexPath
        ) as? TrackEditorCell.Field
        ?? TrackEditorCell.Field(style: .default, reuseIdentifier: TrackEditorCell.Field.reuseID)
        field.delegate = self
        cell.show(title: kind.title, field: field)
        return cell
    }
}

// MARK: - 输入

extension TrackEditorListController: UITextFieldDelegate, UITextViewDelegate {

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let order: [UIResponder] = [
            titleField, albumField, albumArtistField, artistField, composerField, genreField, lyricsView,
            releaseDateField, discNumberField, discTotalField, trackNumberField, trackTotalField, commentField,
        ]
        if let index = order.firstIndex(where: { $0 === textField }), index + 1 < order.count {
            order[index + 1].becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        pushFieldValue(textField)
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        if textField === releaseDateField {
            let current = textField.text ?? ""
            guard let nsRange = Range(range, in: current) else { return false }
            let next = current.replacingCharacters(in: nsRange, with: string)
            return next.count <= 4 || string.isEmpty
        }
        if [discNumberField, discTotalField, trackNumberField, trackTotalField].contains(textField) {
            if string.isEmpty { return true }
            return string.allSatisfy(\.isNumber)
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        viewModel.updateLyrics(textView.text ?? "")
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        viewModel.updateLyrics(textView.text ?? "")
    }
}

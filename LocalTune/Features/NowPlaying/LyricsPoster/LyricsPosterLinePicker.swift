import SwiftUI

/// 选哪几句上海报。从面板的「选择歌词」进来，整页模态。
///
/// 🔴 **"只能选连续的一段"这条规则不在这儿**（`LyricsPosterSelectionPolicy` 管）——
/// 这一页只负责表达：勾选态、够不着的行压暗、越界给一句人话。
///
/// ⚠️ 它**单独一个文件**（不是面板的私有子视图）：面板本身已经够长，两页也确实是两件事
/// —— 一页挑风格画幅，一页挑词。
struct LyricsPosterLinePicker: View {

    @ObservedObject var composer: LyricsPosterComposer

    @Environment(\.dismiss) private var dismiss

    init(composer: LyricsPosterComposer) {
        self.composer = composer
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(composer.lines) { line in
                        row(line)
                    }
                } footer: {
                    Text("一张海报最多 \(LyricsPosterSelectionPolicy.maximumLines) 句，而且只能是一段连着的词。")
                }
            }
            .navigationTitle("选择歌词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert(rejectionMessage, isPresented: rejectionBinding) {
                Button("好", role: .cancel) { composer.rejection = nil }
            }
        }
    }

    private func row(_ line: LyricsPosterLine) -> some View {
        let isSelected = composer.isSelected(line.id)
        return Button {
            composer.toggle(line.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isSelected ? Color(uiColor: AppColor.accent) : Color(uiColor: AppColor.secondaryText)
                    )

                Text(line.text)
                    .foregroundStyle(Color(uiColor: AppColor.title))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        // 够不着的行留在列表里、只是压暗：用户能看懂"只能往两头接"，比直接隐藏好。
        .opacity(isSelected || composer.canExtend(to: line.id) ? 1 : 0.4)
    }

    private var rejectionBinding: Binding<Bool> {
        Binding(
            get: { composer.rejection != nil },
            set: { if !$0 { composer.rejection = nil } }
        )
    }

    /// 越界的原因，说成人话。
    private var rejectionMessage: String {
        switch composer.rejection {
        case .limitReached:
            return "最多只能选 \(LyricsPosterSelectionPolicy.maximumLines) 句"
        case .notAdjacent:
            return "只能接着选相邻的句子"
        case nil:
            return ""
        }
    }
}

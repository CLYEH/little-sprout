import SwiftUI

/// 「編輯相簿名稱」sheet（LS-166 票文範圍 2：編輯名稱＋多寶貝標記）——「更多」下拉選單的
/// 「編輯相簿名稱」列觸發（`design/littlesprout.pen` Notes `kHDk4` `OHMPk`：選單只列「編輯
/// 相簿名稱」「刪除相簿」兩項，沒有另外的「編輯寶貝標記」入口）。同 `CreateAlbumView` 沒有
/// 專屬設計稿的既有理由——版面完全組合自既有已核可元件（`LabeledTextField`／`AttributionSheet`），
/// 把「名稱」與「多寶貝標記」合併成同一次編輯動作，鏡射「新增相簿」sheet 本來就把兩者綁在
/// 一起的既有慣例（`CreateAlbumView` 文件註解），不是本票另外發明的新流程形狀。
struct EditAlbumView: View {
    let detailStore: AlbumDetailStore
    let childrenStore: ChildrenStore

    @State private var title: String
    @State private var showsEmptyTitleMessage = false
    @State private var selectedChildIDs: Set<UUID>
    @State private var showsAttributionSheet = false
    @Environment(\.dismiss) private var dismiss

    init(detailStore: AlbumDetailStore, childrenStore: ChildrenStore) {
        self.detailStore = detailStore
        self.childrenStore = childrenStore
        _title = State(initialValue: detailStore.title)
        _selectedChildIDs = State(initialValue: Set(detailStore.childIDs))
    }

    private var isSubmitting: Bool { detailStore.editState.isSubmitting }

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                nameField
                    .padding(.top, AppSpacing.section)
                childField
                    .padding(.top, AppSpacing.item)
                if case .failure(let error) = detailStore.editState {
                    errorMessage(error)
                        .padding(.top, AppSpacing.item)
                }
                Spacer(minLength: AppSpacing.item)
                footer
                    .padding(.bottom, AppSpacing.item)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
        }
        .appBackground()
        .sheet(isPresented: $showsAttributionSheet) {
            AttributionSheet(
                childrenStore: childrenStore, selectedChildIDs: $selectedChildIDs,
                title: "這本相簿要標記哪個寶貝？", subtitle: "之後隨時可以再改，也可以不標記。"
            )
        }
        .onAppear { detailStore.resetEditState() }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("編輯相簿名稱")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("改個名字，或調整標記的寶貝。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var nameField: some View {
        LabeledTextField(
            label: "相簿名稱",
            placeholder: "上禮拜的動物園一日遊",
            text: Binding(
                get: { title },
                set: { newValue in
                    title = newValue
                    showsEmptyTitleMessage = false
                }
            ),
            helpText: nameHelpText,
            isError: isNameError,
            submitLabel: .done
        )
        .disabled(isSubmitting)
    }

    private var nameHelpText: String {
        if isSubmitting { return "送出期間先不能修改。" }
        if showsEmptyTitleMessage { return "還沒填相簿名稱。在上面打上名字，再按一次。" }
        return "家人在相簿列表會看到這個名字。"
    }

    private var isNameError: Bool {
        !isSubmitting && showsEmptyTitleMessage
    }

    private var childField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("這本相簿是哪個寶貝的？")
                .appFont(.body, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            childFieldBox
        }
    }

    private var childFieldBox: some View {
        Button {
            showsAttributionSheet = true
        } label: {
            HStack {
                Text(selectedChildrenSummaryText)
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(selectedChildIDs.isEmpty ? Color.lsTextSecondary : Color.lsTextPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").appIconFrame(.medium).foregroundStyle(Color.lsTextSecondary)
            }
            .padding(.horizontal, AppSpacing.insetCard)
            .frame(minHeight: AppSpacing.section)
            .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }

    private var selectedChildrenSummaryText: String {
        guard !selectedChildIDs.isEmpty else { return "不指定" }
        let names = childrenStore.activeChildren
            .filter { selectedChildIDs.contains($0.id) }
            .map(\.name)
        return names.isEmpty ? "不指定" : names.joined(separator: "、")
    }

    /// `set_album_children`（`LS045`／`42501`）與 `albums.title` 直接 `.update()`
    /// （merge-review R2 M1 起由 `SupabaseAlbumsAPIClient.updateAlbumTitle` 明確轉出的
    /// `AppError`，不再是靜默 0 列）落在這裡由 `error.userFacingMessage` 的既有映射處理——
    /// `AlbumDetailView` 把「更多」限定 owner 可見，owner 若不是建立者送出時會撞到這兩種
    /// 錯誤，見 `AlbumDetailStore.submitEdit` 文件註解「已知落差」。
    private func errorMessage(_ error: AppError) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.circle.fill").appIconFrame(.small).foregroundStyle(Color.lsDanger)
            Text(error.userFacingMessage).appFont(.note).foregroundStyle(Color.lsDanger)
        }
    }

    private var footer: some View {
        VStack(spacing: AppSpacing.group) {
            submitButton
            cancelButton
        }
    }

    private var submitButton: some View {
        PrimaryButton(
            icon: "checkmark", title: "儲存變更", isLoading: isSubmitting, loadingTitle: "正在儲存…", action: submit
        )
    }

    private var cancelButton: some View {
        Button {
            dismiss()
        } label: {
            Text("取消")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.controlPaddingMedium)
        }
        .disabled(isSubmitting)
    }

    private func submit() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showsEmptyTitleMessage = true
            return
        }
        Task {
            let succeeded = await detailStore.submitEdit(title: trimmed, childIDs: Array(selectedChildIDs))
            if succeeded {
                dismiss()
            }
        }
    }
}

#if DEBUG
#Preview {
    EditAlbumView(detailStore: .preview(), childrenStore: .preview())
}
#endif

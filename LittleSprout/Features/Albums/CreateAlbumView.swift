import SwiftUI

/// 「新增相簿」sheet（LS-165 票文 Scope 2：名稱＋寶貝標記 → 建立相簿）。
///
/// 沒有專屬 .pen 設計稿——LS-142 範圍只畫了相簿 tab root／相簿詳情／上傳佇列三個畫面群
/// （票文「範圍」1–3），這個建立流程的入口只在 tab root 的 Header Row「＋新增相簿」按鈕，
/// 沒有另外出建立流程本身的稿。版面完全組合自既有、已核可的元件，不是這裡新畫的視覺設計：
/// 姓名欄沿用 `LabeledTextField`（同 `CreateChildView` 姓名欄既有寫法）；寶貝標記沿用
/// `AttributionSheet`（該檔文件註解已明確宣告可供相簿發佈流程直接重用，不需要另外出稿，
/// LS-165 覆寫其 `title`／`subtitle` 讓文案符合相簿情境，見該檔文件註解）。
struct CreateAlbumView: View {
    let familyID: UUID
    let albumsStore: AlbumsStore
    let childrenStore: ChildrenStore

    @State private var title = ""
    @State private var showsEmptyTitleMessage = false
    @State private var selectedChildIDs: Set<UUID> = []
    @State private var showsAttributionSheet = false
    @Environment(\.dismiss) private var dismiss

    private var isSubmitting: Bool { albumsStore.createAlbumState.isSubmitting }

    /// 不用系統 `NavigationStack`＋`ToolbarItem(placement: .cancellationAction)`：實測
    /// nav bar 的 bar button item 熱區不受內層 SwiftUI `.padding()`／`.contentShape()`
    /// 影響（同 `DiaryEditorView.cancelButton`／`OTPVerificationView` 既有教訓的另一種
    /// 呈現——那兩處是把取消／返回鈕整個搬出系統 toolbar，改成一般 body 內容），量到只有
    /// 50×36pt。改用 `CreateChildView.footer`「主鈕＋純文字次要鈕」的既有慣例：兩顆都是
    /// 一般 body content 裡的 Button，`.padding()` 對它們的熱區才會生效。
    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                nameField
                    .padding(.top, AppSpacing.section)
                childField
                    .padding(.top, AppSpacing.item)
                if case .failure(let error) = albumsStore.createAlbumState {
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
        .onAppear { albumsStore.resetCreateAlbumState() }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("新增相簿")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("先取個名字，之後隨時可以再加照片。")
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

    private func errorMessage(_ error: AppError) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.circle.fill").appIconFrame(.small).foregroundStyle(Color.lsDanger)
            Text(error.userFacingMessage).appFont(.note).foregroundStyle(Color.lsDanger)
        }
    }

    /// 同 `CreateChildView.footer`：主鈕＋純文字次要鈕，取代原本掛在系統 nav bar
    /// `ToolbarItem` 的「取消」（見 `body` 文件註解——那條路徑量到 50×36pt，低於 44pt 下限）。
    private var footer: some View {
        VStack(spacing: AppSpacing.group) {
            submitButton
            cancelButton
        }
    }

    private var submitButton: some View {
        PrimaryButton(
            icon: "checkmark", title: "建立相簿", isLoading: isSubmitting, loadingTitle: "正在建立…", action: submit
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
                // 同 `CreateChildView.footer`「之後再說」鈕既有修法：稿面 `cmp/Button Text`
                // 的 `$ctl-pad-tap`（9.5）量出來低於 44pt 下限，改用較大內距撐大點擊區。
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
            let succeeded = await albumsStore.createAlbum(
                familyID: familyID, title: trimmed, childIDs: Array(selectedChildIDs)
            )
            if succeeded {
                dismiss()
            }
        }
    }
}

#if DEBUG
#Preview {
    CreateAlbumView(familyID: UUID(), albumsStore: .preview(), childrenStore: .preview())
}
#endif

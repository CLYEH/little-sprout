import SwiftUI

/// LS-18 / 05 建立家庭（含 05b 送出中）。版式依 `design/littlesprout.pen` frame `bC6ZX`／
/// `cy89z`：單一欄位（家庭名稱）＋即時預覽卡（Family Caption 用 `$print-ink`，見 LS-46
/// 進場條件③）＋主要送出鈕。
///
/// 空欄位不 disable CTA（Handoff Notes「05 建立家庭」R6 改寫）：按下去由欄位自己的說明列
/// 回話，不是把按鈕變灰——全稿驗證型 disable＝0，只有 in-flight（送出中）才鎖欄位。
struct CreateFamilyView: View {
    let familyStore: FamilyStore

    @State private var name: String
    @State private var showsEmptyNameMessage = false

    init(familyStore: FamilyStore, initialName: String = "") {
        self.familyStore = familyStore
        _name = State(initialValue: initialName)
    }

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                topSection
                Spacer(minLength: AppSpacing.block)
                FamilyPreviewCard(name: name)
                Spacer(minLength: AppSpacing.block)
                footerButton
                    .padding(.bottom, AppSpacing.item)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        // Store 層狀態隨 app 存活，不會像 View-local @State 一樣每次進畫面自動重置（見
        // `FamilyStore.resetCreateFamilyState` 文件）——離開這個畫面又回來時，先清掉上一次
        // 留下的失敗殘影。
        .onAppear { familyStore.resetCreateFamilyState() }
    }

    private var isSubmitting: Bool { familyStore.createFamilyState.isSubmitting }

    private var topSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                Text("建立家庭")
                    .appFont(.display, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                Text("先給這個家庭取個名字，例如「陳家」或「阿嬤家」。")
                    .appFont(.body)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            LabeledTextField(
                label: "家庭名稱",
                placeholder: "陳家",
                text: Binding(
                    get: { name },
                    set: { newValue in
                        name = newValue
                        showsEmptyNameMessage = false
                    }
                ),
                helpText: fieldHelpText,
                isError: isFieldError,
                submitLabel: .done,
                onSubmit: submit
            )
            .disabled(isSubmitting)
            Text(footerNoteText)
                .appFont(isSubmitting ? .note : .meta, weight: isSubmitting ? .semibold : .regular)
                .foregroundStyle(isSubmitting ? Color.lsTextPrimary : Color.lsTextSecondary)
        }
    }

    /// 三個來源疊在同一個說明列：送出中的鎖定提示 > 空欄位壓測回話 > 後端錯誤 > 預設說明——
    /// 前兩者不算「錯誤」（`isFieldError` 對它們回 false，維持 `LabeledTextField` 的預設淺色
    /// 樣式，不套用 `$danger`），只有真正的後端失敗才走錯誤態文法。
    private var fieldHelpText: String {
        if isSubmitting { return "送出期間先不能修改。" }
        if showsEmptyNameMessage { return "還沒填家庭名稱。在上面打上名字，再按一次。" }
        if case .failure(let error) = familyStore.createFamilyState { return error.userFacingMessage }
        return "家人加入後會看到這個名稱，之後可以再改。"
    }

    private var isFieldError: Bool {
        guard !isSubmitting, !showsEmptyNameMessage else { return false }
        if case .failure = familyStore.createFamilyState { return true }
        return false
    }

    private var footerNoteText: String {
        isSubmitting ? "正在建立你的家庭，請稍候幾秒鐘。" : "建立後你會是這個家庭的管理者，可以邀請家人、管理內容。"
    }

    private var footerButton: some View {
        PrimaryButton(
            icon: "checkmark",
            title: "建立家庭",
            isLoading: isSubmitting,
            loadingTitle: "正在建立…",
            action: submit
        )
    }

    private func submit() {
        guard !isSubmitting else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showsEmptyNameMessage = true
            return
        }
        showsEmptyNameMessage = false
        Task { await familyStore.createFamily(name: trimmed) }
    }
}

/// 建立家庭當下的即時預覽卡（`design/littlesprout.pen` frame `bC6ZX` 節點 `H0KHI`）：還沒有
/// 真實照片可以放，照片區塊維持 `$surface-2` 空白；家庭名稱用 `$print-ink`（不隨深色模式反轉，
/// 見 `ColorTokens.swift` 文件）當作沖印品下緣的手寫標籤。
private struct FamilyPreviewCard: View {
    let name: String

    var body: some View {
        VStack(spacing: 7) {
            Color.lsSurface2
                .frame(height: 120)
            Text(displayName)
                .appFont(.lead, weight: .semibold)
                .foregroundStyle(Color.lsPrintInk)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(.top, AppSpacing.printEdge)
        .padding(.horizontal, AppSpacing.printEdge)
        .padding(.bottom, AppSpacing.printEdgeBottom)
        .background(Color.lsPrintPaper)
        .overlay(PhotoCornerOverlay(size: 26))
        // 家庭名稱已經在上面的欄位輸入/顯示過一次；這張卡是純裝飾性的即時預覽，不重複唸給
        // VoiceOver 使用者聽。
        .accessibilityHidden(true)
    }

    /// Stress / 05 空欄位卡（`design/littlesprout.pen` frame `hElk0` 節點 `yOHuy`）的
    /// `content:" "`：單一半形空白撐住白邊帶行高與卡高，不是空字串（Pencil 的 `Update()`
    /// 對 `content:""` 會靜默丟棄整個屬性）。這裡對應寫法：trimmed 名稱是空的時候仍回傳一個
    /// 空白字元，不是隱藏整列——避免卡高在填名前後跳動。
    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? " " : trimmed
    }
}

#Preview("空欄位") {
    NavigationStack {
        CreateFamilyView(familyStore: .preview())
    }
}

#Preview("已輸入") {
    NavigationStack {
        CreateFamilyView(familyStore: .preview(), initialName: "陳家")
    }
}

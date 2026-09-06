import SwiftUI

/// 04e 最終確認（`design/littlesprout.pen` `X6rf9c`／深色 `v4w2pV`／AX3 `dHnPl`）：LS-193——見
/// `DeleteAccountFlowView.swift` 檔頭對整組畫面拆檔理由的說明。
///
/// LS-152 Notes「十條-8」段的關鍵設計決策：不用長按、不用驗證型 disable（兩者分別違反
/// elder-constraints.md 與品牌十條第 8 條）。改用文字輸入框＋按鈕永遠可點——按下時若輸入不符
/// 「刪除帳號」四個字，只顯示 `hintRow`（`$text-primary`＋circle-alert，不是 danger 責備），
/// 不阻擋按鈕本身可點。`hintRow` 用固定佔位＋`.opacity` 切換（不是條件式 `if`）：兩態的
/// Delete Button y 座標因此不會因為 hint 顯示與否而位移，同 Notes「MJ-3 兩態座標對照」驗收的
/// 「固定高、不塌縮」精神，且不需要照抄稿面量到的 50／232 這種特定字級下的像素值（SwiftUI
/// 端一律讓內容依 Dynamic Type 自然決定高度）。
struct FinalDeleteConfirmView: View {
    let model: DeleteAccountFlowModel

    @State private var confirmText = ""
    @State private var showsMismatchHint = false

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                header
                confirmField
                    .padding(.top, AppSpacing.section)
                hintRow
                    .padding(.top, AppSpacing.label)
                Spacer(minLength: AppSpacing.item)
                footer
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
            .padding(.bottom, AppSpacing.block)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("最後確認")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("這是刪除帳號前的最後一步。請在下面輸入「刪除帳號」四個字，確認你真的要這麼做。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var confirmField: some View {
        TextField("輸入「刪除帳號」", text: $confirmText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: confirmText) { _, _ in showsMismatchHint = false }
            .appFont(.body)
            .foregroundStyle(Color.lsTextPrimary)
            .padding(.horizontal, AppSpacing.insetCard)
            .frame(minHeight: 60)
            .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
            .accessibilityIdentifier(QAAccessibilityID.deleteAccountConfirmField)
    }

    private var hintRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.circle.fill").appIconFrame(.small)
            Text("請先在上面輸入「刪除帳號」四個字，才能繼續。")
                .appFont(.note, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.lsTextPrimary)
        .opacity(showsMismatchHint ? 1 : 0)
        .accessibilityHidden(!showsMismatchHint)
    }

    private var footer: some View {
        VStack(spacing: AppSpacing.group) {
            DeleteAccountDangerButton(
                icon: "trash", label: "永久刪除帳號", action: deleteTapped, isLoading: model.isProcessing
            )
            DeleteAccountTextButton(label: "取消", action: model.cancelFinalConfirm)
        }
    }

    private func deleteTapped() {
        guard DeleteAccountConfirmationPhrase.matches(confirmText) else {
            showsMismatchHint = true
            return
        }
        model.confirmDeletion()
    }
}

#if DEBUG
#Preview("04e 最終確認") {
    NavigationStack {
        FinalDeleteConfirmView(model: DeleteAccountFlowModel(
            accountAPIClient: PreviewAccountAPIClient(), familyStore: .preview(), authStore: .preview(),
            childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview(),
            eulaStore: .preview(shouldPresent: false)
        ))
    }
}
#endif

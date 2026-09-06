import SwiftUI

/// LS-189（依 LS-152 稿 `SSfdn`／AX3 `q4mb2`）：檢舉原因單選——`ContentActionsSheet` 選「檢舉
/// 這則內容」之後開出的下一張 sheet。六個原因對應 `ReportReason`（見該檔 `p_reason → key`
/// 對照表），送出成功後交給 `onSent`（呼叫端接著開 `ReportSentSheet`，05c）。
///
/// 版式沿用 `DeleteConfirmationSheet`／`ContentActionsSheet` 的既有理由：自畫 Grabber、
/// `.medium`／`.large` 兩級 detent，內容包 `ScrollView`（AX3 六個原因列＋標題副標可能超出
/// `.medium`，見稿面 `q4mb2` 板高 1500 已預期這件事）。
struct ReportReasonSheet: View {
    let familyName: String
    let familyID: UUID
    let targetType: ContentTargetType
    let targetID: UUID
    let safetyAPIClient: SafetyAPIClient
    /// RPC 成功、sheet 已關閉之後呼叫（同 `DeleteConfirmationSheet.onSuccess` 的先關後呼順序）
    /// ——呼叫端接著開 `ReportSentSheet`。
    var onSent: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var selectedReason: ReportReason?
    @State private var isSubmitting = false
    @State private var error: AppError?

    var body: some View {
        VStack(spacing: 0) {
            grabber
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.block) {
                    header
                    reasonList
                }
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.bottom, AppSpacing.block)
            }
            .clipped()
            VStack(spacing: AppSpacing.group) {
                submitButton
                cancelButton
                if let error {
                    errorRow(error)
                }
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.group)
            .padding(.bottom, AppSpacing.section)
        }
        .background(Color.lsSurface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationContentInteraction(.scrolls)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.lsBorder)
            .frame(width: 36, height: 5)
            .padding(.top, AppSpacing.block)
            .padding(.bottom, AppSpacing.tight)
            .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("檢舉這則內容")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("請選一個最符合的原因，我們與「\(familyName)」的家庭管理者都會看到。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var reasonList: some View {
        VStack(spacing: 0) {
            ForEach(Array(ReportReason.allCases.enumerated()), id: \.offset) { index, reason in
                if index > 0 { Divider().overlay(Color.lsBorder) }
                reasonRow(reason)
            }
        }
        .background(Color.lsSurface2, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }

    private func reasonRow(_ reason: ReportReason) -> some View {
        Button {
            selectedReason = reason
        } label: {
            HStack(spacing: AppSpacing.group) {
                Image(systemName: selectedReason == reason ? "checkmark.circle.fill" : "circle")
                    .appIconFrame(.medium)
                    .foregroundStyle(selectedReason == reason ? Color.lsTextPrimary : Color.lsTextSecondary)
                Text(reason.displayLabel)
                    .appFont(.body)
                    .foregroundStyle(Color.lsTextPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.item)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selectedReason == reason ? .isSelected : [])
    }

    private var submitButton: some View {
        Button(action: submitTapped) {
            HStack(spacing: AppSpacing.label) {
                if isSubmitting {
                    ProgressView().tint(Color.lsOnAccent)
                }
                Text("送出").appFont(.body, weight: .bold)
            }
            .foregroundStyle(Color.lsOnAccent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
        .disabled(selectedReason == nil || isSubmitting)
        .opacity(selectedReason == nil ? 0.5 : 1)
    }

    private var cancelButton: some View {
        Button {
            dismiss()
        } label: {
            Text("取消")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .disabled(isSubmitting)
    }

    private func errorRow(_ error: AppError) -> some View {
        HStack(spacing: AppSpacing.tight) {
            Image(systemName: "exclamationmark.circle").appIconFrame(.small)
            Text(error.userFacingMessage).appFont(.note)
        }
        .foregroundStyle(Color.lsDanger)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 同 `DeleteConfirmationSheet.confirmTapped`：`guard !isSubmitting` 擋連點（同一個
    /// runloop 內排出兩個 `Task`）。
    private func submitTapped() {
        guard let selectedReason, !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await safetyAPIClient.reportContent(
                    familyID: familyID, targetType: targetType, targetID: targetID, reason: selectedReason
                )
                dismiss()
                onSent()
            } catch {
                self.error = AppError.map(error)
            }
        }
    }
}

#if DEBUG
#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        ReportReasonSheet(
            familyName: "陳家", familyID: UUID(), targetType: .comment, targetID: UUID(),
            safetyAPIClient: PreviewSafetyAPIClient()
        )
    }
}
#endif

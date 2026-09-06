import SwiftUI

/// LS-189（依 LS-152 稿 `rtpQr`）：檢舉已送出——`ReportReasonSheet` 送出成功後開出的收尾卡，
/// 純顯示＋一顆「完成」鈕，不呼叫任何 RPC。
struct ReportSentSheet: View {
    let familyName: String
    /// 「完成」鈕按下、sheet 已關閉之後呼叫（例如清掉呼叫端整條操作表流程的狀態）。
    var onDone: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            grabber
            successBadge
            VStack(spacing: AppSpacing.label) {
                Text("已送出，家庭管理者會處理")
                    .appFont(.lead, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .multilineTextAlignment(.center)
                Text("我們與「\(familyName)」的家庭管理者都收到這則檢舉了，會盡快處理。")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            Button {
                dismiss()
                onDone()
            } label: {
                Text("完成")
                    .appFont(.body, weight: .bold)
                    .foregroundStyle(Color.lsOnAccent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.bottom, AppSpacing.section)
        }
        .background(Color.lsSurface)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.lsBorder)
            .frame(width: 36, height: 5)
            .padding(.top, AppSpacing.block)
            .accessibilityHidden(true)
    }

    private var successBadge: some View {
        Circle()
            .fill(Color.lsSuccess)
            .frame(width: 64, height: 64)
            .overlay {
                Image(systemName: "checkmark")
                    .appIconFrame(.medium)
                    .foregroundStyle(Color.lsOnAccent)
            }
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        ReportSentSheet(familyName: "陳家")
    }
}
#endif

import SwiftUI

/// LS-189（依 LS-152 稿 `WgbNc`）：內容操作表——日記／照片／留言「⋯」或長按開出的 bottom
/// sheet。動作列本身由 `contentActions(for:...)`（純函式，見該檔）依身分算好，這裡只負責畫出
/// 給定的列並回報使用者選了哪一個；「選了之後開哪張卡」交給呼叫端（見 `onSelect` 文件註解）。
///
/// **Grabber 自畫、`.medium`／`.large` 兩級 detent**：同 `DeleteConfirmationSheet` 既有理由
/// （LS-190 R2／R3，見該檔文件註解）——系統 `.presentationDragIndicator` 會被 tap-target gate
/// 誤判成 <44pt 違規，自我量測高度是循環相依的死路。動作列數最多 3（檢舉／封鎖／移除）或 1
/// （刪除），內容量遠小於刪除確認卡的長文案，`.medium` 已足夠，這裡仍給 `.large` 當保險（AX3
/// 字級時列高會長高）。
struct ContentActionsSheet: View {
    let headline: String
    let actions: [ContentAction]
    /// 呼叫端負責 dismiss 之後的下一步（開 05b／05d／05e／既有刪除確認 sheet）——這裡已經先
    /// `dismiss()` 過，同 `DeleteConfirmationSheet` R2 m3「先關自己這張 sheet，再讓呼叫端接手」
    /// 的既有規約。
    let onSelect: (ContentAction) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            grabber
            Text(headline)
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.bottom, AppSpacing.group)
            VStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    if index > 0 { Divider().overlay(Color.lsBorder) }
                    actionRow(action)
                }
            }
            .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .padding(.horizontal, AppSpacing.screenPad)
            cancelButton
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, AppSpacing.group)
                .padding(.bottom, AppSpacing.section)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.lsBorder)
            .frame(width: 36, height: 5)
            .padding(.top, AppSpacing.block)
            .padding(.bottom, AppSpacing.tight)
            .accessibilityHidden(true)
    }

    private func actionRow(_ action: ContentAction) -> some View {
        Button {
            dismiss()
            onSelect(action)
        } label: {
            HStack(spacing: AppSpacing.group) {
                Image(systemName: action.icon).appIconFrame(.medium)
                Text(action.label).appFont(.body, weight: .semibold)
                Spacer(minLength: 0)
            }
            .foregroundStyle(action.isDanger ? Color.lsDanger : Color.lsTextPrimary)
            .padding(.horizontal, AppSpacing.item)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
    }

    private var cancelButton: some View {
        Button {
            dismiss()
        } label: {
            Text("取消")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
    }
}

#if DEBUG
#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        ContentActionsSheet(
            headline: "「今天在溜滑梯上玩得好開心。」",
            actions: [.report, .block(memberID: UUID(), memberName: "陳志明"), .removeAsOwner],
            onSelect: { _ in }
        )
    }
}
#endif

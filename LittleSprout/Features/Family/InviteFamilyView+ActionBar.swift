import SwiftUI

/// 釘底 Action Bar（LS-111 R6 起的慣例，見 `InviteFamilyView` 檔頭文件註解）＋次要動作（複製碼／
/// 名額文案）——拆成獨立檔案，理由同 `InviteFamilyView+Role.swift`／
/// `InviteFamilyView+PendingApprovals.swift` 檔頭註解（主檔逼近 SwiftLint `file_length` 上限）。
/// 這裡的成員不是 `private`：理由同上述兩檔。
extension InviteFamilyView {
    // MARK: - Action Bar

    @ViewBuilder
    var actionBarContainer: some View {
        if case .checkingExisting = phase {
            // 純技術查詢等待態沒有任何可按動作——不畫 hairline／底列，同既有慣例（見
            // `actionsSection` 舊版註解，行為不變，只是搬進釘底容器）。
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Rectangle().fill(Color.lsBorder).frame(height: 1)
                actionBarContent
                    .padding(.vertical, AppSpacing.item)
                    .padding(.horizontal, AppSpacing.screenPad)
            }
            .background(Color.lsSurface)
        }
    }

    @ViewBuilder
    private var actionBarContent: some View {
        switch phase {
        case .checkingExisting:
            EmptyView()
        case .lookupFailed:
            // R2 N1：查詢失敗時不知道這個家庭有沒有既有碼，不能顯示「產生邀請碼」（會重複
            // 建立、舊碼撤不掉）——只給重試，跟 `RootView.FamilyLookupFailedView` 同一個
            // 兜底邏輯，錯誤文字已經在上面的 `errorRow` 顯示過。
            SecondaryButton(icon: "arrow.clockwise", title: "重試", action: retryLookup)
        case .empty:
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                Text("產生後 7 天內有效，最多 5 位家人可以用。")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
                PrimaryButton(icon: "plus", title: "產生邀請碼", action: generate)
            }
        case .generating:
            PrimaryButton(
                icon: "arrow.triangle.2.circlepath",
                title: "產生邀請碼",
                isLoading: true,
                loadingTitle: "正在產生邀請碼…",
                action: {}
            )
        case .generated(let invite):
            ShareLink(
                item: inviteURL(invite.code),
                subject: Text("邀請你加入「\(familyStore.myFamily?.name ?? "")」")
            ) {
                HStack(spacing: AppSpacing.label) {
                    Image(systemName: "square.and.arrow.up").appIconFrame(.medium)
                    Text("分享邀請連結").appFont(.body, weight: .bold)
                }
                .foregroundStyle(Color.lsOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.controlPaddingCTA)
                .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            }
        }
    }

    // MARK: - 次要動作（複製碼／名額文案，依狀態切換）

    @ViewBuilder
    var secondaryActionsSection: some View {
        switch phase {
        case .generating:
            SecondaryButton(icon: "doc.on.doc", title: "複製邀請碼", isDimmed: true) {}
        case .generated(let invite):
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                SecondaryButton(icon: "doc.on.doc", title: copyButtonTitle, action: { copyCode(invite.code) })
                // R1 F3：票文 Scope 第 3 點要求的名額文案（`used_count` 不退還，Linear comment
                // `4f10699c`）——`.pen` 07c 沒有這句（全稿「名額」只在 06b/06c 申請人側出現），
                // 措辭與位置比照既有的 07a 政策小字。
                Text("名額不退還，需要更多名額請重新產生。")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
        case .checkingExisting, .lookupFailed, .empty:
            EmptyView()
        }
    }

    private var copyButtonTitle: String {
        showsCopiedFeedback ? "已複製！" : "複製邀請碼"
    }
}

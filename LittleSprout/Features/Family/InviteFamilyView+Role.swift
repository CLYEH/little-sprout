import SwiftUI

/// LS-111 角色列（member／viewer）——拆成獨立檔案，理由同 `InviteFamilyView+PendingApprovals.swift`
/// 檔頭註解（主檔逼近 SwiftLint `file_length` 上限）。這裡的成員不是 `private`：跨檔案的
/// extension 碰不到主檔的 `private` 存取層級，退而求其次用預設 internal（同
/// `FamilyStore+JoinRequests.swift` 的取捨，見該檔文件註解）。
extension InviteFamilyView {
    // MARK: - 角色選擇（互動列，07a）

    var interactiveRoleSection: some View {
        VStack(spacing: AppSpacing.label) {
            roleOptionRow(role: .member, icon: "pencil", title: "一般成員", description: "可以發文、留言，也能上傳照片。")
            roleOptionRow(role: .viewer, icon: "eye", title: "只能看", description: "只能看照片和日記，不能發文。")
        }
    }

    /// 四通道編碼（LS-111 R8 現況）：語意 icon（pencil／eye）＋絕對定位 checkmark（未選中時
    /// 透明、非移除節點，保留版面對齊）＋字重（700 選中／600 未選中）＋背景（`$print-paper`
    /// 紙面選中／透明未選中）。選中列額外浮起（`$paper-shadow` 陰影），未選中列直接躺在背景上
    /// ——不是兩張並排的卡片，是「一列被選中就浮起變成一張紙」。
    private func roleOptionRow(role: FamilyRole, icon: String, title: String, description: String) -> some View {
        let isSelected = selectedRole == role
        return Button {
            selectedRole = role
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.item) {
                Image(systemName: icon)
                    .appIconFrame(.medium)
                    .foregroundStyle(isSelected ? Color.lsPrintInk : Color.lsTextSecondary)
                VStack(alignment: .leading, spacing: AppSpacing.label) {
                    Text(title)
                        .appFont(.body, weight: isSelected ? .bold : .semibold)
                        .foregroundStyle(isSelected ? Color.lsPrintInk : Color.lsTextPrimary)
                    Text(description)
                        .appFont(.body)
                        .foregroundStyle(isSelected ? Color.lsPrintInkSecondary : Color.lsTextSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(AppSpacing.item)
            .background(
                isSelected ? Color.lsPrintPaper : Color.clear,
                in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                    .strokeBorder(isSelected ? Color.lsPaperEdge : Color.clear, lineWidth: 1)
            )
            .shadow(color: isSelected ? Color.lsPaperShadow : .clear, radius: 3, x: 0, y: 2)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark")
                    .appIconFrame(.medium)
                    .foregroundStyle(isSelected ? Color.lsPrintInk : Color.clear)
                    .padding(AppSpacing.item)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 角色狀態（唯讀列，07／07c，`cmp/Role Status`）

    var roleStatusSection: some View {
        // `.generating` 時 `latestInvite` 已經被 `createInvite` 設回 nil（撤銷舊碼之後、拿到新碼
        // 之前，見 `FamilyStore.createInvite` 文件）——落回 `selectedRole`（使用者剛選的那個），
        // 顯示「正在建立哪個角色」而不是舊碼的角色。
        let role = familyStore.latestInvite?.role ?? selectedRole
        return HStack(alignment: .top, spacing: AppSpacing.item) {
            Image(systemName: role == .viewer ? "eye" : "pencil")
                .appIconFrame(.medium)
                .foregroundStyle(Color.lsTextPrimary)
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                Text("這支邀請碼的身份：\(role == .viewer ? "只能看" : "一般成員")")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                Text("要換身份，請重新產生一組。")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.item)
    }
}

import SwiftUI

/// LS-152 / 03b・03c・03d・03e 四張確認 sheet——拆成獨立檔案，理由同
/// `InviteFamilyView+ActionBar.swift` 檔頭註解（`FamilyMembersView.swift` 逼近 SwiftLint
/// `file_length` 上限）。版式沿用 `EditChildView.DeleteChildSheet` 既有慣例：grabber＋標題＋
/// 完整文案交代後果＋主要確認鈕（`.presentationDetents([.medium])`）。可點元件一律
/// `minHeight: 48`（orchestrator 附加要求，比長輩硬約束 44pt 再多一點安全邊界，同
/// `LabeledTextField` 顯示／隱藏切換鈕的既有理由——次像素捨入可能讓剛好 44pt 卡在邊界）。

/// 03b：Owner 移除成員確認。
struct RemoveMemberSheet: View {
    let familyStore: FamilyStore
    let member: FamilyMember

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Capsule().fill(Color.lsBorder).frame(width: 36, height: 5)
            Text("要移除\(member.displayName)嗎？")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            Text("移除後，\(member.displayName)不會再看到這個家庭的照片和日記，需要新的邀請碼才能重新加入。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            if case .failure(let error) = familyStore.memberActionState {
                Text(error.userFacingMessage)
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(Color.lsDanger)
            }
            VStack(spacing: AppSpacing.group) {
                Button(action: confirm) {
                    HStack(spacing: AppSpacing.label) {
                        if familyStore.memberActionState.isSubmitting {
                            ProgressView()
                        } else {
                            Image(systemName: "person.fill.xmark").appIconFrame(.medium)
                        }
                        Text(familyStore.memberActionState.isSubmitting ? "正在移除…" : "移除成員")
                            .appFont(.body, weight: .bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingMedium)
                    .frame(minHeight: 48)
                }
                .foregroundStyle(Color.lsDanger)
                .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                        .strokeBorder(Color.lsDanger, lineWidth: 1.5)
                )
                .disabled(familyStore.memberActionState.isSubmitting)
                cancelButton
            }
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, AppSpacing.block)
        .padding(.bottom, AppSpacing.section)
        .presentationDetents([.medium])
        .onAppear { familyStore.resetMemberActionState() }
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
                .frame(minHeight: 48)
        }
        .disabled(familyStore.memberActionState.isSubmitting)
    }

    private func confirm() {
        guard !familyStore.memberActionState.isSubmitting else { return }
        Task {
            if await familyStore.removeMember(userID: member.userID) {
                dismiss()
            }
        }
    }
}

/// 03c：轉移 Owner 確認——不是刪除性動作（不丟資料），主鈕維持 accent 而非 danger，但仍
/// 明講後果（自己降為一般成員）。
struct TransferOwnershipSheet: View {
    let familyStore: FamilyStore
    let member: FamilyMember

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Capsule().fill(Color.lsBorder).frame(width: 36, height: 5)
            Text("把 Owner 身份轉移給\(member.displayName)？")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            Text("轉移後，你會變成一般成員，\(member.displayName)會成為這個家庭的 Owner，可以管理成員與家庭設定。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            if case .failure(let error) = familyStore.memberActionState {
                Text(error.userFacingMessage)
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(Color.lsDanger)
            }
            VStack(spacing: AppSpacing.group) {
                PrimaryButton(
                    icon: "crown",
                    title: "轉移 Owner 身份",
                    isLoading: familyStore.memberActionState.isSubmitting,
                    loadingTitle: "正在轉移…",
                    action: confirm
                )
                .frame(minHeight: 48)
                cancelButton
            }
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, AppSpacing.block)
        .padding(.bottom, AppSpacing.section)
        .presentationDetents([.medium])
        .onAppear { familyStore.resetMemberActionState() }
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
                .frame(minHeight: 48)
        }
        .disabled(familyStore.memberActionState.isSubmitting)
    }

    private func confirm() {
        guard !familyStore.memberActionState.isSubmitting else { return }
        Task {
            if await familyStore.transferOwnership(toUserID: member.userID) {
                dismiss()
            }
        }
    }
}

/// 03d：退出家庭確認（非唯一 owner，或唯一成員）——client 端已經判斷過不需要先轉移
/// （`FamilyStore.mustTransferOwnershipBeforeLeaving == false`），伺服器 `LS057` 仍是最終
/// 裁決（極端併發窗口仍可能被擋，見 `FamilyMembersView.startLeaveFlow` 文件註解），失敗時
/// 顯示對應錯誤文案，不強行當作成功。
struct LeaveFamilyConfirmSheet: View {
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    let albumsStore: AlbumsStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Capsule().fill(Color.lsBorder).frame(width: 36, height: 5)
            Text("要退出「\(familyStore.myFamily?.name ?? "")」嗎？")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            Text("退出後，你不會再看到這個家庭的照片和日記，需要新的邀請碼才能重新加入。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            if case .failure(let error) = familyStore.memberActionState {
                Text(error.userFacingMessage)
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(Color.lsDanger)
            }
            VStack(spacing: AppSpacing.group) {
                Button(action: confirm) {
                    HStack(spacing: AppSpacing.label) {
                        if familyStore.memberActionState.isSubmitting {
                            ProgressView()
                        } else {
                            Image(systemName: "door.left.hand.open").appIconFrame(.medium)
                        }
                        Text(familyStore.memberActionState.isSubmitting ? "正在退出…" : "退出家庭")
                            .appFont(.body, weight: .bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingMedium)
                    .frame(minHeight: 48)
                }
                .foregroundStyle(Color.lsDanger)
                .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                        .strokeBorder(Color.lsDanger, lineWidth: 1.5)
                )
                .disabled(familyStore.memberActionState.isSubmitting)
                cancelButton
            }
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, AppSpacing.block)
        .padding(.bottom, AppSpacing.section)
        .presentationDetents([.medium])
        .onAppear { familyStore.resetMemberActionState() }
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
                .frame(minHeight: 48)
        }
        .disabled(familyStore.memberActionState.isSubmitting)
    }

    /// 成功後連帶歸零 `childrenStore`／`timelineStore`／`albumsStore`——同
    /// `SettingsView.signOut()` 的既有理由：這三個 store 隨 app 存活，不清掉的話，同一個
    /// session 內若之後建立或加入另一個家庭，會先看到剛離開那個家庭的殘留資料。
    private func confirm() {
        guard !familyStore.memberActionState.isSubmitting else { return }
        Task {
            if await familyStore.leaveFamily() {
                childrenStore.reset()
                timelineStore.reset()
                albumsStore.reset()
                dismiss()
            }
        }
    }
}

/// 03e：唯一 owner 且家庭還有其他成員——純資訊性，導引使用者先去成員列表點「轉移 Owner
/// 身份」，這裡不重複那個流程的入口（03 成員列每一列的「…」選單已經有）。
struct MustTransferOwnershipFirstSheet: View {
    let familyName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Capsule().fill(Color.lsBorder).frame(width: 36, height: 5)
            Text("請先轉移 Owner 身份")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            Text("你是「\(familyName)」的唯一 Owner，退出前請先把 Owner 身份轉移給其他成員——在下面的成員列表點選成員旁的「…」，選擇「轉移 Owner 身份」。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            Button {
                dismiss()
            } label: {
                Text("好，我知道了")
                    .appFont(.body, weight: .bold)
                    .foregroundStyle(Color.lsOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingCTA)
                    .frame(minHeight: 48)
            }
            .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, AppSpacing.block)
        .padding(.bottom, AppSpacing.section)
        .presentationDetents([.medium])
    }
}

#if DEBUG
#Preview("03b 移除成員") {
    Color.clear.sheet(isPresented: .constant(true)) {
        RemoveMemberSheet(
            familyStore: .preview(),
            member: FamilyMember(userID: UUID(), role: .member, displayName: "陳小美", avatarURL: nil)
        )
    }
}

#Preview("03c 轉移 Owner") {
    Color.clear.sheet(isPresented: .constant(true)) {
        TransferOwnershipSheet(
            familyStore: .preview(),
            member: FamilyMember(userID: UUID(), role: .member, displayName: "陳小美", avatarURL: nil)
        )
    }
}

#Preview("03d 退出家庭") {
    Color.clear.sheet(isPresented: .constant(true)) {
        LeaveFamilyConfirmSheet(
            familyStore: .preview(withFamily: Family(
                id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
            )),
            childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview()
        )
    }
}

#Preview("03e 需先轉移") {
    Color.clear.sheet(isPresented: .constant(true)) {
        MustTransferOwnershipFirstSheet(familyName: "陳家")
    }
}
#endif

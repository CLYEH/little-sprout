import SwiftUI

/// LS-152 / 03b・03c・03d 三張確認 sheet ＋ 03e push 頁——拆成獨立檔案，理由同
/// `InviteFamilyView+ActionBar.swift` 檔頭註解（`FamilyMembersView.swift` 逼近 SwiftLint
/// `file_length` 上限）。sheet 版式沿用 `EditChildView.DeleteChildSheet` 既有慣例：grabber＋
/// 標題＋完整文案交代後果＋主要確認鈕（`.presentationDetents([.medium])`）。可點元件一律
/// `minHeight: 48`（orchestrator 附加要求，比長輩硬約束 44pt 再多一點安全邊界，同
/// `LabeledTextField` 顯示／隱藏切換鈕的既有理由——次像素捨入可能讓剛好 44pt 卡在邊界）。
///
/// R2（merge-review R1 M1／B1）：四個動作的錯誤訊息一律先查
/// `AppError.familyMemberActionMessage`（LS0xx 專屬文案），沒有專屬文案才退回
/// `error.userFacingMessage`（見該屬性文件註解，`FamilyMemberActionVisibility.swift`）。

/// 03b：Owner 移除成員確認。
struct RemoveMemberSheet: View {
    let familyStore: FamilyStore
    let member: FamilyMember

    @Environment(\.dismiss) private var dismiss

    /// R2（merge-review R1 M6）：稿標題帶家庭名——「要把「陳志明」移出「陳家」嗎？」。
    private var familyName: String { familyStore.myFamily?.name ?? "" }

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Capsule().fill(Color.lsBorder).frame(width: 36, height: 5)
            Text("要把「\(member.displayName)」移出「\(familyName)」嗎？")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            Text("移出後，他將無法再看到這個家庭的相片、影片與日記。他自己上傳的內容會保留在家庭裡，除非你另外刪除。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            if case .failure(let error) = familyStore.memberActionState {
                Text(error.familyMemberActionMessage ?? error.userFacingMessage)
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
                        Text(familyStore.memberActionState.isSubmitting ? "正在移出…" : "移出成員")
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

/// 03c：轉移家庭管理者確認——不是刪除性動作（不丟資料），主鈕維持 accent 而非 danger，但仍
/// 明講後果（自己降為一般成員）。
struct TransferOwnershipSheet: View {
    let familyStore: FamilyStore
    let member: FamilyMember

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Capsule().fill(Color.lsBorder).frame(width: 36, height: 5)
            Text("要把家庭管理者身分交給「\(member.displayName)」嗎？")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            Text(
                "轉移後，\(member.displayName)可以管理家庭成員與內容、處理檢舉；你會變成一般成員，" +
                "仍能繼續使用這個家庭、看到所有照片與日記。"
            )
            .appFont(.note)
            .foregroundStyle(Color.lsTextPrimary)
            .multilineTextAlignment(.center)
            if case .failure(let error) = familyStore.memberActionState {
                Text(error.familyMemberActionMessage ?? error.userFacingMessage)
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(Color.lsDanger)
            }
            VStack(spacing: AppSpacing.group) {
                PrimaryButton(
                    icon: "crown",
                    title: "轉移家庭管理者",
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

/// 03d：退出家庭確認（非唯一 owner，或家庭另有共同 owner）——client 端已經判斷過不需要先
/// 轉移（`FamilyStore.leaveFlowCase == .leave`），伺服器 `LS057` 仍是最終裁決（極端併發窗口，
/// 例如共同 owner 幾乎同時退出，見 `FamilyMembersView.startLeaveFlow` 文件註解），失敗時用
/// `AppError.familyMemberActionMessage` 顯示對應文案（B1），不強行當作成功。
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
            Text("退出後，你將無法再看到這個家庭的相片、影片與日記，除非有人重新邀請你。你自己上傳的內容會保留在家庭裡。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            if case .failure(let error) = familyStore.memberActionState {
                Text(error.familyMemberActionMessage ?? error.userFacingMessage)
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

// R3（merge-review R2 M-A）：03e push 頁（`MustTransferOwnershipFirstView`）搬到獨立檔案
// `FamilyMembersView+LeavePrecheck.swift`——理由同本檔檔頭「拆成獨立檔案」註解，新增
// `.soleMember` 變體後這裡逼近 SwiftLint `file_length` 上限。

#if DEBUG
#Preview("03b 移除成員") {
    Color.clear.sheet(isPresented: .constant(true)) {
        RemoveMemberSheet(
            familyStore: .preview(withFamily: Family(
                id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
            )),
            member: FamilyMember(userID: UUID(), role: .member, displayName: "陳小美", avatarURL: nil)
        )
    }
}

#Preview("03c 轉移家庭管理者") {
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

#endif

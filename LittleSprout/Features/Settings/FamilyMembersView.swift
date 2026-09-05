import SwiftUI

/// LS-152 / 03 家庭成員（`design/littlesprout.pen` `hVAq3`，AX3 長名字壓測 `gjCoe`，
/// iPad `yJvj7`）：成員清單（角色徽章、Owner 標示）＋ Owner 動作（每列「…」選單，轉移
/// Owner 身份＝03c、移除成員＝03b，皆走確認 sheet）＋「退出家庭」入口（03d／03e，依
/// `FamilyStore.mustTransferOwnershipBeforeLeaving` client 端預判分流，伺服器 `LS057`
/// 為最終裁決，見該屬性文件註解）。
///
/// iPad：跟 `SettingsView`（LS-188／191 教訓）同理——這支畫面被推入 `SettingsView` regular
/// 版面既有的 sidebar＋detail 兩欄殼裡（該殼本身已經是 `HStack`，不是
/// `NavigationSplitView`），這裡不需要再判斷 size class 或另外分版面；`.sheet` 呈現的四張
/// 確認卡在 iPad 上 size class 一律是 compact（系統行為），內容本來就沒有依 size class 分支，
/// 不會誤判。
struct FamilyMembersView: View {
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    let albumsStore: AlbumsStore

    @State private var removeTarget: FamilyMember?
    @State private var transferTarget: FamilyMember?
    @State private var showsLeaveConfirmation = false
    @State private var showsMustTransferFirst = false

    private var myUserID: UUID? { familyStore.ownerUserID }
    private var myRole: FamilyRole? { familyStore.myRole }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                memberListCard
                    .padding(.top, AppSpacing.section)
                leaveFamilySection
                    .padding(.top, AppSpacing.block)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
            .padding(.bottom, AppSpacing.block)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            familyStore.resetMemberActionState()
            await familyStore.refreshMembers()
        }
        .sheet(item: $removeTarget) { member in
            RemoveMemberSheet(familyStore: familyStore, member: member)
        }
        .sheet(item: $transferTarget) { member in
            TransferOwnershipSheet(familyStore: familyStore, member: member)
        }
        .sheet(isPresented: $showsLeaveConfirmation) {
            LeaveFamilyConfirmSheet(
                familyStore: familyStore, childrenStore: childrenStore,
                timelineStore: timelineStore, albumsStore: albumsStore
            )
        }
        .sheet(isPresented: $showsMustTransferFirst) {
            MustTransferOwnershipFirstSheet(familyName: familyStore.myFamily?.name ?? "")
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("家庭成員")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("「\(familyStore.myFamily?.name ?? "")」目前的成員與角色。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    @ViewBuilder
    private var memberListCard: some View {
        if familyStore.membersState.isSubmitting && familyStore.members.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(AppSpacing.insetCard)
        } else if case .failure(let error) = familyStore.membersState, familyStore.members.isEmpty {
            memberListErrorRow(error)
        } else {
            SettingsCard {
                ForEach(Array(familyStore.members.enumerated()), id: \.element.id) { index, member in
                    if index > 0 { SettingsRowDivider() }
                    MemberRow(
                        member: member,
                        avatarURL: familyStore.avatarDisplayURL(rawValue: member.avatarURL),
                        myRole: myRole,
                        myUserID: myUserID,
                        onTransfer: { transferTarget = member },
                        onRemove: { removeTarget = member }
                    )
                }
            }
        }
    }

    private func memberListErrorRow(_ error: AppError) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text(error.userFacingMessage)
                .appFont(.note)
                .foregroundStyle(Color.lsDanger)
            Button("重試") {
                Task { await familyStore.refreshMembers() }
            }
            .appFont(.body, weight: .semibold)
        }
    }

    private var leaveFamilySection: some View {
        Button(action: startLeaveFlow) {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "door.left.hand.open").appIconFrame(.medium)
                Text("退出家庭").appFont(.body, weight: .semibold)
            }
            .foregroundStyle(Color.lsDanger)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .frame(minHeight: 44)
        }
    }

    /// 03d／03e 分流入口——client 端預判，見 `FamilyStore.mustTransferOwnershipBeforeLeaving`
    /// 文件註解；伺服器 `LS057` 才是最終裁決，`LeaveFamilyConfirmSheet` 送出後若仍拿到
    /// `LS057`（極端併發窗口，例如共同 owner 幾乎同時退出），照樣顯示對應錯誤文案，不會誤判
    /// 成功。
    private func startLeaveFlow() {
        if familyStore.mustTransferOwnershipBeforeLeaving {
            showsMustTransferFirst = true
        } else {
            showsLeaveConfirmation = true
        }
    }
}

/// 03 成員列——頭像＋姓名（「（你）」標記自己）＋角色徽章；Owner 檢視他人時多一顆「…」選單
/// （轉移 Owner 身份／移除成員），可見性依 `FamilyMember.isTransferable`／`isRemovable`
/// （見 `FamilyMemberActionVisibility.swift`）。
private struct MemberRow: View {
    let member: FamilyMember
    let avatarURL: URL?
    let myRole: FamilyRole?
    let myUserID: UUID?
    let onTransfer: () -> Void
    let onRemove: () -> Void

    private var isMe: Bool { myUserID == member.userID }

    private var canTransfer: Bool {
        guard let myRole, let myUserID else { return false }
        return member.isTransferable(byRole: myRole, myUserID: myUserID)
    }

    private var canRemove: Bool {
        guard let myRole, let myUserID else { return false }
        return member.isRemovable(byRole: myRole, myUserID: myUserID)
    }

    var body: some View {
        HStack(spacing: AppSpacing.group) {
            ChildAvatarView(name: member.displayName, size: 44, avatarURL: avatarURL)
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                HStack(spacing: AppSpacing.tight) {
                    Text(member.displayName)
                        .appFont(.body, weight: .semibold)
                        .foregroundStyle(Color.lsTextPrimary)
                        .lineLimit(1)
                    if isMe {
                        Text("（你）")
                            .appFont(.note)
                            .foregroundStyle(Color.lsTextSecondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                Text(member.role.membersListDisplayLabel)
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            Spacer(minLength: AppSpacing.group)
            if canTransfer || canRemove {
                actionMenu
            }
        }
        .padding(AppSpacing.insetCard)
        .frame(minHeight: 44)
    }

    private var actionMenu: some View {
        Menu {
            if canTransfer {
                Button("轉移 Owner 身份", action: onTransfer)
            }
            if canRemove {
                Button("移除成員", role: .destructive, action: onRemove)
            }
        } label: {
            Image(systemName: "ellipsis")
                .appIconFrame(.medium)
                .foregroundStyle(Color.lsTextSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(member.displayName)的動作")
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        FamilyMembersView(
            familyStore: .preview(withFamily: Family(
                id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
            )),
            childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview()
        )
    }
}
#endif

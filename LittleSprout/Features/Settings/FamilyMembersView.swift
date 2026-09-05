import SwiftUI

/// LS-152 / 03 家庭成員（`design/littlesprout.pen` `hVAq3`，AX3 長名字壓測 `gjCoe`，
/// iPad `yJvj7`）：成員清單（`cmp/Role Pill` 角色徽章、Owner 標示）＋ Owner 動作（每列尾端
/// chevron，轉移家庭管理者＝03c、移除成員＝03b，皆走確認 sheet）＋「退出家庭」入口
/// （03d／03e，依 `FamilyStore.mustTransferOwnershipBeforeLeaving` client 端預判分流，
/// 伺服器 `LS057`／`LS001` 為最終裁決，見該屬性與 `AppError.familyMemberActionMessage`
/// 文件註解）。
///
/// R2（merge-review R1 m2）：每列動作入口原本用「…」`Menu`，稿三板一律列尾 `chevron-right`
/// （22×22）——這裡改用 chevron 圖示但仍掛 `Menu` 觸發（不是直接導覽到單一畫面）：稿面沒有
/// 「一顆 chevron 決定進 03b 還是 03c」這個分支邏輯的畫面，`Menu` 在同一顆可點元件內先讓
/// 使用者選要做哪個動作，功能等價、圖示對齊稿面。
///
/// iPad：跟 `SettingsView`（LS-188／191 教訓）同理——這支畫面被推入 `SettingsView` regular
/// 版面既有的 sidebar＋detail 兩欄殼裡（該殼本身已經是 `HStack`，不是
/// `NavigationSplitView`），這裡不需要再判斷 size class 或另外分版面；`.sheet` 呈現的三張
/// 確認卡在 iPad 上 size class 一律是 compact（系統行為），內容本來就沒有依 size class 分支，
/// 不會誤判。稿 `yJvj7` 把家庭成員清單與「邀請家人」合併成 iPad 專屬的單頁 Detail Pane
/// 版式，與目前沿用 LS-188 殼（家庭成員／邀請家人／退出家庭三個入口各自導覽）的既有架構不同
/// ——這個落差本輪沒有處理（merge-review R1 標為「沒看／沒驗的範圍」，非 blocker／major），
/// 記入 handoff。
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
        // R2（merge-review R1 M2）：03e 稿是 push 整頁（Nav Back，無 Tab Bar），不是 sheet
        // ——`MustTransferOwnershipFirstSheet` 已改名為 `MustTransferOwnershipFirstView` 並改用
        // `navigationDestination`。
        .navigationDestination(isPresented: $showsMustTransferFirst) {
            MustTransferOwnershipFirstView(
                familyName: familyStore.myFamily?.name ?? "",
                otherMembersCount: otherMembersCount
            )
        }
    }

    private var otherMembersCount: Int {
        guard let myUserID else { return max(0, familyStore.members.count - 1) }
        return familyStore.members.filter { $0.userID != myUserID }.count
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("家庭成員")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            // R2（merge-review R1 M6）：稿三板一致帶人數「「陳家」目前有 4 位家人。」，原本
            // 漏了成員數。
            Text("「\(familyStore.myFamily?.name ?? "")」目前有 \(familyStore.members.count) 位家人。")
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
    /// 文件註解；伺服器 `LS057`／`LS001` 才是最終裁決，`LeaveFamilyConfirmSheet` 送出後若仍
    /// 撞到（極端併發窗口，例如共同 owner 幾乎同時退出，或唯一 owner 兼唯一成員被 03d 誤判），
    /// 用 `AppError.familyMemberActionMessage` 顯示對應文案，不會誤判成功（B1）。
    private func startLeaveFlow() {
        if familyStore.mustTransferOwnershipBeforeLeaving {
            showsMustTransferFirst = true
        } else {
            showsLeaveConfirmation = true
        }
    }
}

/// 03 成員列——頭像（48×48，同稿 `cmp/Child Avatar` 尺寸，R2 修正原本誤用的 44）＋姓名
/// （自己那一列文字直接併入「（你）」，同稿單一文字節點，R2 修正原本拆成兩個 Text 的寫法）＋
/// `cmp/Role Pill` 角色徽章（R2 修正原本的裸 `Text`，見 `FamilyMemberActionVisibility
/// .membersListIconName` 文件註解）；Owner 檢視他人時多一顆 chevron（R2 修正原本的「…」，
/// 見本檔型別文件註解）觸發選單（轉移家庭管理者／移除成員），可見性依
/// `FamilyMember.isTransferable`／`isRemovable`。
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

    /// 稿 `hVAq3`／`gjCoe`／`yJvj7` 自己那一列的 Name 文字節點內容就是「陳美玲（你）」整串，
    /// 不是姓名＋另一個次要色文字節點（R1 誤拆成兩個 `Text`）。
    private var displayName: String {
        isMe ? "\(member.displayName)（你）" : member.displayName
    }

    var body: some View {
        HStack(spacing: AppSpacing.group) {
            ChildAvatarView(name: member.displayName, size: 48, avatarURL: avatarURL)
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                // R2（merge-review R1 m1）：AX3 長名字壓測板 `gjCoe` 的 Name 文字節點是
                // `width=fill_container`，沒有截斷——原本 `.lineLimit(1)` 拿掉，讓長名字換行、
                // 列高隨字級與內容自然長高。
                Text(displayName)
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                Pill(icon: member.role.membersListIconName, text: member.role.membersListDisplayLabel)
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
                Button("轉移家庭管理者", action: onTransfer)
            }
            if canRemove {
                Button("移出成員", role: .destructive, action: onRemove)
            }
        } label: {
            Image(systemName: "chevron.right")
                .appIconFrame(.small)
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

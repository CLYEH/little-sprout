import SwiftUI

/// 01 設定頁 root（LS-188，`design/littlesprout.pen` `t5wI4`/`Rx5mP`/`z9tytH`/`B2DckT`，依
/// LS-152 稿實作）：五區——個人／家庭／內容與安全／法律／帳號。取代 LS-17 的最小占位
/// （`ContentUnavailableView` ＋邀請家人＋登出）。
///
/// 各區入口在對應票（LS-24 家庭成員／刪除帳號、LS-23 封鎖／檢舉、LS-133 法務 in-app sheet）
/// 併入前指向占位（`ProfileEditView`／`FamilyMembersView`／`DeleteAccountFlowView`／
/// `BlockListView`／`ReportInboxView`，Notes 板約定檔名）——後續票只替換這些檔案的內容，不動
/// 這支 root（票文範圍 3）。「退出家庭」沒有另外拆一支占位檔：LS-24「多 owner 轉移」把它跟
/// 成員管理歸在同一個未來畫面，見 `FamilyMembersView` 文件註解。
///
/// 垂直置中（使用者 2026-09-05 核可 LS-152 稿的唯一意見，本票直接落地）：見
/// `SettingsRowView` 文件註解。
struct SettingsView: View {
    let authStore: AuthStore
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    /// LS-126 merge-review R1 M5：登出時歸零，同 `familyStore`／`childrenStore` 的理由——
    /// `TimelineStore` 隨 app 存活，不清掉的話，下一位在同一台裝置登入的使用者會先看到
    /// 上一個家庭殘留的時間軸（簽名 URL 1 小時內仍可讀，見該 store `reset()` 文件註解）。
    let timelineStore: TimelineStore
    /// LS-165：跟 `timelineStore` 同理，登出時歸零——相簿 tab 首頁隨 app 存活，不清掉的話
    /// 下一位在同一台裝置登入的使用者會先看到上一個家庭殘留的相簿列表。
    let albumsStore: AlbumsStore

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isSigningOut = false
    @State private var errorMessage: String?
    /// Regular（iPad）左側五區導覽選取——同 `AuthenticatedRootView` 的既有理由（selection
    /// 存在容器層而非各自子視圖），這裡範圍縮小到「這個畫面內的五區」，跟 app 層的
    /// `AppSection` selection 是兩層不同的導覽狀態，互不相干。
    @State private var regularSelection: SettingsSection = .profile

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularBody
            } else {
                compactBody
            }
        }
        // LS-188：「檢舉紀錄」列只有 Owner 看得到，判斷依據是 `childrenStore.isOwner`——那份
        // 角色目前只在 `ChildrenManagementView` 進場時才會查（`ChildrenStore.refresh
        // (familyID:)`），直接從別的分頁導覽到設定頁的使用者可能還沒查過。`myRole == nil`
        // 才補查一次：`ChildrenStore` 隨 app 存活，已經查過（不論從哪個畫面查到）就不重打
        // 一次網路。
        .task(id: familyStore.myFamily?.id) {
            guard let familyID = familyStore.myFamily?.id else { return }
            guard childrenStore.myRole == nil else { return }
            await childrenStore.refresh(familyID: familyID)
        }
        .alert(
            "登出失敗",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            presenting: errorMessage
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Compact（iPhone，`t5wI4`/`Rx5mP`/`z9tytH`）

    private var compactBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(spacing: AppSpacing.block) {
                    profileSection
                    if familyStore.myFamily != nil {
                        familySection
                    }
                    contentSafetySection
                    legalSection
                    accountSection
                }
                .padding(.top, AppSpacing.section)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, 8)
            .padding(.bottom, AppSpacing.block)
        }
        .background(Color.lsBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("設定")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text(headerSubtitle)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var headerSubtitle: String {
        guard let name = familyStore.myFamily?.name else { return "你的帳號與家庭設定都在這裡。" }
        return "「\(name)」的帳號與家庭設定都在這裡。"
    }

    // MARK: - Regular（iPad，`B2DckT`）
    //
    // 稿面 `B2DckT` 畫的是「設定」自己的 sidebar＋detail 兩欄，但 app 層在 regular 寬度已經有
    // 一層 `SectionSplitView`（`RootView.swift`：時間軸／相簿／寶貝／設定四個 tab 的 sidebar）
    // ——`SettingsView` 本身是那層 detail 欄裡的內容，不是整個畫面。這裡在自己的內容區域內
    // 再開一層五區 `NavigationSplitView`，還原稿面「選一區、右邊出現對應內容」的操作方式；
    // 兩層 sidebar 疊起來的實際可用寬度比稿面單獨畫的 834pt 版心窄，是本票已知的稿面↔既有
    // 導覽架構落差，記入 handoff「未完成」——不動 `RootView` 的既有四分頁架構（那是本票範圍
    // 之外的改動）。
    private var regularBody: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: sidebarSelection) { section in
                sidebarRow(section)
            }
            .navigationTitle("設定")
        } detail: {
            ScrollView {
                sectionContent(for: regularSelection)
                    .padding(AppSpacing.screenPad)
            }
            .background(Color.lsBackground)
            .navigationTitle(regularSelection.title)
        }
    }

    /// `List` 的單選 API 只接受 optional binding；取消選取（nil）時保持原區塊，同
    /// `SectionSplitView.sidebarSelection` 的既有寫法。
    private var sidebarSelection: Binding<SettingsSection?> {
        Binding(get: { regularSelection }, set: { regularSelection = $0 ?? regularSelection })
    }

    /// 稿面 `B2DckT` Nav Item：選中＝`$print-paper` 底、`$print-ink` icon／文字；未選中＝
    /// 透明底、`$text-secondary` icon、`$text-primary` 文字。
    private func sidebarRow(_ section: SettingsSection) -> some View {
        let isSelected = section == regularSelection
        return HStack(spacing: AppSpacing.group) {
            Image(systemName: section.icon)
                .appIconFrame(.medium)
                .foregroundStyle(isSelected ? Color.lsPrintInk : Color.lsTextSecondary)
            Text(section.title)
                .appFont(.body)
                .foregroundStyle(isSelected ? Color.lsPrintInk : Color.lsTextPrimary)
        }
        .padding(.vertical, AppSpacing.tight)
        .listRowBackground(isSelected ? Color.lsPrintPaper : Color.clear)
    }

    @ViewBuilder
    private func sectionContent(for section: SettingsSection) -> some View {
        switch section {
        case .profile:
            profileSection
        case .family:
            if familyStore.myFamily != nil {
                familySection
            }
        case .contentSafety:
            contentSafetySection
        case .legal:
            legalSection
        case .account:
            accountSection
        }
    }

    // MARK: - 個人

    private var profileSection: some View {
        SettingsSectionBlock(title: "個人") {
            NavigationLink {
                ProfileEditView()
            } label: {
                ProfileSummaryRow(displayName: displayName)
            }
            // LS-188：垂直置中 UITest 用（多行副標樣本）——整列合併成一顆 button，label 會
            // 隨姓名變，同 `QAAccessibilityID.timelineDiaryCard` 的既有理由。
            .accessibilityIdentifier(QAAccessibilityID.settingsProfileRow)
        }
    }

    /// LS-188：`profiles.display_name` 沒有任何既有讀取路徑（該表目前只在建立家庭時被寫入一次
    /// ，見 `SupabaseFamilyAPIClient.ensureProfileExists`），新增一支「讀自己 profile」的
    /// client／RPC 屬於 02 顯示名稱編輯頁（LS-152 另票）的範圍，不是這張 root 票要做的事
    /// （本票的後端範圍限定在既有 `get_family_quota`，見票文環境段）。這裡先用登入 email
    /// 本地部分當顯示名稱（同 `ensureProfileExists` 建立 profiles 列時的預設值推導邏輯），
    /// 02 頁落地後這裡應該改讀真正的 `profiles.display_name`——記入 handoff「未完成」。
    private var displayName: String {
        EmailDisplayName.derive(fromEmail: authStore.session?.email) ?? "我"
    }

    // MARK: - 家庭

    private var familySection: some View {
        SettingsSectionBlock(title: "家庭") {
            // LS-188：稿面「家庭成員」列的「N 位」摘要需要新的成員清單/計數查詢——同「個人」
            // 列的理由，屬於 LS-24（家庭成員管理）票的範圍，不在這張 root 票新增後端呼叫。
            NavigationLink {
                FamilyMembersView()
            } label: {
                SettingsRowView(icon: "person.2.fill", label: "家庭成員")
            }
            SettingsRowDivider()
            // LS-107：07 邀請家人本身有 LS-46 核可的設計稿，這顆列只是導航入口，沿用既有
            // 畫面，不需要另外走設計 gate。
            NavigationLink {
                InviteFamilyView(familyStore: familyStore)
            } label: {
                SettingsRowView(icon: "person.badge.plus", label: "邀請家人")
            }
            // LS-188：垂直置中 UITest 用（單行列樣本）。
            .accessibilityIdentifier(QAAccessibilityID.settingsInviteRow)
            SettingsRowDivider()
            NavigationLink {
                FamilyMembersView()
            } label: {
                SettingsRowView(icon: "door.left.hand.open", label: "退出家庭")
            }
        }
    }

    // MARK: - 內容與安全

    /// 列組成（含「檢舉紀錄」是否顯示）交給 `SettingsContentSafetyComposition.rows(isOwner:)`
    /// 判斷——那支是純函式，XCTest 直接覆蓋，這裡只負責依清單把對應的列畫出來。
    private var contentSafetySection: some View {
        SettingsSectionBlock(title: "內容與安全") {
            let rows = SettingsContentSafetyComposition.rows(isOwner: childrenStore.isOwner)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    SettingsRowDivider()
                }
                contentSafetyRow(row)
            }
        }
    }

    @ViewBuilder
    private func contentSafetyRow(_ row: SettingsContentSafetyRow) -> some View {
        switch row {
        case .blockList:
            NavigationLink {
                BlockListView()
            } label: {
                SettingsRowView(icon: "person.fill.xmark", label: "封鎖名單")
            }
        case .reportInbox:
            NavigationLink {
                ReportInboxView()
            } label: {
                SettingsRowView(icon: "flag.fill", label: "檢舉紀錄")
            }
        case .storage:
            NavigationLink {
                StorageUsageView(familyStore: familyStore)
            } label: {
                SettingsRowView(icon: "internaldrive", label: "儲存空間")
            }
        }
    }

    // MARK: - 法律

    private var legalSection: some View {
        SettingsSectionBlock(title: "法律") {
            // 待辦（LS-133 核可後）：改開 in-app sheet，不再跳出系統瀏覽器。這裡先沿用
            // `WelcomeView.legalAttributedString` 既有的兩個網址（票文範圍 1：「法律入口沿用
            // 既有開啟方式」）。
            Link(destination: URL(string: "https://littlesprout.app/legal/terms")!) {
                SettingsRowView(icon: "doc.text", label: "使用條款")
            }
            SettingsRowDivider()
            Link(destination: URL(string: "https://littlesprout.app/legal/privacy")!) {
                SettingsRowView(icon: "shield", label: "隱私權政策")
            }
        }
    }

    // MARK: - 帳號

    private var accountSection: some View {
        SettingsSectionBlock(title: "帳號") {
            // LS-17 QA1：`SettingsRowView` 的 `.frame(minHeight: 44)` 已經滿足長輩硬約束
            // ≥44pt 點擊目標，不需要再另外加不可見 padding（舊版占位頁的作法，見這支檔案的
            // git 歷史）。
            Button(action: signOut) {
                SettingsRowView(icon: "rectangle.portrait.and.arrow.right", label: "登出", showsChevron: false)
            }
            .disabled(isSigningOut)
            SettingsRowDivider()
            NavigationLink {
                DeleteAccountFlowView()
            } label: {
                SettingsRowView(icon: "trash", label: "刪除帳號", isDestructive: true)
            }
        }
    }

    private func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            defer { isSigningOut = false }
            do {
                try await authStore.signOut()
                // R2 N5：`AuthenticatedGate`（含它的 `.task(id:)`）在登出當下整個從畫面樹被
                // 移除，只會被取消、不會以 nil 重跑一次——`FamilyStore.reset()` 因此需要一個
                // 真的會被呼叫到的入口，這裡是登出成功後唯一一個。沒有這行，`myFamily`／
                // `latestInvite` 會在記憶體裡留到下一位使用者登入前（見 `FamilyStore.reset()`
                // 文件註解／`syncOwner` 對「同一人重登入不重查」以外情境的假設）。
                familyStore.reset()
                // LS-113：`ChildrenStore` 隨 app 存活，同 `FamilyStore` 的理由——登出不清掉
                // 的話，下一位在同一台裝置登入的使用者會沿用上一位的孩子清單。
                childrenStore.reset()
                // LS-126 merge-review R1 M5：見上方 `timelineStore` 屬性文件註解。
                timelineStore.reset()
                // LS-165：見上方 `albumsStore` 屬性文件註解。
                albumsStore.reset()
            } catch {
                errorMessage = AppError.map(error).userFacingMessage
            }
        }
    }
}

#if DEBUG
#Preview("Compact") {
    NavigationStack {
        SettingsView(
            authStore: .preview(),
            familyStore: .preview(withFamily: Family(
                id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
            )),
            childrenStore: .preview(), timelineStore: .preview(),
            albumsStore: .preview()
        )
    }
}

#Preview("Regular") {
    NavigationStack {
        SettingsView(
            authStore: .preview(),
            familyStore: .preview(withFamily: Family(
                id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
            )),
            childrenStore: .preview(), timelineStore: .preview(),
            albumsStore: .preview()
        )
    }
    .environment(\.horizontalSizeClass, .regular)
}
#endif

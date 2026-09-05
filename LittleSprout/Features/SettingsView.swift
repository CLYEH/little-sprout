import SwiftUI

/// Placeholder：設定（家庭管理、成員、帳號）。
///
/// 登出鈕是本畫面目前唯一可用的動作（LS-17 R2 review N7）：家庭管理／成員邀請等其餘功能仍是
/// 占位，但完全沒有登出入口，QA 在 test branch 驗收時要重測 Email OTP 只能刪 app 重裝——
/// `AuthStore.signOut()` 已實作並測過，成本很低，先接上這一顆。
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

    @State private var isSigningOut = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            // `ContentUnavailableView(label:description:actions:)` 的 actions 插槽在本畫面的
            // 容器組合下（`RootView → AuthenticatedRootView → SectionTabView →
            // SectionContentView`）確實會渲染（R2 handoff 原先寫「完全不渲染」不夠精確，
            // R3 review B6 指出後重新量測更正）；但實測與 description 只隔約 20pt，視覺上
            // 像 description 段落的延伸而非獨立動作（`.claude/evidence/LS-17/r3/
            // b6-settings-before-production-hierarchy.png`，iPhone 17 Pro／iOS 26.0.1）。
            // 改用手排版面後，`ContentUnavailableView` 只剩 label/description 兩段、不再
            // 用 `.frame(maxHeight: .infinity)` 把整個 VStack 撐滿，登出鈕因此落在畫面下段、
            // 與說明文字明顯分開（同目錄 `b6-settings-after-production-hierarchy.png`）。
            ContentUnavailableView {
                Label("設定", systemImage: "gearshape")
            } description: {
                Text("家庭管理與帳號設定會顯示在這裡。")
            }
            // LS-107：這個畫面原本的 description 就寫著「成員邀請會顯示在這裡」——這裡填上
            // 那個承諾，不是新畫面（07 邀請家人本身有 LS-46 核可的設計稿，這顆列只是導航
            // 入口，沿用既有列樣式，不需要另外走設計 gate）。只有已經有家庭才顯示：還在三岔路
            // 階段的使用者不會看到這顆設定分頁。
            if familyStore.myFamily != nil {
                NavigationLink {
                    InviteFamilyView(familyStore: familyStore)
                } label: {
                    HStack {
                        Label("邀請家人", systemImage: "person.badge.plus")
                            .appFont(.body)
                            .foregroundStyle(Color.lsTextPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Color.lsTextSecondary)
                    }
                    .padding(.vertical, AppSpacing.item)
                    .padding(.horizontal, AppSpacing.item)
                    .contentShape(Rectangle())
                }
            }
            // LS-17 QA1：原 `Button("登出", role: .destructive, action: signOut)` 實測
            // 32×19pt，違反長輩硬約束 ≥44pt 點擊目標。改用 label closure 加不可見 padding
            // 撐大點擊區，視覺仍是純文字紅字、不加框、不改樣式。
            Button(role: .destructive, action: signOut) {
                Text("登出")
                    .padding(.vertical, AppSpacing.item)
                    .padding(.horizontal, AppSpacing.item)
                    .contentShape(Rectangle())
            }
            .disabled(isSigningOut)
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
#Preview {
    NavigationStack {
        SettingsView(
            authStore: .preview(), familyStore: .preview(), childrenStore: .preview(), timelineStore: .preview(),
            albumsStore: .preview()
        )
    }
}
#endif

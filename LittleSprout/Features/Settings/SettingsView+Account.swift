import SwiftUI

/// `SettingsView` 拆分出的「帳號」區（登出／刪除帳號）——`SettingsView.swift` 加完 LS-193
/// `accountAPIClient` 佈線後逼近 SwiftLint `file_length` 上限（同 `SettingsView+Profile.swift`
/// 檔頭「五區內容後超過上限」的既有理由）。`isSigningOut`／`errorMessage` 在主檔已改成非
/// `private`（同 `regularSelection` 的既有作法），這裡才讀寫得到。
extension SettingsView {
    // MARK: - 帳號

    var accountSection: some View {
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
                DeleteAccountFlowView(
                    accountAPIClient: accountAPIClient, authStore: authStore, familyStore: familyStore,
                    childrenStore: childrenStore, timelineStore: timelineStore, albumsStore: albumsStore
                )
            } label: {
                SettingsRowView(icon: "trash", label: "刪除帳號", isDestructive: true)
            }
        }
    }

    func signOut() {
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

import SwiftUI

/// `SettingsView` 的登出收尾，從 `SettingsView.swift` 拆出獨立檔案（merge-review R2 B3）——
/// `SettingsView.swift` 與 `FamilyStore.swift` 同一天各自被兩張票（本票／LS-210）疊加壓到
/// SwiftLint `file_length` 400 行上限，理由同 `SettingsView+Sidebar.swift`／
/// `SettingsView+Profile.swift` 從主檔拆分的既有先例。純搬移，不改行為：`isSigningOut`／
/// `errorMessage` 因此不再標 `private`（跨檔案 extension 存取不到，見兩個屬性宣告處）。
extension SettingsView {
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
                // LS-190 R2：見上方 `eulaStore` 屬性文件註解。
                eulaStore.reset()
            } catch {
                errorMessage = AppError.map(error).userFacingMessage
            }
        }
    }
}

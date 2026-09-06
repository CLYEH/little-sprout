import SwiftUI

/// `SettingsView` 的「帳號」區，從 `SettingsView.swift` 拆出獨立檔案——merge-review R2 B2
/// 需要新增 `resumer` 屬性／參數，逼近 SwiftLint `file_length` 400 上限（R2 review i1 已提醒
/// 只剩 9 行餘裕），理由同 `SettingsView+SignOut.swift`／`SettingsView+Sidebar.swift`／
/// `SettingsView+Profile.swift` 從主檔拆分的既有先例。
extension SettingsView {
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
            // LS-193：接上真正的刪除帳號流程，取代 LS-188 佔位。
            NavigationLink {
                DeleteAccountFlowView(
                    accountAPIClient: accountAPIClient, authStore: authStore, familyStore: familyStore,
                    childrenStore: childrenStore, timelineStore: timelineStore, albumsStore: albumsStore,
                    eulaStore: eulaStore, resumer: resumer
                )
            } label: {
                SettingsRowView(icon: "trash", label: "刪除帳號", isDestructive: true)
            }
        }
    }
}

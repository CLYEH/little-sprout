import SwiftUI

/// `SettingsView.compactBody` 的自畫標題（`header`／`headerSubtitle`）——拆到這支 extension 檔
/// 的理由同 `SettingsView+Account.swift`／`SettingsView+Profile.swift` 既有先例：
/// `SettingsView.swift` 本身已經是 SwiftLint `file_length`（400）上限，搬出這兩個成員才有空間
/// 讓 `compactBody` 恢復一行一 modifier（LS-344 R2，merge-review R1 i2）。不標 `private`：
/// 跨檔案 extension 存取不到（同 `regularSelection` 屬性宣告處的既有理由）。
extension SettingsView {
    var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("設定")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                // LS-344：系統 nav bar 隱藏後，這是唯一的 heading 訊號來源（同
                // `TimelineView`／`AlbumsView`／`ChildrenManagementView` 既有理由）。
                .accessibilityAddTraits(.isHeader)
            Text(headerSubtitle)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    var headerSubtitle: String {
        guard let name = familyStore.myFamily?.name else { return "你的帳號與家庭設定都在這裡。" }
        return "「\(name)」的帳號與家庭設定都在這裡。"
    }
}

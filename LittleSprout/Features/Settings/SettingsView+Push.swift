import SwiftUI
import UIKit

/// `SettingsView` 拆分出的「推播通知」列（LS-217，稿面 `y7KAW`／`y66AzT` `DVEow`）——理由同
/// `SettingsView+Account.swift`／`SettingsView+Profile.swift` 從 `SettingsView.swift` 拆分的
/// 既有先例：加完這段內容後那支檔案超過 SwiftLint `file_length`／`type_body_length` 上限。
/// `SettingsView` 是這幾支方法目前唯一的呼叫端，因此不再標 `private`（跨檔案 extension 需要
/// 讀寫 `presentsPushPreprompt`／`showsPushDeniedAlert`／`showsPushDisableConfirm`，見該檔
/// 屬性宣告處的既有理由）。
extension SettingsView {
    /// 整列可點（Notes `UU5Rm`：Toggle 只是視覺，`SettingsRowView.toggleIsOn` 不接手勢）；
    /// 三態行為交給 `handlePushRowTapped()`，本身不含任何分支邏輯（票文範圍 3）。
    var pushRow: some View {
        Button(action: handlePushRowTapped) {
            SettingsRowView(
                icon: "bell", label: "推播通知",
                value: SettingsPushRowComposition.valueText(for: pushNotificationStore.authorizationStatus),
                showsChevron: false,
                toggleIsOn: SettingsPushRowComposition.isOn(for: pushNotificationStore.authorizationStatus)
            )
        }
        .accessibilityIdentifier(QAAccessibilityID.settingsPushRow)
        .fullScreenCover(isPresented: $presentsPushPreprompt) {
            PushPrepromptView(pushNotificationStore: pushNotificationStore) {
                presentsPushPreprompt = false
            }
        }
        // `.denied` 態——導系統設定（票文範圍 3）。
        .alert("要開啟推播通知嗎？", isPresented: $showsPushDeniedAlert) {
            Button("前往設定", action: openSystemNotificationSettings)
            Button("取消", role: .cancel) {}
        }
        // 已授權態切關——定案文案見 Handoff Notes `Z7vNe`。
        .alert("要關閉推播通知嗎？", isPresented: $showsPushDisableConfirm) {
            Button("前往設定", action: openSystemNotificationSettings)
            Button("取消", role: .cancel) {}
        } message: {
            Text("這需要在「設定」App 裡調整通知權限。")
        }
    }

    /// 狀態來源＝`UNAuthorizationStatus`（票文範圍 3）：`.notDetermined` 走前置頁流程；
    /// `.denied` 走「要開啟…」alert；已授權（含 `.provisional`／`.ephemeral`，見
    /// `SettingsPushRowComposition`）走「要關閉…」確認。
    func handlePushRowTapped() {
        switch pushNotificationStore.authorizationStatus {
        case .notDetermined:
            presentsPushPreprompt = true
        case .denied:
            showsPushDeniedAlert = true
        case .authorized, .provisional, .ephemeral:
            showsPushDisableConfirm = true
        @unknown default:
            showsPushDeniedAlert = true
        }
    }

    /// iOS 無法讓 App 直接改自己的通知權限，兩顆「前往設定」alert 鈕共用同一個導覽動作
    /// （票文範圍 3：`openNotificationSettingsURLString`）。
    func openSystemNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

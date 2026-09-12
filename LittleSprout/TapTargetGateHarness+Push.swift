#if DEBUG
import SwiftUI

/// LS-217：推播權限前置說明頁與設定頁「推播通知」列的三態 host，從 `TapTargetGateHarness.swift`
/// 拆出獨立檔案——同 `TapTargetGateHarness+Settings.swift`／`+Safety.swift` 從主檔拆分的既有
/// 先例（避免那支檔案再度超過 SwiftLint `file_length` 上限）。
extension TapTargetGateHarness {
    /// 推播權限前置說明頁（`design/littlesprout.pen` `j7WwV`）——初始態不需要任何 seed 資料，
    /// `PushNotificationStore.preview()` 預設 `.notDetermined`（同 `.createChild` 等既有先例：
    /// `.preview()` 系列本身就能免登入建構出有代表性的畫面）。
    @MainActor
    @ViewBuilder
    static var pushPrepromptHost: some View {
        PushPrepromptView(pushNotificationStore: .preview(), onFinish: {})
    }

    /// 設定頁「推播通知」列——`.denied` 態，`SettingsPushRowUITests` 用來斷言 value 文案
    /// 「關閉」與點擊後的「要開啟推播通知嗎？」alert（票文範圍 3）。同 `settingsHost` 的
    /// 既有結構，只換 `pushNotificationStore`。
    @MainActor
    @ViewBuilder
    static var settingsPushDeniedHost: some View {
        NavigationStack {
            SettingsView(
                authStore: .preview(),
                familyStore: settingsFamilyStore(withFamily: Family(
                    id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                childrenStore: .preview(), accountAPIClient: PreviewAccountAPIClient(),
                timelineStore: .preview(),
                albumsStore: .preview(),
                eulaStore: .preview(shouldPresent: false), resumer: .preview(),
                safetyAPIClient: PreviewSafetyAPIClient(),
                pushNotificationStore: .preview(authorizationStatus: .denied)
            )
        }
        .environment(\.horizontalSizeClass, .compact)
    }

    /// 同上，`.authorized` 態——`SettingsPushRowUITests` 斷言 value 文案「開啟」與點擊後的
    /// 「要關閉推播通知嗎？」確認（Notes `Z7vNe` 定案文案）。
    @MainActor
    @ViewBuilder
    static var settingsPushAuthorizedHost: some View {
        NavigationStack {
            SettingsView(
                authStore: .preview(),
                familyStore: settingsFamilyStore(withFamily: Family(
                    id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                childrenStore: .preview(), accountAPIClient: PreviewAccountAPIClient(),
                timelineStore: .preview(),
                albumsStore: .preview(),
                eulaStore: .preview(shouldPresent: false), resumer: .preview(),
                safetyAPIClient: PreviewSafetyAPIClient(),
                pushNotificationStore: .preview(authorizationStatus: .authorized)
            )
        }
        .environment(\.horizontalSizeClass, .compact)
    }
}
#endif

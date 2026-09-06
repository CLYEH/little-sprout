#if DEBUG
import Foundation
import UserNotifications

/// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用的假 `PushAuthorizationService`——不會
/// 真的跳系統對話框（同 `PreviewSafetyAPIClient` 的角色，見該檔）。生產路徑一律用
/// `SystemPushAuthorizationService`。
private struct PreviewPushAuthorizationService: PushAuthorizationService {
    let status: UNAuthorizationStatus

    func currentAuthorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool { status == .authorized }
}

/// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用的假 `PushDeviceTokenAPIClient`——不打真
/// 網路、不需要 `Config/Secrets.xcconfig`。生產路徑一律用 `SupabasePushDeviceTokenAPIClient`。
private struct PreviewPushDeviceTokenAPIClient: PushDeviceTokenAPIClient {
    func registerDeviceToken(token: String, platform: String) async throws {}
}

extension PushNotificationStore {
    /// `TapTargetGateHarness.pushPrepromptHost`／`SettingsView` 的 `#Preview` 用：同步灌
    /// `authorizationStatus`，不需要真的登入或系統權限環境即可渲染出有代表性的畫面
    /// （同 `EULAStore.preview(shouldPresent:)` 的既有理由）。
    @MainActor
    static func preview(authorizationStatus: UNAuthorizationStatus = .notDetermined) -> PushNotificationStore {
        let store = PushNotificationStore(
            authorizationService: PreviewPushAuthorizationService(status: authorizationStatus),
            deviceTokenAPIClient: PreviewPushDeviceTokenAPIClient()
        )
        store.seedForPreview(authorizationStatus: authorizationStatus)
        return store
    }
}
#endif

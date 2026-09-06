import Foundation
import Observation
import UIKit
import UserNotifications

/// 推播權限與裝置 token 註冊（LS-217）的 `@Observable` 狀態管理——同 `EULAStore` 之於
/// `EULAAPIClient` 的角色：把 `PushAuthorizationService`／`PushDeviceTokenAPIClient` 包成
/// `AuthenticatedRootView`／`SettingsView` 能直接讀狀態驅動重繪的 store，隨 app 存活
/// （`LittleSproutApp` 建一次，見該檔文件註解）。
@MainActor
@Observable
final class PushNotificationStore {
    private let authorizationService: PushAuthorizationService
    private let deviceTokenAPIClient: PushDeviceTokenAPIClient

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// `AuthenticatedRootView` 的 `.fullScreenCover(isPresented:)` 綁這個——同
    /// `FamilyStore.showsChildOnboarding` 既有的「store 算好要不要顯示、View 只負責綁定」分工
    /// （見該屬性文件註解）。
    private(set) var showsPreprompt = false

    init(authorizationService: PushAuthorizationService, deviceTokenAPIClient: PushDeviceTokenAPIClient) {
        self.authorizationService = authorizationService
        self.deviceTokenAPIClient = deviceTokenAPIClient
    }

    /// `AuthenticatedRootView` 的 `.task(id: authStore.session?.userID)` 呼叫——查目前系統
    /// 授權狀態，並依 `PushPrepromptPolicy` 判斷「登入後首次進時間軸」是否該自動顯示前置頁
    /// （票文範圍 1）。
    func refreshForEnteringApp(userID: UUID) async {
        authorizationStatus = await authorizationService.currentAuthorizationStatus()
        showsPreprompt = PushPrepromptPolicy.shouldPresent(
            authorizationStatus: authorizationStatus,
            hasShownBefore: PushPrepromptDisplayRecord.hasShown(userID: userID)
        )
    }

    /// 每次 App 進前景重讀狀態（票文範圍 2）——不影響 `showsPreprompt`（前置頁只在「登入後
    /// 首次進場」判斷一次，見 `refreshForEnteringApp`）；已授權時重新呼叫
    /// `registerForRemoteNotifications()`，讓系統再送一次 `didRegisterForRemoteNotifications
    /// WithDeviceToken`——去重邏輯在 `submitTokenIfNeeded` 那一層，這裡只負責觸發。
    func refreshOnForeground(userID: UUID) async {
        authorizationStatus = await authorizationService.currentAuthorizationStatus()
        guard authorizationStatus == .authorized else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// 前置頁關閉（不論是「開啟通知」或「稍後再說」）——標記這個使用者已經看過，
    /// `refreshForEnteringApp` 之後不會再自動顯示。
    func dismissPreprompt(userID: UUID) {
        showsPreprompt = false
        PushPrepromptDisplayRecord.markShown(userID: userID)
    }

    /// 前置頁 CTA「開啟通知」／設定頁列 `.notDetermined` 態走的「第 1 項流程」共用——跳系統
    /// 對話框，允許就呼叫 `registerForRemoteNotifications()`（票文範圍 2）。
    @discardableResult
    func requestAuthorizationAndRegister() async -> Bool {
        do {
            let granted = try await authorizationService.requestAuthorization()
            authorizationStatus = granted ? .authorized : .denied
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return granted
        } catch {
            // 註冊失敗記 log 不擋 UI（票文範圍 2）。
            didFailToRegister(error: error)
            return false
        }
    }

    /// `AppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` 轉呼叫
    /// ——hex 化 token 後交給 `submitTokenIfNeeded` 判斷要不要送。
    func didRegister(deviceToken: Data, userID: UUID) async {
        await submitTokenIfNeeded(Self.hexString(from: deviceToken), userID: userID)
    }

    /// `AppDelegate.application(_:didFailToRegisterForRemoteNotificationsWithError:)` 轉呼叫
    /// ——票文範圍 2「註冊失敗記 log 不擋 UI」，不改變任何 store 狀態。
    func didFailToRegister(error: Error) {
        #if DEBUG
        print("LS-217 push registerForRemoteNotifications 失敗：\(error)")
        #endif
    }

    /// 去重核心：同一個 (userID, tokenHex) 只送一次 `register_device_token`；RPC 失敗時不標記
    /// 已送出，讓下一次觸發（下次前景／下次登入）自然重試——同時滿足「註冊失敗記 log 不擋 UI」
    /// 與「不會因為一次失敗就永久放棄」兩個要求。不是 `private`：單元測試需要直接呼叫，跳過
    /// `didRegister` 內部才需要的 `Task` 包裝（見該方法）。
    func submitTokenIfNeeded(_ tokenHex: String, userID: UUID) async {
        guard PushDeviceTokenSubmissionRecord.lastSubmittedTokenHex(userID: userID) != tokenHex else { return }
        do {
            try await deviceTokenAPIClient.registerDeviceToken(token: tokenHex, platform: "ios")
            PushDeviceTokenSubmissionRecord.markSubmitted(tokenHex, userID: userID)
        } catch {
            didFailToRegister(error: error)
        }
    }

    static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
    /// `TapTargetGateHarness`／`#Preview` 用：同步灌狀態，不經過 async 查詢——同
    /// `EULAStore.seedForPreview` 的既有理由（見該檔）。整支 `#if DEBUG` 圍住，Release build
    /// 不會編到。
    func seedForPreview(authorizationStatus: UNAuthorizationStatus) {
        self.authorizationStatus = authorizationStatus
    }
    #endif
}

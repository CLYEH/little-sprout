import UIKit

/// LS-217：`UIApplicationDelegateAdaptor` 橋接——SwiftUI `App` 沒有原生管道能收
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`／`application(_:
/// didFailToRegisterForRemoteNotificationsWithError:)` 這兩個 UIKit-only 回呼，這是唯一能接住
/// APNs device token／註冊失敗事件的地方（Apple 官方建議寫法：SwiftUI `App` +
/// `UIApplicationDelegateAdaptor`）。
///
/// `authStore`／`pushNotificationStore` 由 `LittleSproutApp.init()` 在兩者都建立完成之後立刻
/// 指派（同一個 app 生命週期只建一次，見該檔文件註解）——`UIApplicationDelegateAdaptor` 保證
/// `AppDelegate` 實例的建立早於 `LittleSproutApp.body` 求值，但比 `init()` 裡其餘 `@State`
/// 屬性初始化的時機更早，因此不能用 initializer 注入，只能用「建立後賦值」這個常見模式。
/// `authStore` 用來在 device token 真的送達時讀「當下」的登入者（`session?.userID`）——不是
/// 快取某個時間點的 userID，換帳號後這個回呼若剛好又觸發一次，讀到的一定是新的登入者。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    var authStore: AuthStore?
    var pushNotificationStore: PushNotificationStore?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard let pushNotificationStore, let userID = authStore?.session?.userID else { return }
        Task { await pushNotificationStore.didRegister(deviceToken: deviceToken, userID: userID) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        pushNotificationStore?.didFailToRegister(error: error)
    }
}

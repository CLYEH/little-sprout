import Foundation
@testable import LittleSprout
import XCTest

/// merge-review R1（PR #352 comment `a208172b`）M1／m1／m2／i5 的回歸測試——`PushNotification
/// StoreTests.swift` 加完這批之後超過 SwiftLint `type_body_length`（250 行），拆成獨立檔案純粹
/// 是為了過 gate（同 `FamilyStoreInviteRaceTests.swift` 的既有拆檔理由），兩者共用同一份
/// `StubPushAuthorizationService`／`StubPushDeviceTokenAPIClient`／`AsyncGate`。
///
/// 主題是「`registerForRemoteNotifications()` 什麼時候會被呼叫」——`PushNotificationStoreTests`
/// 那邊測的是 `submitTokenIfNeeded` 的去重／重試邏輯本身，這裡測的是三個觸發點
/// （`refreshForEnteringApp`／`refreshOnForeground`／`requestAuthorizationAndRegister`）
/// 有沒有真的在該觸發的時機呼叫協定方法，加上 m1 的併發去重回歸測試。
@MainActor
final class PushNotificationStoreRegistrationTests: XCTestCase {
    // MARK: - m1：submitTokenIfNeeded 併發去重

    /// `AppDelegate` 每次 `didRegisterForRemoteNotificationsWithDeviceToken` 都開一個新 `Task`
    /// ——連續兩次回呼在去重 guard 通過後、`markSubmitted` 之前互相追上時，修法前會各自把
    /// RPC 都送出去。用 `gate.waitForWaiters(count:)` 當同步點（同 `EULAStoreTests` 既有模式，
    /// 見該檔）：第一次呼叫真的卡進 RPC 的 in-flight 區段之後，才讓第二次呼叫進場。
    func testSubmitTokenIfNeeded_concurrentCallsSameTokenAndUser_onlyRegistersOnce() async {
        let userID = UUID()
        defer { PushDeviceTokenSubmissionRecord.reset(userID: userID) }
        let deviceTokenClient = StubPushDeviceTokenAPIClient()
        let gate = AsyncGate()
        deviceTokenClient.setRegisterHandler { _, _ in await gate.wait() }
        let store = PushNotificationStore(
            authorizationService: StubPushAuthorizationService(), deviceTokenAPIClient: deviceTokenClient
        )

        let task1 = Task { await store.submitTokenIfNeeded("concurrent-token", userID: userID) }
        await gate.waitForWaiters(count: 1)

        // 第二次呼叫應該被 in-flight guard 立刻擋掉，不再送一次 RPC（也不會卡在 gate 上）。
        let task2 = Task { await store.submitTokenIfNeeded("concurrent-token", userID: userID) }

        await gate.open()
        await task1.value
        await task2.value

        XCTAssertEqual(
            deviceTokenClient.registerCallCount, 1, "同一個 (userID, tokenHex) 併發呼叫只該送一次 RPC"
        )
    }

    // MARK: - M1：refreshForEnteringApp 冷啟動／換帳號必須重新註冊

    /// merge-review R1 M1（失敗情境 a）：冷啟動只跑 `refreshForEnteringApp`，`onChange(of:
    /// scenePhase)` 的 `.active` 分支（`refreshOnForeground`）不會被觸發（SwiftUI `onChange`
    /// 不對初始值觸發）——已授權時這條路徑必須自己呼叫 `registerForRemoteNotifications()`，
    /// 否則系統輪替 token 後永遠不會重新拿到、也不會重送 `register_device_token`。
    func testRefreshForEnteringApp_authorized_registersForRemoteNotifications() async {
        let userID = UUID()
        defer { PushPrepromptDisplayRecord.reset(userID: userID) }
        let authService = StubPushAuthorizationService(status: .authorized)
        let store = PushNotificationStore(
            authorizationService: authService, deviceTokenAPIClient: StubPushDeviceTokenAPIClient()
        )

        await store.refreshForEnteringApp(userID: userID)

        XCTAssertEqual(
            authService.registerForRemoteNotificationsCallCount, 1,
            "冷啟動已授權時應該呼叫 registerForRemoteNotifications，讓系統重新送出/確認裝置 token"
        )
    }

    /// merge-review R1 M1（失敗情境 b，`docs/API.md:767-770` 明講的跨帳號外洩）：A 登出、B 在
    /// 同一個 app 行程立刻登入（`scenePhase` 不變動，只有 `.task(id: authStore.session?.userID)`
    /// 的 `id` 換了）——`refreshForEnteringApp` 必須重新觸發註冊，系統才會再送一次
    /// `didRegister` 回呼把這支裝置（同一個 token）重新關聯到 B，否則 `device_tokens` 那一列
    /// 會一直對到 A、B 使用期間持續收到 A 家庭的推播。
    func testRefreshForEnteringApp_accountSwitch_sameToken_reregistersForSecondUser() async {
        let userA = UUID()
        let userB = UUID()
        defer {
            PushPrepromptDisplayRecord.reset(userID: userA)
            PushPrepromptDisplayRecord.reset(userID: userB)
            PushDeviceTokenSubmissionRecord.reset(userID: userA)
            PushDeviceTokenSubmissionRecord.reset(userID: userB)
        }
        let authService = StubPushAuthorizationService(status: .authorized)
        let deviceTokenClient = StubPushDeviceTokenAPIClient()
        let store = PushNotificationStore(authorizationService: authService, deviceTokenAPIClient: deviceTokenClient)
        let tokenData = Data([0xDE, 0xAD, 0xBE, 0xEF])

        // A 登入：冷啟動／首次進場觸發註冊，模擬系統回呼帶 token。
        await store.refreshForEnteringApp(userID: userA)
        XCTAssertEqual(authService.registerForRemoteNotificationsCallCount, 1)
        await store.didRegister(deviceToken: tokenData, userID: userA)
        XCTAssertEqual(deviceTokenClient.registerCallCount, 1)

        // A 登出、B 立刻登入（同一支裝置、token 不變）。
        await store.refreshForEnteringApp(userID: userB)
        XCTAssertEqual(
            authService.registerForRemoteNotificationsCallCount, 2,
            "換帳號後也該重新註冊，不能只在剛授權當下呼叫一次"
        )
        await store.didRegister(deviceToken: tokenData, userID: userB)

        XCTAssertEqual(deviceTokenClient.registerCallCount, 2, "RPC 應該對兩個使用者各送一次")
        XCTAssertEqual(deviceTokenClient.registeredTokens, ["deadbeef", "deadbeef"])
        XCTAssertEqual(
            PushDeviceTokenSubmissionRecord.lastSubmittedTokenHex(userID: userB), "deadbeef",
            "第二次 RPC 是替換帳號 B 送出的，不是沿用 A 的去重記錄"
        )
    }

    // MARK: - m2：refreshForEnteringApp 被取消時不寫入過期狀態

    /// merge-review R1 m2：`.task(id:)` 換帳號時會取消舊 task，但
    /// `UNUserNotificationCenter.notificationSettings()` 不因取消提前返回——取消後才回來的結果
    /// 屬於前一位使用者查詢當下的狀態，不該再寫入 `authorizationStatus`／`showsPreprompt`。用
    /// `gate.waitForWaiters(count:)` 確保真的卡在 await 中間才取消（不是猜時間）。
    func testRefreshForEnteringApp_cancelledMidFlight_doesNotWriteStaleState() async {
        let userID = UUID()
        defer { PushPrepromptDisplayRecord.reset(userID: userID) }
        let authService = StubPushAuthorizationService(status: .notDetermined)
        let gate = AsyncGate()
        authService.setCurrentAuthorizationStatusHandler {
            await gate.wait()
            return .denied
        }
        let store = PushNotificationStore(
            authorizationService: authService, deviceTokenAPIClient: StubPushDeviceTokenAPIClient()
        )

        let task = Task { await store.refreshForEnteringApp(userID: userID) }
        await gate.waitForWaiters(count: 1)
        task.cancel()
        await gate.open()
        _ = await task.value

        XCTAssertEqual(
            store.authorizationStatus, .notDetermined,
            "task 被取消後不該再寫入查到的狀態，避免換帳號時寫入前一位使用者查到的結果"
        )
        XCTAssertFalse(store.showsPreprompt)
    }

    // MARK: - i5：refreshOnForeground／requestAuthorizationAndRegister 原本零測試覆蓋

    func testRefreshOnForeground_authorized_registersForRemoteNotifications() async {
        let userID = UUID()
        let authService = StubPushAuthorizationService(status: .authorized)
        let store = PushNotificationStore(
            authorizationService: authService, deviceTokenAPIClient: StubPushDeviceTokenAPIClient()
        )

        await store.refreshOnForeground(userID: userID)

        XCTAssertEqual(authService.registerForRemoteNotificationsCallCount, 1)
    }

    func testRefreshOnForeground_notAuthorized_doesNotRegister() async {
        let userID = UUID()
        let authService = StubPushAuthorizationService(status: .denied)
        let store = PushNotificationStore(
            authorizationService: authService, deviceTokenAPIClient: StubPushDeviceTokenAPIClient()
        )

        await store.refreshOnForeground(userID: userID)

        XCTAssertEqual(authService.registerForRemoteNotificationsCallCount, 0)
    }

    /// merge-review R1 i5：這條路徑原本直接呼叫 `UIApplication.shared`，零測試覆蓋——現在透過
    /// `PushAuthorizationService.registerForRemoteNotifications()` 可以釘住。
    func testRequestAuthorizationAndRegister_granted_registersForRemoteNotifications() async {
        let authService = StubPushAuthorizationService()
        authService.setRequestAuthorizationHandler { true }
        let store = PushNotificationStore(
            authorizationService: authService, deviceTokenAPIClient: StubPushDeviceTokenAPIClient()
        )

        _ = await store.requestAuthorizationAndRegister()

        XCTAssertEqual(authService.registerForRemoteNotificationsCallCount, 1)
    }
}

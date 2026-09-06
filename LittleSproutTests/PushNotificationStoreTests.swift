import Foundation
@testable import LittleSprout
import XCTest

/// LS-217 票文驗收：「token 變更重送去重、註冊失敗不擋」——同 `EULAStoreTests`／
/// `PendingAccountDeletionResumerTests` 既有慣例，用 `Stub*` 假 client（不打真網路／不跳系統
/// 對話框）。`userID` 用隨機 `UUID()`＋`defer` 清本機旗標，避免同機多次測試互相汙染
/// `UserDefaults.standard`。
@MainActor
final class PushNotificationStoreTests: XCTestCase {
    // MARK: - submitTokenIfNeeded 去重

    func testSubmitTokenIfNeeded_sameTokenTwice_onlyRegistersOnce() async {
        let userID = UUID()
        defer { PushDeviceTokenSubmissionRecord.reset(userID: userID) }
        let deviceTokenClient = StubPushDeviceTokenAPIClient()
        let store = PushNotificationStore(
            authorizationService: StubPushAuthorizationService(), deviceTokenAPIClient: deviceTokenClient
        )

        await store.submitTokenIfNeeded("abc123", userID: userID)
        await store.submitTokenIfNeeded("abc123", userID: userID)

        XCTAssertEqual(deviceTokenClient.registerCallCount, 1, "同一個 (userID, tokenHex) 只該送一次")
    }

    func testSubmitTokenIfNeeded_tokenChanged_registersAgain() async {
        let userID = UUID()
        defer { PushDeviceTokenSubmissionRecord.reset(userID: userID) }
        let deviceTokenClient = StubPushDeviceTokenAPIClient()
        let store = PushNotificationStore(
            authorizationService: StubPushAuthorizationService(), deviceTokenAPIClient: deviceTokenClient
        )

        await store.submitTokenIfNeeded("abc123", userID: userID)
        await store.submitTokenIfNeeded("def456", userID: userID)

        XCTAssertEqual(deviceTokenClient.registerCallCount, 2, "token 變更應該重送")
        XCTAssertEqual(deviceTokenClient.registeredTokens, ["abc123", "def456"])
    }

    /// `docs/API.md` §4 `register_device_token`：同一支裝置換帳號登入時該重新關聯——以
    /// `userID` 分 key 天然滿足這個需求，換帳號後讀到的一定是 `nil`。
    func testSubmitTokenIfNeeded_sameTokenDifferentUser_registersAgain() async {
        let userA = UUID()
        let userB = UUID()
        defer {
            PushDeviceTokenSubmissionRecord.reset(userID: userA)
            PushDeviceTokenSubmissionRecord.reset(userID: userB)
        }
        let deviceTokenClient = StubPushDeviceTokenAPIClient()
        let store = PushNotificationStore(
            authorizationService: StubPushAuthorizationService(), deviceTokenAPIClient: deviceTokenClient
        )

        await store.submitTokenIfNeeded("sametoken", userID: userA)
        await store.submitTokenIfNeeded("sametoken", userID: userB)

        XCTAssertEqual(deviceTokenClient.registerCallCount, 2, "換帳號後同一個裝置 token 也應該重送")
    }

    // MARK: - 註冊失敗不擋

    func testSubmitTokenIfNeeded_registerFails_doesNotThrowAndDoesNotMarkSubmitted() async {
        let userID = UUID()
        defer { PushDeviceTokenSubmissionRecord.reset(userID: userID) }
        let deviceTokenClient = StubPushDeviceTokenAPIClient()
        deviceTokenClient.setRegisterHandler { _, _ in throw AppError.network(message: "offline") }
        let store = PushNotificationStore(
            authorizationService: StubPushAuthorizationService(), deviceTokenAPIClient: deviceTokenClient
        )

        // 不 throw、不 crash——`submitTokenIfNeeded` 本身簽名不是 `throws`，只要能編譯、跑完
        // 就已經證明「失敗不擋」；下面另外斷言沒有被誤標記成功。
        await store.submitTokenIfNeeded("willfail", userID: userID)

        XCTAssertNil(
            PushDeviceTokenSubmissionRecord.lastSubmittedTokenHex(userID: userID),
            "RPC 失敗不該標記已送出，否則下次前景／登入不會重試"
        )
    }

    /// 失敗一次之後，下次呼叫（模擬下次前景重試）應該重新嘗試——不是永久放棄。
    func testSubmitTokenIfNeeded_registerFailsThenSucceeds_retriesAndMarksSubmitted() async {
        let userID = UUID()
        defer { PushDeviceTokenSubmissionRecord.reset(userID: userID) }
        let deviceTokenClient = StubPushDeviceTokenAPIClient()
        deviceTokenClient.setRegisterHandler { _, _ in throw AppError.network(message: "offline") }
        let store = PushNotificationStore(
            authorizationService: StubPushAuthorizationService(), deviceTokenAPIClient: deviceTokenClient
        )

        await store.submitTokenIfNeeded("retry-me", userID: userID)
        deviceTokenClient.setRegisterHandler { _, _ in }
        await store.submitTokenIfNeeded("retry-me", userID: userID)

        XCTAssertEqual(deviceTokenClient.registerCallCount, 2, "第一次失敗後應該重試，不是被去重擋掉")
        XCTAssertEqual(PushDeviceTokenSubmissionRecord.lastSubmittedTokenHex(userID: userID), "retry-me")
    }

    func testDidFailToRegister_doesNotCrash() {
        let store = PushNotificationStore(
            authorizationService: StubPushAuthorizationService(),
            deviceTokenAPIClient: StubPushDeviceTokenAPIClient()
        )

        // 唯一的驗證點：呼叫本身不 throw、不 crash（票文範圍 2「註冊失敗記 log 不擋 UI」）。
        store.didFailToRegister(error: AppError.network(message: "offline"))
    }

    // MARK: - didRegister（AppDelegate 轉呼叫的整段路徑）

    func testDidRegister_hexEncodesTokenAndSubmits() async {
        let userID = UUID()
        defer { PushDeviceTokenSubmissionRecord.reset(userID: userID) }
        let deviceTokenClient = StubPushDeviceTokenAPIClient()
        let store = PushNotificationStore(
            authorizationService: StubPushAuthorizationService(), deviceTokenAPIClient: deviceTokenClient
        )
        let tokenData = Data([0xDE, 0xAD, 0xBE, 0xEF])

        await store.didRegister(deviceToken: tokenData, userID: userID)

        XCTAssertEqual(deviceTokenClient.registeredTokens, ["deadbeef"])
    }

    // MARK: - refreshForEnteringApp（票文範圍 1）

    func testRefreshForEnteringApp_notDeterminedNeverShown_showsPreprompt() async {
        let userID = UUID()
        defer { PushPrepromptDisplayRecord.reset(userID: userID) }
        let store = PushNotificationStore(
            authorizationService: StubPushAuthorizationService(status: .notDetermined),
            deviceTokenAPIClient: StubPushDeviceTokenAPIClient()
        )

        await store.refreshForEnteringApp(userID: userID)

        XCTAssertEqual(store.authorizationStatus, .notDetermined)
        XCTAssertTrue(store.showsPreprompt)
    }

    func testRefreshForEnteringApp_authorized_doesNotShowPreprompt() async {
        let userID = UUID()
        defer { PushPrepromptDisplayRecord.reset(userID: userID) }
        let store = PushNotificationStore(
            authorizationService: StubPushAuthorizationService(status: .authorized),
            deviceTokenAPIClient: StubPushDeviceTokenAPIClient()
        )

        await store.refreshForEnteringApp(userID: userID)

        XCTAssertFalse(store.showsPreprompt)
    }

    func testDismissPreprompt_marksShown_soNextRefreshDoesNotShowAgain() async {
        let userID = UUID()
        defer { PushPrepromptDisplayRecord.reset(userID: userID) }
        let store = PushNotificationStore(
            authorizationService: StubPushAuthorizationService(status: .notDetermined),
            deviceTokenAPIClient: StubPushDeviceTokenAPIClient()
        )
        await store.refreshForEnteringApp(userID: userID)
        XCTAssertTrue(store.showsPreprompt)

        store.dismissPreprompt(userID: userID)
        XCTAssertFalse(store.showsPreprompt)

        // 模擬下次啟動／再次進場：再查一次，這次不該再自動顯示。
        await store.refreshForEnteringApp(userID: userID)
        XCTAssertFalse(store.showsPreprompt, "已看過的旗標應該持久——下次進場不該再自動顯示")
    }

    // MARK: - requestAuthorizationAndRegister

    func testRequestAuthorizationAndRegister_granted_updatesStatusToAuthorized() async {
        let authService = StubPushAuthorizationService()
        authService.setRequestAuthorizationHandler { true }
        let store = PushNotificationStore(
            authorizationService: authService, deviceTokenAPIClient: StubPushDeviceTokenAPIClient()
        )

        let granted = await store.requestAuthorizationAndRegister()

        XCTAssertTrue(granted)
        XCTAssertEqual(store.authorizationStatus, .authorized)
    }

    func testRequestAuthorizationAndRegister_denied_updatesStatusToDenied() async {
        let authService = StubPushAuthorizationService()
        authService.setRequestAuthorizationHandler { false }
        let store = PushNotificationStore(
            authorizationService: authService, deviceTokenAPIClient: StubPushDeviceTokenAPIClient()
        )

        let granted = await store.requestAuthorizationAndRegister()

        XCTAssertFalse(granted)
        XCTAssertEqual(store.authorizationStatus, .denied)
        XCTAssertEqual(authService.registerForRemoteNotificationsCallCount, 0, "被拒絕不該呼叫註冊")
    }

    /// 註冊失敗不擋 UI：`requestAuthorization()` 本身 throw（例如系統層級錯誤）不該讓呼叫端
    /// 崩潰，回傳 `false` 讓畫面照常關閉（`PushPrepromptView` 的 CTA 兩種結果都會 `onFinish`）。
    func testRequestAuthorizationAndRegister_throws_returnsFalseWithoutCrashing() async {
        let authService = StubPushAuthorizationService()
        authService.setRequestAuthorizationHandler { throw AppError.network(message: "offline") }
        let store = PushNotificationStore(
            authorizationService: authService, deviceTokenAPIClient: StubPushDeviceTokenAPIClient()
        )

        let granted = await store.requestAuthorizationAndRegister()

        XCTAssertFalse(granted)
    }
}

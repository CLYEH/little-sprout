import AuthenticationServices
import Foundation
@testable import LittleSprout
import XCTest

/// Root routing 狀態機：`isSessionValid` 是「離線過期 session 查 expiresAt」這條規則的
/// 核心（LS-55 N1／I5），`AuthStore` 則是把 `AuthService.currentSession`（非 Observable）
/// 包成可以驅動 SwiftUI 重繪的來源（LS-55 N7）。
@MainActor
final class AuthStoreTests: XCTestCase {
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    // MARK: - isSessionValid（純函式，root routing 狀態機的核心判斷）

    func test_isSessionValid_nilSession_isFalse() {
        XCTAssertFalse(AuthStore.isSessionValid(nil, asOf: Date()))
    }

    func test_isSessionValid_futureExpiry_isTrue() {
        let session = AuthSession(userID: userID, email: "a@example.com", expiresAt: Date().addingTimeInterval(3600))
        XCTAssertTrue(AuthStore.isSessionValid(session, asOf: Date()))
    }

    func test_isSessionValid_pastExpiry_isFalse() {
        // 離線開 app 時 currentSession 可能回傳非 nil 但已過期的 session（LS-55 N1）——
        // root routing 不能只判斷「非 nil 就當作已登入」，這條測試釘住必須額外看 expiresAt。
        let session = AuthSession(userID: userID, email: "a@example.com", expiresAt: Date().addingTimeInterval(-3600))
        XCTAssertFalse(AuthStore.isSessionValid(session, asOf: Date()))
    }

    func test_isSessionValid_exactlyAtExpiry_isFalse() {
        let now = Date()
        let session = AuthSession(userID: userID, email: "a@example.com", expiresAt: now)
        XCTAssertFalse(AuthStore.isSessionValid(session, asOf: now))
    }

    // MARK: - init 讀初始快照

    func test_init_seedsSessionFromAuthService() {
        let session = AuthSession(userID: userID, email: "a@example.com", expiresAt: .distantFuture)
        let stub = StubAuthService(currentSession: session)

        let store = AuthStore(authService: stub)

        XCTAssertEqual(store.session, session)
        XCTAssertTrue(store.isAuthenticated())
    }

    func test_init_expiredCachedSession_isAuthenticatedFalse() {
        // 離線重啟情境：AuthService 回傳非 nil 但過期的 session，AuthStore 一樣要判定未登入。
        let expired = AuthSession(userID: userID, email: "a@example.com", expiresAt: Date().addingTimeInterval(-10))
        let stub = StubAuthService(currentSession: expired)

        let store = AuthStore(authService: stub)

        XCTAssertNotNil(store.session, "過期 session 仍要保留在 session 屬性上，不是被吃掉")
        XCTAssertFalse(store.isAuthenticated())
    }

    // MARK: - 動作完成後更新可觀察的 session（驅動 root routing 重繪的訊號）

    func test_signInWithApple_success_updatesSession() async throws {
        let stub = StubAuthService()
        let expected = AuthSession(userID: userID, email: "apple@example.com", expiresAt: .distantFuture)
        stub.setSignInWithAppleHandler { _, _ in expected }
        let store = AuthStore(authService: stub)
        XCTAssertNil(store.session)

        try await store.signInWithApple(idToken: "id-token", nonce: "nonce")

        XCTAssertEqual(store.session, expected)
        XCTAssertTrue(store.isAuthenticated())
    }

    // MARK: - signInWithGoogle（LS-39）
    //
    // `StubAuthService.signInWithGoogle` 不會真的呼叫 `launchFlow`（見該檔註解）——這裡的
    // `noopLaunchFlow` 純粹是滿足協定簽名的佔位輸入，測試只斷言 `AuthStore` 怎麼處理
    // handler 回傳/丟出的結果。真正的 ASWebAuthenticationSession／取消行為靠模擬器手動驗證
    // （見 handoff）。

    private var noopLaunchFlow: @MainActor @Sendable (_ url: URL) async throws -> URL {
        { url in url }
    }

    func test_signInWithGoogle_success_updatesSession() async throws {
        let stub = StubAuthService()
        let expected = AuthSession(userID: userID, email: "google@example.com", expiresAt: .distantFuture)
        stub.setSignInWithGoogleHandler { expected }
        let store = AuthStore(authService: stub)
        XCTAssertNil(store.session)

        try await store.signInWithGoogle(launchFlow: noopLaunchFlow)

        XCTAssertEqual(store.session, expected)
        XCTAssertTrue(store.isAuthenticated())
    }

    func test_signInWithGoogle_userCanceled_propagatesRawErrorWithoutUpdatingSession() async {
        // 使用者在系統瀏覽器面板取消：`AuthService.signInWithGoogle` 協定文件定案這種情況原樣
        // 拋 `ASWebAuthenticationSessionError`（不包成 `AppError`）——這裡釘住 `AuthStore` 對
        // 這個型別不做任何特殊判斷（不吞、不誤判成功），也沒有汙染 session；辨識「取消該
        // 靜默」是 `WelcomeView` 的責任，不是這一層。
        let stub = StubAuthService()
        stub.setSignInWithGoogleHandler { throw ASWebAuthenticationSessionError(.canceledLogin) }
        let store = AuthStore(authService: stub)

        do {
            try await store.signInWithGoogle(launchFlow: noopLaunchFlow)
            XCTFail("使用者取消時必須把錯誤原樣往上拋，不能吞掉")
        } catch let error as ASWebAuthenticationSessionError {
            XCTAssertEqual(error.code, .canceledLogin)
        } catch {
            XCTFail("預期原樣拋出 ASWebAuthenticationSessionError，實際拿到 \(error)")
        }

        XCTAssertNil(store.session)
    }

    func test_signInWithGoogle_failure_propagatesAppErrorWithoutUpdatingSession() async {
        let stub = StubAuthService()
        stub.setSignInWithGoogleHandler { throw AppError.network(message: "offline") }
        let store = AuthStore(authService: stub)

        do {
            try await store.signInWithGoogle(launchFlow: noopLaunchFlow)
            XCTFail("失敗時必須把錯誤往上拋，不能吞掉")
        } catch {
            XCTAssertEqual(AppError.map(error), .network(message: "offline"))
        }

        XCTAssertNil(store.session)
    }

    func test_verifyEmailOTP_success_updatesSession() async throws {
        let stub = StubAuthService()
        let expected = AuthSession(userID: userID, email: "grandma@example.com", expiresAt: .distantFuture)
        stub.setVerifyEmailOTPHandler { _, _ in expected }
        let store = AuthStore(authService: stub)

        try await store.verifyEmailOTP(email: "grandma@example.com", token: "123456")

        XCTAssertEqual(store.session, expected)
    }

    func test_signOut_clearsSession() async throws {
        let session = AuthSession(userID: userID, email: "a@example.com", expiresAt: .distantFuture)
        let stub = StubAuthService(currentSession: session)
        let store = AuthStore(authService: stub)
        XCTAssertNotNil(store.session)

        try await store.signOut()

        XCTAssertNil(store.session)
        XCTAssertFalse(store.isAuthenticated())
    }

    func test_signOut_failure_doesNotClearSessionAndPropagatesError() async {
        // 順修（LS-17 收尾 sweeper F2）：`StubAuthService.setSignOutHandler` 原本零呼叫點，
        // `SettingsView.signOut()` 的 `errorMessage` alert 分支（`catch { errorMessage =
        // AppError.map(error).userFacingMessage }`）也從未被驗證過——`authService.signOut()`
        // 丟錯時，`AuthStore.signOut()` 裡 `session = nil` 那行（見該方法實作）根本執行不到，
        // 錯誤必須原樣往上拋，SettingsView 的 catch 分支才接得住並顯示 alert。
        let session = AuthSession(userID: userID, email: "a@example.com", expiresAt: .distantFuture)
        let stub = StubAuthService(currentSession: session)
        stub.setSignOutHandler { throw AppError.network(message: "offline") }
        let store = AuthStore(authService: stub)
        XCTAssertNotNil(store.session)

        do {
            try await store.signOut()
            XCTFail("signOut() 失敗時必須把錯誤往上拋，不能吞掉")
        } catch {
            XCTAssertEqual(AppError.map(error), .network(message: "offline"))
        }

        XCTAssertNotNil(store.session, "signOut 失敗不該清掉 session——使用者仍是登入狀態")
        XCTAssertTrue(store.isAuthenticated())
    }

    func test_refreshSnapshot_picksUpBackgroundChange() {
        // 模擬「這個 store 沒有主動呼叫、但背景已經改變 session」（例如 SDK 的
        // autoRefreshToken 計時器）——RootView 在 scenePhase 轉 active 時呼叫這個方法補撿。
        let stub = StubAuthService()
        let store = AuthStore(authService: stub)
        XCTAssertNil(store.session)

        let refreshed = AuthSession(userID: userID, email: "refreshed@example.com", expiresAt: .distantFuture)
        stub.setCurrentSession(refreshed)
        XCTAssertNil(store.session, "在呼叫 refreshSnapshot() 之前，store 不會自動看到背景變化")

        store.refreshSnapshot()

        XCTAssertEqual(store.session, refreshed)
    }

    // MARK: - sessionUpdates 訂閱（LS-17 R2 merge-reviewer N5／LS-82）

    func test_sessionUpdates_signedOut_clearsSessionAndDeauthenticates() async throws {
        // SDK 端偵測到 refresh token 被撤銷／重用會發 signedOut，這條路徑不經過任何
        // AuthStore 方法呼叫——必須靠訂閱 sessionUpdates 才能反映，不能只靠 init／
        // mutating 方法後／scenePhase 這三個既有快照時機（否則使用者會停在一個已登出
        // 的 app 裡，見 ticket 描述）。RootView 的 root routing 直接讀
        // `authStore.isAuthenticated()`，這裡在 store 層驗證同一個判斷。
        let session = AuthSession(userID: userID, email: "a@example.com", expiresAt: .distantFuture)
        let stub = StubAuthService(currentSession: session)
        let store = AuthStore(authService: stub)
        XCTAssertTrue(store.isAuthenticated())

        stub.emitSessionUpdate(nil)

        let expectation = expectation(description: "sessionUpdates 的 signedOut 事件把 session 寫回 nil")
        let pollTask = Task {
            while store.session != nil {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        pollTask.cancel()

        XCTAssertNil(store.session)
        XCTAssertFalse(store.isAuthenticated(), "RootView 靠這個判斷決定要不要繼續顯示已登入內容")
    }

    func test_sessionUpdates_tokenRefreshed_doesNotClearSession() async throws {
        // 對照上一條：tokenRefreshed 事件帶的是仍然有效的新 session，訂閱不能把它誤判成
        // 登出——這裡直接把值轉發（不篩事件種類）就自然滿足，這條測試釘住這個預期不會
        // 之後被「乾脆只在收到 nil 時才更新」之類的簡化悄悄破壞。
        let stub = StubAuthService()
        let store = AuthStore(authService: stub)
        XCTAssertNil(store.session)

        let refreshed = AuthSession(userID: userID, email: "refreshed@example.com", expiresAt: .distantFuture)
        stub.emitSessionUpdate(refreshed)

        let expectation = expectation(description: "sessionUpdates 的 tokenRefreshed 事件把新 session 寫進去，不是清成 nil")
        let pollTask = Task {
            while store.session == nil {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        pollTask.cancel()

        XCTAssertEqual(store.session, refreshed)
        XCTAssertTrue(store.isAuthenticated())
    }
}

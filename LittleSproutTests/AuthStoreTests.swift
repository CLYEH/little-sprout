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
}

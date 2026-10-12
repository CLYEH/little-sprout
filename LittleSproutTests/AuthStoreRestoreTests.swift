import Foundation
@testable import LittleSprout
import XCTest

/// LS-502 R1b：`AuthStore` 還原中狀態的熱回前景與逾時測試。與 `AuthStoreTests` 分檔只因該類別
/// 已貼近 SwiftLint `type_body_length` 上限（250 行）。
@MainActor
final class AuthStoreRestoreTests: XCTestCase {
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func test_sceneDidBecomeActive_sessionExpiredWhileSettled_becomesPendingThenSettlesOnRefreshedEvent() async throws {
        // 熱回前景：app 在背景待過 access token 壽命，回前景時 store 早已 settled、session 已過期——
        // 不重設成 pending 就會直接落登入頁（與冷啟動同一個閃爍）。
        let shortLived = AuthSession(userID: userID, email: "a@example.com", expiresAt: Date().addingTimeInterval(0.5))
        let stub = StubAuthService(currentSession: shortLived)
        let store = AuthStore(authService: stub)
        XCTAssertEqual(store.restoreState, .settled, "init 時 session 仍有效")

        store.sceneDidBecomeActive()
        XCTAssertEqual(store.restoreState, .settled, "有效 session 回前景不進還原中")

        try await Task.sleep(nanoseconds: 700_000_000) // 時間推到過期
        store.sceneDidBecomeActive()
        XCTAssertEqual(store.restoreState, .pending, "settled＋session 已過期 → 重設為還原中")

        stub.emitSessionUpdate(AuthSession(userID: userID, email: "a@example.com", expiresAt: .distantFuture))
        let expectation = expectation(description: "刷新後的有效 session 事件讓 restoreState 回到 settled")
        let pollTask = Task {
            while store.restoreState != .settled {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        pollTask.cancel()
    }

    func test_init_expiredSession_noEvent_settlesAfterInjectedTimeout() async throws {
        // 離線：SDK refresh 失敗但不發事件，只靠逾時兜底結束還原（注入 0.05 秒避免等 5 秒）。
        let expired = AuthSession(userID: userID, email: "a@example.com", expiresAt: Date().addingTimeInterval(-3600))
        let store = AuthStore(authService: StubAuthService(currentSession: expired), restoreTimeout: .milliseconds(50))
        XCTAssertEqual(store.restoreState, .pending)

        for _ in 0..<200 where store.restoreState == .pending {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(store.restoreState, .settled, "沒有任何事件時，逾時必須結束還原，否則離線會永遠卡在佔位頁")
        XCTAssertFalse(store.isAuthenticated(), "逾時後 session 仍過期 → RootRoute 落登入頁")
    }
}

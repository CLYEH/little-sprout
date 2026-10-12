@testable import LittleSprout
import XCTest

/// LS-502：根路由三態。使用者回報的缺陷是「Keychain 的 access token 已過期（1h）→ 第一幀直接
/// 落登入頁，等 SDK 背景 refresh 成功才跳進動態」——`.restoring` 必須擋住這一閃。
@MainActor
final class RootRouteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let userID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func session(expiresIn seconds: TimeInterval) -> AuthSession {
        AuthSession(userID: userID, email: "a@example.com", expiresAt: now.addingTimeInterval(seconds))
    }

    func test_validSession_isAuthenticated_evenWhilePending() {
        // 有效 session 不受還原狀態影響（既有登入行為不變）。
        for state in [AuthStore.RestoreState.pending, .settled] {
            XCTAssertEqual(
                RootRoute.resolve(session: session(expiresIn: 3600), now: now, restoreState: state),
                .authenticated
            )
        }
    }

    func test_nilSession_isWelcome_evenWhilePending() {
        // 沒有存 session 的人沒有東西可還原，不能卡在佔位頁。
        for state in [AuthStore.RestoreState.pending, .settled] {
            XCTAssertEqual(RootRoute.resolve(session: nil, now: now, restoreState: state), .welcome)
        }
    }

    func test_expiredSession_pending_isRestoring() {
        // 本票要修的缺陷：過期 + 還原中 ≠ 登入頁。
        XCTAssertEqual(
            RootRoute.resolve(session: session(expiresIn: -60), now: now, restoreState: .pending),
            .restoring,
            "過期 session 在還原中必須顯示啟動佔位頁，不得落登入頁"
        )
    }

    func test_expiredSession_settled_isWelcome() {
        // 刷新失敗／離線逾時後仍過期 → 登入頁（與 LS-502 前離線行為相同）。
        XCTAssertEqual(
            RootRoute.resolve(session: session(expiresIn: -60), now: now, restoreState: .settled),
            .welcome
        )
    }

    func test_expiredSession_afterRestoreTimeout_isWelcome() {
        // 逾時兜底：`AuthStore.restoreTimeout` 到期會把 `.pending` 設成 `.settled`（見 AuthStore），
        // 此後同一份過期 session 路由成登入頁。
        XCTAssertEqual(AuthStore.restoreTimeout, .seconds(5))
        XCTAssertEqual(
            RootRoute.resolve(session: session(expiresIn: -3600), now: now, restoreState: .settled),
            .welcome
        )
    }
}

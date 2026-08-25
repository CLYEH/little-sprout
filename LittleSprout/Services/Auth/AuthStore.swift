import Foundation
import Observation

/// 把 `AuthService.currentSession` 包成 `@Observable`，讓 root routing 可以依它重繪
/// （`AuthService.currentSession` 本身不是 Observable，背景變化不會觸發任何 View 重繪，見該
/// 協定文件與 LS-55 N7）。所有會改變登入狀態的動作（Apple／Email OTP／登出）都經過這個
/// store，動作完成後立刻把結果寫進 `session`——這個屬性的變化才是驅動畫面重繪的訊號，不是
/// 直接在 View 裡讀 `authService.currentSession`。
///
/// `refreshSnapshot()` 供 App 從背景回到前景時呼叫，撿回可能在背景被其他路徑（例如 SDK
/// 的 autoRefreshToken 計時器）更新、但這個 store 還沒看到的 session 變化。
@MainActor
@Observable
final class AuthStore {
    private let authService: AuthService

    private(set) var session: AuthSession?

    init(authService: AuthService) {
        self.authService = authService
        self.session = authService.currentSession
    }

    /// 離線開 app 時 `currentSession` 可能回傳非 nil 但已過期的 session（LS-55 N1／I5）；
    /// root routing 必須用這個屬性，不能只判斷 `session != nil`。
    func isAuthenticated(asOf now: Date = Date()) -> Bool {
        AuthStore.isSessionValid(session, asOf: now)
    }

    static func isSessionValid(_ session: AuthSession?, asOf now: Date) -> Bool {
        guard let session else { return false }
        return session.expiresAt > now
    }

    @discardableResult
    func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        let session = try await authService.signInWithApple(idToken: idToken, nonce: nonce)
        self.session = session
        return session
    }

    func sendEmailOTP(email: String) async throws {
        try await authService.sendEmailOTP(email: email)
    }

    @discardableResult
    func verifyEmailOTP(email: String, token: String) async throws -> AuthSession {
        let session = try await authService.verifyEmailOTP(email: email, token: token)
        self.session = session
        return session
    }

    func signOut() async throws {
        try await authService.signOut()
        session = nil
    }

    func refreshSnapshot() {
        session = authService.currentSession
    }
}

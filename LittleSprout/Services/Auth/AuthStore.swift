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
///
/// 真正驅動 `session` 的是 init 起的 `sessionUpdates` 訂閱（見下方 `observeSessionUpdatesTask`）
/// ——涵蓋「SDK 端偵測到 refresh token 被撤銷／重用而發 signedOut，但沒有經過這個 store 任何
/// 方法呼叫」的情況（LS-17 R2 merge-reviewer N5／LS-82）。init／mutating 方法後／
/// `refreshSnapshot()` 這三個快照時機仍然保留，但只是補位：真正即時的訊號一律以訂閱到的
/// `sessionUpdates` 事件為準，快照只是「訂閱事件還沒送達前」的過渡值，兩邊寫的都是同一個
/// `AuthService` 的事實，不會互相矛盾。
@MainActor
@Observable
final class AuthStore {
    private let authService: AuthService
    // Optional（有隱含預設值 nil）而非 let：讓下面 init 裡 `[weak self]` 捕捉可以放在任何位置，
    // 不受「escaping closure 捕捉 self 前，這個屬性本身必須先被賦值」這條 definite
    // initialization 規則卡住（該規則連 weak 捕捉也算「使用 self」）。`nonisolated(unsafe)`：
    // `deinit` 是 nonisolated（隨時可能在任何 thread 執行），但只需要呼叫 `Task.cancel()`
    // 這個本身 thread-safe 的操作——沒有其他地方會並發寫這個屬性（唯一寫入點是 init，唯一
    // 讀取點是 deinit）。`@ObservationIgnored`：這是內部實作細節（背景 task handle），不是
    // 該讓 View 依它重繪的狀態，本來就不該進 `@Observable` 的追蹤——順便繞開「`nonisolated`
    // 不能套用在 `@Observable` 巨集轉換過的 mutable 屬性」這條限制，讓 `nonisolated(unsafe)`
    // 生效（`Task<Void, Never>` 是 `Sendable`，這裡的用法安全，見上方說明）。
    @ObservationIgnored
    private nonisolated(unsafe) var observeSessionUpdatesTask: Task<Void, Never>?

    private(set) var session: AuthSession?

    init(authService: AuthService) {
        self.authService = authService
        self.session = authService.currentSession
        observeSessionUpdatesTask = Task { [weak self] in
            for await session in authService.sessionUpdates {
                guard let self, !Task.isCancelled else { return }
                self.session = session
            }
        }
    }

    deinit {
        observeSessionUpdatesTask?.cancel()
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

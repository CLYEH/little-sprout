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
/// `refreshSnapshot()` 這三個快照時機仍然保留，但只是補位。**權威值一律是
/// `authService.currentSession`**：`sessionUpdates` 只當「有事發生、該重新讀」的訊號，訂閱迴圈
/// 收到事件後不直接採用事件攜帶的值，而是重讀 `currentSession`——`SupabaseAuthService` 對
/// `cachedSession` 是先寫後 yield，構造上 `currentSession` 不可能比已送達的 stream 事件更舊
/// （LS-82 PR #147 review F2）。快照路徑與訂閱路徑因此不會互相覆蓋成更舊的值，但暫態上仍可能
/// 不同步（例如背景累積多個事件、`refreshSnapshot()` 先跑一次再被訂閱迴圈追上）——會收斂，不
/// 保證每個中間值都對到一次重繪。
@MainActor
@Observable
final class AuthStore {
    private let authService: AuthService
    // Optional（有隱含預設值 nil）而非 let：讓下面 init 裡 `[weak self]` 捕捉可以放在任何位置，
    // 不受「escaping closure 捕捉 self 前，這個屬性本身必須先被賦值」這條 definite
    // initialization 規則卡住（該規則連 weak 捕捉也算「使用 self」）。`@ObservationIgnored`：
    // 排除在 `@Observable` 巨集的追蹤之外（本來就不是該讓 View 依它重繪的狀態），順便讓這個
    // `Sendable`（`Task<Void, Never>`）屬性能被 nonisolated 的 `deinit` 直接讀取／呼叫
    // `cancel()`（LS-82 PR #147 review F3 實測：`@ObservationIgnored` 就夠，不需要再疊
    // `nonisolated(unsafe)`——那會把這個屬性永久移出 isolation 檢查，日後若有其他地方從
    // nonisolated context 重新指派它，編譯器不會攔）。
    @ObservationIgnored
    private var observeSessionUpdatesTask: Task<Void, Never>?

    private(set) var session: AuthSession?

    init(authService: AuthService) {
        self.authService = authService
        self.session = authService.currentSession
        observeSessionUpdatesTask = Task { [weak self] in
            for await _ in authService.sessionUpdates {
                guard let self, !Task.isCancelled else { return }
                self.session = authService.currentSession
            }
        }
    }

    // 這裡的 cancel 不只停掉這個 store 自己的訂閱迴圈——`sessionUpdates` 是一次性訂閱，
    // consumer 取消後底層 stream 永久終止（實測，見 `AuthService.sessionUpdates` 協定文件）。
    // 目前生產路徑 `authService` 與 `AuthStore` 在 `LittleSproutApp` 成對建立、同生共死，
    // 沒有現行 bug；但若日後 `authService` 被提升為跨多個 store 共用的實例，這裡的 cancel
    // 會讓下一個訂閱它的 store 永遠收不到事件、且不會有任何錯誤（LS-82 PR #147 review F1）。
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

    /// 見 `AuthService.signInWithGoogle` 協定文件：使用者取消時 `authService` 會原樣拋
    /// `ASWebAuthenticationSessionError`（不是 `AppError`）——這裡不做任何特殊判斷，跟其他
    /// 失敗一樣原封不動往上傳；辨識「取消該靜默」是呼叫端（`WelcomeView`）的責任。
    @discardableResult
    func signInWithGoogle(
        launchFlow: @MainActor @Sendable (_ url: URL) async throws -> URL
    ) async throws -> AuthSession {
        let session = try await authService.signInWithGoogle(launchFlow: launchFlow)
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

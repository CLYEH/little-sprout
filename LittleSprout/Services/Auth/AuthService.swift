import Foundation

/// 認證服務介面。Supabase 是唯一實作（`SupabaseAuthService`），但介面本身不洩漏這件事，
/// 讓呼叫端可以用假實作測試。錯誤一律映射為 `AppError`（見該檔），不直接往外拋
/// Supabase SDK 的 error 型別。
protocol AuthService: Sendable {
    /// 目前的登入狀態；未登入為 nil。可能是過期的——呼叫端若需要保證有效的 session，
    /// 用 `refreshSession()`。實作要求：這個屬性必須是純記憶體讀取（不得每次存取都同步
    /// 打 Keychain 之類的 I/O），讀取本身在 SwiftUI body 這種高頻重繪的地方是安全的
    /// （`SupabaseAuthService` 用內部快取＋監聽 auth 狀態變化達成）。
    ///
    /// 離線開 app 時（見 `SupabaseClientFactory.emitLocalSessionAsInitialSession`／LS-55 N1）：
    /// 這裡回傳的可能是一份**已過期但非 nil**的 session（先前登入過、本機還留著、但目前連
    /// 不上網刷新）——不是「nil＝未登入、非 nil＝已登入且可用」這麼單純。任何要用這個值判斷
    /// 「該不該讓使用者進 app」的 root routing 邏輯，必須另外檢查 `expiresAt`，不能只看
    /// 「非 nil 就當作已登入可用」（LS-55 I5；PR #77 R1）。
    ///
    /// 注意：「讀取安全」不等於「可以直接當 SwiftUI 的狀態源」。這個屬性本身不是
    /// Observable（沒有 publisher，值變化不會通知任何 View），值在背景變化時（例如
    /// autoRefreshToken 自動刷新、或另一個畫面呼叫 `signOut()`）不會觸發任何重繪——
    /// 直接在某個 View 的 `body` 裡讀它，只會拿到「這次剛好重繪時」的一次性快照，之後
    /// 不會自動更新。LS-17（登入 UI／root routing）需要另外包一層 observable（例如
    /// `@Observable` class 內部訂閱 auth 狀態變化再對外發佈），不能直接拿這個協定的
    /// `currentSession` 驅動畫面路由邏輯（LS-55 N7）。
    var currentSession: AuthSession? { get }

    /// Session 狀態變化的非同步序列，直接對應底層 SDK 的 `authStateChanges`（測試假實作可自行
    /// 決定何時推送）。這是唯一能讓訂閱端跟上「SDK 端背景改變 session、且沒有經過呼叫端任何
    /// `AuthService` 方法」這種情況的訊號來源——例如 SDK 偵測到 refresh token 被撤銷／重用而
    /// 發 `signedOut`，`currentSession` 快取會變 nil，但這件事本身不會通知任何人（LS-17 R2
    /// merge-reviewer N5／LS-82）。`AuthStore` 用它驅動 `session`，取代單靠 init／mutating
    /// 方法後／`scenePhase` 這三個快照時機。
    ///
    /// 實作只需要保證單一消費者訂閱後能收到之後所有事件——app 內只有一個 `AuthStore` 會訂閱，
    /// 不需要支援多消費者廣播。
    ///
    /// **訂閱是一次性的**：消費者（`for await` 所在的 `Task`）一旦被取消，底層 stream 就會
    /// **永久終止**——不是「這個消費者停止收」，是整條 stream 死掉，之後即使換一個新的
    /// `for await` 重新訂閱也收不到任何事件、迴圈直接結束，且不會有任何錯誤或訊號指出這件事
    /// （LS-82 PR #147 review F1，實測）。因此持有這個 `AuthService` 實例的物件，與訂閱
    /// `sessionUpdates` 的 `AuthStore`，兩者必須成對建立、同生共死（目前生產路徑
    /// `LittleSproutApp` 就是這樣接的）。若日後（例如 LS-18）把 `AuthService` 實例提升為跨
    /// 多個元件共用、而 `AuthStore` 可能被重建，這裡會靜默失效，須另外處理（例如改
    /// `sessionUpdates` 為每次取用註冊新 continuation 的 computed property）。
    var sessionUpdates: AsyncStream<AuthSession?> { get }

    /// 用 Sign in with Apple 拿到的 ID token 交換 Supabase session。
    /// - Parameters:
    ///   - idToken: `ASAuthorizationAppleIDCredential.identityToken` 解出的 JWT 字串。
    ///   - nonce: 送出 Apple 登入請求前產生的原始（未雜湊）nonce，見 `AppleSignInNonce`。
    @discardableResult
    func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession

    /// 寄送 Email OTP 到指定信箱。
    func sendEmailOTP(email: String) async throws

    /// 驗證 Email OTP 並登入。
    @discardableResult
    func verifyEmailOTP(email: String, token: String) async throws -> AuthSession

    /// 強制刷新 session（例如即將過期時）。
    @discardableResult
    func refreshSession() async throws -> AuthSession

    /// 登出目前裝置的 session。
    func signOut() async throws
}

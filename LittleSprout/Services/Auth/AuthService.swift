import Foundation

/// 認證服務介面。Supabase 是唯一實作（`SupabaseAuthService`），但介面本身不洩漏這件事，
/// 讓呼叫端可以用假實作測試。錯誤一律映射為 `AppError`（見該檔），不直接往外拋
/// Supabase SDK 的 error 型別。
protocol AuthService: Sendable {
    /// 目前的登入狀態；未登入為 nil。可能是過期的——呼叫端若需要保證有效的 session，
    /// 用 `refreshSession()`。實作要求：這個屬性必須是純記憶體讀取（不得每次存取都同步
    /// 打 Keychain 之類的 I/O），才能安全用在 SwiftUI body 這種高頻重繪的地方
    /// （`SupabaseAuthService` 用內部快取＋監聽 auth 狀態變化達成）。
    var currentSession: AuthSession? { get }

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

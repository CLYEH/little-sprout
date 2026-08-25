#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview` 用的假 `AuthService`——不打真網路、不需要 `Config/Secrets.xcconfig`。
/// 生產路徑（`LittleSproutApp`）一律用 `SupabaseAuthService`，這個型別不會被編進 Release build
/// 之外的任何呼叫路徑（`#if DEBUG` 圍住，且只有 Preview provider 參照它）。
private final class PreviewAuthService: AuthService, @unchecked Sendable {
    var currentSession: AuthSession?

    // Preview 不需要背景 session 變化；回傳一個永遠不會 yield 的空序列即可滿足協定。
    var sessionUpdates: AsyncStream<AuthSession?> {
        AsyncStream { _ in }
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        AuthSession(userID: UUID(), email: "preview@example.com", expiresAt: .distantFuture)
    }

    func sendEmailOTP(email: String) async throws {}

    func verifyEmailOTP(email: String, token: String) async throws -> AuthSession {
        AuthSession(userID: UUID(), email: email, expiresAt: .distantFuture)
    }

    func refreshSession() async throws -> AuthSession {
        AuthSession(userID: UUID(), email: "preview@example.com", expiresAt: .distantFuture)
    }

    func signOut() async throws {}
}

extension AuthStore {
    @MainActor
    static func preview() -> AuthStore {
        AuthStore(authService: PreviewAuthService())
    }
}
#endif

import Auth
import Foundation
import Supabase

/// `AuthService` 的 Supabase 實作。所有方法都只是把 Supabase Auth 呼叫轉一層並把
/// 錯誤映射成 `AppError`；session 的持久化與 auto-refresh 由 SDK 內建行為負責
/// （`SupabaseClient` 預設用 Keychain 儲存＋PKCE flow＋autoRefreshToken=true，
/// 見 `SupabaseClientFactory`），這裡不重做一份。
final class SupabaseAuthService: AuthService {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    var currentSession: AuthSession? {
        client.auth.currentSession.map { AuthSession(session: $0) }
    }

    @discardableResult
    func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
            )
            return AuthSession(session: session)
        } catch {
            throw AppError.map(error)
        }
    }

    func sendEmailOTP(email: String) async throws {
        do {
            try await client.auth.signInWithOTP(email: email)
        } catch {
            throw AppError.map(error)
        }
    }

    @discardableResult
    func verifyEmailOTP(email: String, token: String) async throws -> AuthSession {
        do {
            let response = try await client.auth.verifyOTP(email: email, token: token, type: .email)
            guard case .session(let session) = response else {
                // .user case 只會出現在「沒有建立 session 的驗證流程」（例如某些 signup 確認）；
                // 本 app 的 Email OTP 流程一律預期拿到 session，拿不到視為後端契約不符。
                throw AppError.server(message: "驗證成功但未取得 session", code: nil)
            }
            return AuthSession(session: session)
        } catch {
            throw AppError.map(error)
        }
    }

    @discardableResult
    func refreshSession() async throws -> AuthSession {
        do {
            let session = try await client.auth.refreshSession()
            return AuthSession(session: session)
        } catch {
            throw AppError.map(error)
        }
    }

    func signOut() async throws {
        do {
            try await client.auth.signOut()
        } catch {
            throw AppError.map(error)
        }
    }
}

extension AuthSession {
    init(session: Session) {
        self.init(
            userID: session.user.id,
            email: session.user.email,
            expiresAt: Date(timeIntervalSince1970: session.expiresAt)
        )
    }
}

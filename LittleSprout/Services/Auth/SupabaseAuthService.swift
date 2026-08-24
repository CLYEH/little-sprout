import Auth
import Foundation
import os
import Supabase

/// `AuthService` 的 Supabase 實作。所有方法都只是把 Supabase Auth 呼叫轉一層並把
/// 錯誤映射成 `AppError`；session 的持久化與 auto-refresh 由 SDK 內建行為負責
/// （`SupabaseClient` 預設用 Keychain 儲存＋PKCE flow＋autoRefreshToken=true，
/// 見 `SupabaseClientFactory`），這裡不重做一份。
final class SupabaseAuthService: AuthService {
    private let client: SupabaseClient
    // `AuthClient.currentSession` 每次讀取都會跑 storage migration 檢查再 SecItemCopyMatching
    // 一次同步 Keychain 存取（LS-49 PR #63 review F5）——若 `currentSession` 被用在 SwiftUI
    // body 裡，等於每次重繪都打一次 Keychain。這裡改成本地快取：init 時讀一次當起始值，
    // 之後靠兩條路徑更新：①下面每個方法自己拿到新 session/登出結果後「同步」寫回快取
    // ②`authStateChanges` 監聽背景變化（例如 SDK 的 autoRefreshToken 計時器自動刷新）。
    // 只靠②不夠：`eventEmitter.emit` 到這裡的 `for await` 真的消費到事件之間有排程延遲，
    // 若 signIn 方法一 return 呼叫端就同步讀 currentSession，會讀到還沒更新的舊值
    // （這個 race 是實測抓到的，不是猜的——第一版只做②時單元測試會間歇性失敗）。
    private let cachedSession: OSAllocatedUnfairLock<AuthSession?>
    private let observeAuthChangesTask: Task<Void, Never>

    init(client: SupabaseClient) {
        self.client = client
        let box = OSAllocatedUnfairLock<AuthSession?>(
            initialState: client.auth.currentSession.map { AuthSession(session: $0) }
        )
        cachedSession = box
        observeAuthChangesTask = Task {
            for await (_, session) in client.auth.authStateChanges {
                box.withLock { $0 = session.map { AuthSession(session: $0) } }
            }
        }
    }

    deinit {
        observeAuthChangesTask.cancel()
    }

    /// 目前的登入狀態快取，安全用在 SwiftUI body（純記憶體讀取，不打 Keychain）。
    var currentSession: AuthSession? {
        cachedSession.withLock { $0 }
    }

    @discardableResult
    func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
            )
            return updateCache(session: session)
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
            return updateCache(session: session)
        } catch {
            throw AppError.map(error)
        }
    }

    @discardableResult
    func refreshSession() async throws -> AuthSession {
        do {
            let session = try await client.auth.refreshSession()
            return updateCache(session: session)
        } catch {
            throw AppError.map(error)
        }
    }

    func signOut() async throws {
        do {
            // .local：只登出這一台裝置。SDK 預設 .global 會撤銷同帳號所有裝置的 session，
            // 跟 AuthService 協定文件寫的「登出目前裝置的 session」不符（LS-49 PR #63 review F1）。
            try await client.auth.signOut(scope: .local)
            cachedSession.withLock { $0 = nil }
        } catch {
            throw AppError.map(error)
        }
    }

    /// 把 SDK 的 `Session` 轉成 `AuthSession`、同步寫回快取，再回傳給呼叫端——見上面
    /// `cachedSession` 欄位的註解：不能只靠 `authStateChanges` 非同步更新。
    @discardableResult
    private func updateCache(session: Session) -> AuthSession {
        let authSession = AuthSession(session: session)
        cachedSession.withLock { $0 = authSession }
        return authSession
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

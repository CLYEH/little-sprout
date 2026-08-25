import Auth
import AuthenticationServices
import Foundation
import os
import Supabase

/// `AuthService` 的 Supabase 實作。所有方法都只是把 Supabase Auth 呼叫轉一層並把
/// 錯誤映射成 `AppError`；session 的持久化與 auto-refresh 由 SDK 內建行為負責
/// （`SupabaseClient` 預設用 Keychain 儲存＋PKCE flow＋autoRefreshToken=true，
/// 見 `SupabaseClientFactory`），這裡不重做一份。
final class SupabaseAuthService: AuthService {
    // LS-39：Google OAuth 的 redirect URL，須與 Info.plist 的 CFBundleURLTypes（`littlesprout`
    // scheme）＋ Supabase dashboard → Authentication → URL Configuration → Redirect URLs
    // 三處一致（後者是使用者操作，見 ticket comment 2026-08-25）。
    private static let googleRedirectURL = URL(string: "littlesprout://auth/callback")!

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
    // `sessionUpdates` 由同一條 `authStateChanges` 監聽迴圈驅動（見下面 init），不是另外
    // 重打一份 SDK 呼叫——維持跟 `cachedSession` 完全同步的一份事實來源（LS-82）。一次性訂閱：
    // 消費者取消後這條 stream 永久終止，`sessionUpdates` 與訂閱它的 `AuthStore` 必須同生共死
    // （見 `AuthService.sessionUpdates` 協定文件；LS-82 PR #147 review F1）。
    private let sessionUpdatesContinuation: AsyncStream<AuthSession?>.Continuation
    let sessionUpdates: AsyncStream<AuthSession?>

    init(client: SupabaseClient) {
        self.client = client
        let box = OSAllocatedUnfairLock<AuthSession?>(
            initialState: client.auth.currentSession.map { AuthSession(session: $0) }
        )
        cachedSession = box

        // `.makeStream` 回傳的 continuation 是 `let`（`Sendable`），可以直接被下面的 Task
        // closure 捕捉，不必像 `AsyncStream { $0 }` 那樣繞一層 `var` optional（那種寫法在
        // Swift 6 strict concurrency 下會被判定為「在 escaping closure 裡捕捉可變 var」）。
        let (stream, continuation) = AsyncStream.makeStream(of: AuthSession?.self)
        sessionUpdates = stream
        sessionUpdatesContinuation = continuation

        observeAuthChangesTask = Task {
            for await (_, session) in client.auth.authStateChanges {
                let authSession = session.map { AuthSession(session: $0) }
                box.withLock { $0 = authSession }
                continuation.yield(authSession)
            }
        }
    }

    deinit {
        observeAuthChangesTask.cancel()
        sessionUpdatesContinuation.finish()
    }

    /// 目前的登入狀態快取（純記憶體讀取，不打 Keychain，讀取本身可以安全放在 SwiftUI body
    /// 裡不會拖慢重繪）。但這不是 Observable 屬性——背景更新（`authStateChanges` 監聽到的
    /// 變化）不會通知任何 View 重繪，不得把它當成畫面的狀態來源（見 `AuthService.
    /// currentSession` 協定文件；LS-17 需要另外包一層 observable，LS-55 N7）。
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

    /// 見 `AuthService.signInWithGoogle` 協定文件：`ASWebAuthenticationSessionError`（使用者
    /// 取消）原樣放行，不包進 `AppError`——只有這個 catch 分支之外的錯誤才走一般映射。
    @discardableResult
    func signInWithGoogle(
        launchFlow: @MainActor @Sendable (_ url: URL) async throws -> URL
    ) async throws -> AuthSession {
        do {
            let session = try await client.auth.signInWithOAuth(
                provider: .google,
                redirectTo: Self.googleRedirectURL,
                launchFlow: launchFlow
            )
            return updateCache(session: session)
        } catch let cancelError as ASWebAuthenticationSessionError {
            throw cancelError
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

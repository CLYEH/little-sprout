import Foundation
@testable import LittleSprout
import os

/// LS-17 的 `AuthStore`／`EmailSignInModel`／`OTPVerificationModel` 測試用假
/// `AuthService`——不打真網路，用可設定的 handler 決定每個方法的行為。跟
/// `MockURLProtocol` 同一套模式（lock 保護的可變 handler，見該檔）。
final class StubAuthService: AuthService, @unchecked Sendable {
    typealias EmailHandler = @Sendable (String) async throws -> Void
    typealias SessionHandler = @Sendable (String, String) async throws -> AuthSession
    // Google 走 OAuth，沒有 idToken/nonce 這類輸入可以斷言——測試只需要控制它回傳/丟出什麼。
    typealias GoogleSessionHandler = @Sendable () async throws -> AuthSession

    enum StubError: Error {
        case unconfigured
    }

    private struct Box {
        var currentSession: AuthSession?
        var sendEmailOTPHandler: EmailHandler = { _ in }
        var verifyEmailOTPHandler: SessionHandler = { _, _ in throw StubError.unconfigured }
        var signInWithAppleHandler: SessionHandler = { _, _ in throw StubError.unconfigured }
        var signInWithGoogleHandler: GoogleSessionHandler = { throw StubError.unconfigured }
        var signInWithPasswordHandler: SessionHandler = { _, _ in throw StubError.unconfigured }
        var signOutHandler: @Sendable () async throws -> Void = {}
        var sentEmails: [String] = []
        var verifyAttempts: [(email: String, token: String)] = []
        var passwordSignInAttempts: [(email: String, password: String)] = []
    }

    private let box: OSAllocatedUnfairLock<Box>
    private let sessionUpdatesContinuation: AsyncStream<AuthSession?>.Continuation
    let sessionUpdates: AsyncStream<AuthSession?>

    init(currentSession: AuthSession? = nil) {
        box = OSAllocatedUnfairLock(initialState: Box(currentSession: currentSession))
        let (stream, continuation) = AsyncStream.makeStream(of: AuthSession?.self)
        sessionUpdates = stream
        sessionUpdatesContinuation = continuation
    }

    deinit {
        sessionUpdatesContinuation.finish()
    }

    var currentSession: AuthSession? {
        box.withLock { $0.currentSession }
    }

    /// 供測試模擬「SDK 端背景改變 session」（例如偵測到 refresh token 被撤銷／重用而發
    /// signedOut、或 autoRefreshToken 定時刷新發 tokenRefreshed）——不經過任何
    /// `AuthService` 方法呼叫，直接把值推進 `sessionUpdates`（LS-82）。
    func emitSessionUpdate(_ session: AuthSession?) {
        box.withLock { $0.currentSession = session }
        sessionUpdatesContinuation.yield(session)
    }

    var sentEmails: [String] {
        box.withLock { $0.sentEmails }
    }

    var verifyAttempts: [(email: String, token: String)] {
        box.withLock { $0.verifyAttempts }
    }

    var passwordSignInAttempts: [(email: String, password: String)] {
        box.withLock { $0.passwordSignInAttempts }
    }

    func setCurrentSession(_ session: AuthSession?) {
        box.withLock { $0.currentSession = session }
    }

    func setSendEmailOTPHandler(_ handler: @escaping EmailHandler) {
        box.withLock { $0.sendEmailOTPHandler = handler }
    }

    func setVerifyEmailOTPHandler(_ handler: @escaping SessionHandler) {
        box.withLock { $0.verifyEmailOTPHandler = handler }
    }

    func setSignInWithAppleHandler(_ handler: @escaping SessionHandler) {
        box.withLock { $0.signInWithAppleHandler = handler }
    }

    func setSignInWithGoogleHandler(_ handler: @escaping GoogleSessionHandler) {
        box.withLock { $0.signInWithGoogleHandler = handler }
    }

    func setSignInWithPasswordHandler(_ handler: @escaping SessionHandler) {
        box.withLock { $0.signInWithPasswordHandler = handler }
    }

    func setSignOutHandler(_ handler: @escaping @Sendable () async throws -> Void) {
        box.withLock { $0.signOutHandler = handler }
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        let handler = box.withLock { $0.signInWithAppleHandler }
        let session = try await handler(idToken, nonce)
        box.withLock { $0.currentSession = session }
        return session
    }

    // launchFlow 不在這裡呼叫：測試只關心「AuthStore 怎麼處理 handler 回傳/丟出的結果」，
    // 不重跑一次真的 ASWebAuthenticationSession（那是手動模擬器驗證與 WelcomeView 的事）。
    func signInWithGoogle(
        launchFlow: @MainActor @Sendable (_ url: URL) async throws -> URL
    ) async throws -> AuthSession {
        let handler = box.withLock { $0.signInWithGoogleHandler }
        let session = try await handler()
        box.withLock { $0.currentSession = session }
        return session
    }

    func signInWithPassword(email: String, password: String) async throws -> AuthSession {
        box.withLock { $0.passwordSignInAttempts.append((email, password)) }
        let handler = box.withLock { $0.signInWithPasswordHandler }
        let session = try await handler(email, password)
        box.withLock { $0.currentSession = session }
        return session
    }

    func sendEmailOTP(email: String) async throws {
        box.withLock { $0.sentEmails.append(email) }
        let handler = box.withLock { $0.sendEmailOTPHandler }
        try await handler(email)
    }

    func verifyEmailOTP(email: String, token: String) async throws -> AuthSession {
        box.withLock { $0.verifyAttempts.append((email, token)) }
        let handler = box.withLock { $0.verifyEmailOTPHandler }
        let session = try await handler(email, token)
        box.withLock { $0.currentSession = session }
        return session
    }

    func refreshSession() async throws -> AuthSession {
        guard let session = currentSession else { throw StubError.unconfigured }
        return session
    }

    func signOut() async throws {
        let handler = box.withLock { $0.signOutHandler }
        try await handler()
        box.withLock { $0.currentSession = nil }
    }
}

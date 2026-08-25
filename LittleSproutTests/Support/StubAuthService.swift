import Foundation
@testable import LittleSprout
import os

/// LS-17 的 `AuthStore`／`EmailSignInModel`／`OTPVerificationModel` 測試用假
/// `AuthService`——不打真網路，用可設定的 handler 決定每個方法的行為。跟
/// `MockURLProtocol` 同一套模式（lock 保護的可變 handler，見該檔）。
final class StubAuthService: AuthService, @unchecked Sendable {
    typealias EmailHandler = @Sendable (String) async throws -> Void
    typealias SessionHandler = @Sendable (String, String) async throws -> AuthSession

    enum StubError: Error {
        case unconfigured
    }

    private struct Box {
        var currentSession: AuthSession?
        var sendEmailOTPHandler: EmailHandler = { _ in }
        var verifyEmailOTPHandler: SessionHandler = { _, _ in throw StubError.unconfigured }
        var signInWithAppleHandler: SessionHandler = { _, _ in throw StubError.unconfigured }
        var signOutHandler: @Sendable () async throws -> Void = {}
        var sentEmails: [String] = []
        var verifyAttempts: [(email: String, token: String)] = []
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

    func setSignOutHandler(_ handler: @escaping @Sendable () async throws -> Void) {
        box.withLock { $0.signOutHandler = handler }
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        let handler = box.withLock { $0.signInWithAppleHandler }
        let session = try await handler(idToken, nonce)
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

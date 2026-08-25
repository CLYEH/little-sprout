import Foundation
@testable import LittleSprout
import XCTest

/// 03「輸入驗證碼」狀態機：驗證失敗計次、保留輸入、重寄冷卻。對應 LS-17 scope
/// 「Email OTP 輸入與錯誤（保留輸入＋計次）」這條驗收條件。
@MainActor
final class OTPVerificationModelTests: XCTestCase {
    private let userID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func makeModel(
        maxAttempts: Int = 5,
        cooldownSeconds: Int = 60,
        stub: StubAuthService = StubAuthService()
    ) -> (OTPVerificationModel, StubAuthService) {
        let store = AuthStore(authService: stub)
        let model = OTPVerificationModel(
            email: "grandma@example.com",
            authStore: store,
            maxAttempts: maxAttempts,
            cooldownSeconds: cooldownSeconds
        )
        return (model, stub)
    }

    // MARK: - 輸入

    func test_updateCode_stripsNonDigitsAndCapsAtSix() {
        let (model, _) = makeModel()

        model.updateCode("5a2-8 4b12")

        XCTAssertEqual(model.code, "528412")
    }

    // MARK: - 驗證失敗計次（核心驗收條件）

    func test_verify_incompleteCode_doesNotCallAuthServiceOrConsumeAttempt() async {
        let (model, stub) = makeModel()
        model.updateCode("123")

        let result = await model.verify()

        XCTAssertFalse(result)
        XCTAssertEqual(model.remainingAttempts, 5)
        XCTAssertTrue(stub.verifyAttempts.isEmpty)
    }

    func test_verify_failure_decrementsRemainingAttemptsAndSetsMessage() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        let (model, _) = makeModel(maxAttempts: 5, stub: stub)
        model.updateCode("111111")

        let result = await model.verify()

        XCTAssertFalse(result)
        XCTAssertEqual(model.remainingAttempts, 4)
        XCTAssertEqual(model.errorMessage, "驗證碼不對，還可以再試 4 次")
    }

    func test_verify_failure_keepsEnteredCode() async {
        // 「保留輸入＋計次」：輸錯不清空使用者打的碼（Handoff Notes「OTP 輸錯行為維持既有」）。
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        let (model, _) = makeModel(stub: stub)
        model.updateCode("111111")

        _ = await model.verify()

        XCTAssertEqual(model.code, "111111")
    }

    func test_verify_repeatedFailures_decrementsSequentially() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        let (model, _) = makeModel(maxAttempts: 3, stub: stub)
        model.updateCode("111111")

        _ = await model.verify()
        XCTAssertEqual(model.remainingAttempts, 2)
        _ = await model.verify()
        XCTAssertEqual(model.remainingAttempts, 1)
        _ = await model.verify()
        XCTAssertEqual(model.remainingAttempts, 0)
        XCTAssertEqual(model.errorMessage, "驗證碼不對，還可以再試 0 次")
    }

    func test_verify_afterAttemptsExhausted_doesNotCallAuthServiceAgain() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        let (model, stub2) = makeModel(maxAttempts: 1, stub: stub)
        model.updateCode("111111")
        _ = await model.verify()
        XCTAssertEqual(model.remainingAttempts, 0)
        XCTAssertEqual(stub2.verifyAttempts.count, 1)

        let result = await model.verify()

        XCTAssertFalse(result)
        XCTAssertEqual(stub2.verifyAttempts.count, 1, "次數用盡後不該再打後端")
    }

    func test_verify_success_clearsErrorMessage() async {
        let stub = StubAuthService()
        let expected = AuthSession(userID: userID, email: "grandma@example.com", expiresAt: .distantFuture)
        stub.setVerifyEmailOTPHandler { _, _ in expected }
        let (model, _) = makeModel(stub: stub)
        model.updateCode("528412")

        let result = await model.verify()

        XCTAssertTrue(result)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - 重寄

    func test_resend_success_resetsCodeAttemptsAndCooldown() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        let (model, _) = makeModel(maxAttempts: 5, cooldownSeconds: 60, stub: stub)
        model.updateCode("111111")
        _ = await model.verify()
        XCTAssertEqual(model.remainingAttempts, 4)
        model.tickCooldown()
        model.tickCooldown()
        XCTAssertFalse(model.canResend)

        // 重寄前手動把冷卻歸零，才能通過 `resend()` 的 `canResend` 前置檢查而不必真的等待。
        for _ in 0..<100 { model.tickCooldown() }
        XCTAssertTrue(model.canResend)

        let result = await model.resend()

        XCTAssertTrue(result)
        XCTAssertEqual(model.code, "")
        XCTAssertEqual(model.remainingAttempts, 5)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.resendCooldown, 60)
    }

    func test_resend_whileCoolingDown_doesNotCallAuthService() async {
        let stub = StubAuthService()
        let (model, stub2) = makeModel(cooldownSeconds: 60, stub: stub)
        XCTAssertFalse(model.canResend)

        let result = await model.resend()

        XCTAssertFalse(result)
        XCTAssertTrue(stub2.sentEmails.isEmpty)
    }

    // MARK: - 冷卻倒數（純遞減，不靠真計時器）

    func test_tickCooldown_decrementsAndStopsAtZero() {
        let (model, _) = makeModel(cooldownSeconds: 2)

        model.tickCooldown()
        XCTAssertEqual(model.resendCooldown, 1)
        model.tickCooldown()
        XCTAssertEqual(model.resendCooldown, 0)
        model.tickCooldown()
        XCTAssertEqual(model.resendCooldown, 0, "不會遞減成負數")
    }

    func test_canResend_trueOnlyWhenCooldownReachesZero() {
        let (model, _) = makeModel(cooldownSeconds: 1)
        XCTAssertFalse(model.canResend)

        model.tickCooldown()

        XCTAssertTrue(model.canResend)
    }
}

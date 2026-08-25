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

    // MARK: - 錯誤分流（R2 review M1）

    func test_verify_networkError_doesNotDecrementAttemptsAndUsesUserFacingMessage() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.network(message: "offline") }
        let (model, _) = makeModel(maxAttempts: 5, stub: stub)
        model.updateCode("111111")

        let result = await model.verify()

        XCTAssertFalse(result)
        XCTAssertEqual(model.remainingAttempts, 5, "網路錯誤不是驗證碼的問題，不該扣次數")
        XCTAssertEqual(model.errorMessage, AppError.network(message: "offline").userFacingMessage)
    }

    func test_verify_serverError_doesNotDecrementAttempts() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.server(message: "boom", code: nil) }
        let (model, _) = makeModel(maxAttempts: 5, stub: stub)
        model.updateCode("111111")

        _ = await model.verify()

        XCTAssertEqual(model.remainingAttempts, 5)
        XCTAssertEqual(model.errorMessage, AppError.server(message: "boom", code: nil).userFacingMessage)
    }

    // MARK: - otp_expired／429 不算碼錯（R3 review B3）

    func test_verify_otpExpired_doesNotDecrementAttempts_promptsResend() async {
        // 正式環境實測：碼過期以 403（.rejected 層）回來，不是 400（見 R3 handoff）。
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in
            throw AppError.rejected(message: "token has expired or is invalid", code: "otp_expired")
        }
        let (model, _) = makeModel(maxAttempts: 5, stub: stub)
        model.updateCode("111111")

        let result = await model.verify()

        XCTAssertFalse(result)
        XCTAssertEqual(model.remainingAttempts, 5, "碼過期不是打錯字，不該扣長輩的嘗試次數")
        XCTAssertEqual(model.errorMessage, "這組驗證碼已經過期了，請重新寄一組新的再試。")
    }

    func test_verify_rateLimited_doesNotDecrementAttempts_showsCooldownMessage() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in
            throw AppError.validationRetryable(message: "rate limited", code: "over_request_rate_limit")
        }
        let (model, _) = makeModel(maxAttempts: 5, stub: stub)
        model.updateCode("111111")

        let result = await model.verify()

        XCTAssertFalse(result)
        XCTAssertEqual(model.remainingAttempts, 5, "打太快是頻率限制，不是碼錯，不該扣次數")
        XCTAssertEqual(model.errorMessage, "太多次嘗試了，請稍候一下再試一次。")
    }

    func test_verify_afterAttemptsExhausted_setsClearMessageInsteadOfSilentNoop() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        let (model, _) = makeModel(maxAttempts: 1, stub: stub)
        model.updateCode("111111")
        _ = await model.verify()
        XCTAssertEqual(model.remainingAttempts, 0)

        let result = await model.verify()

        XCTAssertFalse(result)
        XCTAssertNotNil(model.errorMessage, "次數用盡後按下確認登入不能靜默無反應")
        XCTAssertNotEqual(
            model.errorMessage, "驗證碼不對，還可以再試 0 次",
            "應給出可重寄的明確出路，不是沿用舊的計次訊息"
        )
    }

    // MARK: - 重寄／驗證競態（R2 review M2）

    func test_verify_staleFailureAfterResend_doesNotChangeAttemptsOrMessage() async {
        let stub = StubAuthService()
        let (model, _) = makeModel(maxAttempts: 5, cooldownSeconds: 60, stub: stub)
        model.updateCode("111111")
        for _ in 0..<100 { model.tickCooldown() }
        XCTAssertTrue(model.canResend)

        // 模擬「verify 還在飛的時候使用者按了重寄」：resend 在 verify 的後端呼叫回來之前完成。
        stub.setVerifyEmailOTPHandler { _, _ in
            _ = await model.resend()
            throw AppError.validationRetryable(message: "stale", code: nil)
        }

        let result = await model.verify()

        XCTAssertFalse(result)
        XCTAssertEqual(model.remainingAttempts, 5, "resend 已重置次數，遲到的舊碼驗證失敗不得再扣一次")
        XCTAssertEqual(model.code, "", "resend 已清空輸入，遲到的失敗結果不得殘留舊訊息")
        XCTAssertNil(model.errorMessage, "resend 成功已清錯誤，遲到的舊碼失敗不得覆蓋")
    }

    // MARK: - 再入 guard（R2 review M5）

    func test_verify_reentrantCallWhileVerifying_isIgnored() async {
        let stub = StubAuthService()
        let (model, stub2) = makeModel(maxAttempts: 5, stub: stub)
        model.updateCode("111111")
        stub.setVerifyEmailOTPHandler { _, _ in
            _ = await model.verify()
            throw AppError.validationRetryable(message: "bad", code: nil)
        }

        let result = await model.verify()

        XCTAssertFalse(result)
        XCTAssertEqual(stub2.verifyAttempts.count, 1, "isVerifying 時的重入呼叫不該再打一次後端")
        XCTAssertEqual(model.remainingAttempts, 4)
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

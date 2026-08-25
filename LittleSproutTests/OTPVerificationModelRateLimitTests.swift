import Foundation
@testable import LittleSprout
import XCTest

/// LS-92 I-3／R2（PR #155 review R1，`comment 5412440073`）：`resend()` 自己撞
/// `over_email_send_rate_limit`（或裸 429）。跟 `OTPVerificationModelTests` 是同一個測試
/// 對象，拆成獨立檔案純粹是為了 SwiftLint `type_body_length`（250 行）——共用該檔的
/// `makeModel(...)` 測試工廠方法。`verify()` 自己的 429 另見
/// `OTPVerificationModelVerifyRateLimitTests.swift`（R2 F2：兩條冷卻線刻意分開測試，
/// 才能釘住「不互相汙染」這件事本身）。
extension OTPVerificationModelTests {
    func test_resend_emailSendRateLimited_marksResendRateLimitedAndStartsCooldown() async {
        let stub = StubAuthService()
        stub.setSendEmailOTPHandler { _ in
            throw AppError.validationRetryable(message: "Email rate limit exceeded", code: "over_email_send_rate_limit")
        }
        let (model, _) = makeModel(cooldownSeconds: 45, stub: stub)
        for _ in 0..<100 { model.tickCooldown() }
        XCTAssertTrue(model.canResend)

        let result = await model.resend()

        XCTAssertFalse(result)
        XCTAssertTrue(model.isResendRateLimited)
        XCTAssertFalse(model.canResend)
    }

    func test_resend_rateLimited_doesNotResetAttemptsOrClearExistingCode() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        stub.setSendEmailOTPHandler { _ in
            throw AppError.validationRetryable(message: "Email rate limit exceeded", code: "over_email_send_rate_limit")
        }
        let (model, _) = makeModel(maxAttempts: 5, cooldownSeconds: 45, stub: stub)
        model.updateCode("111111")
        _ = await model.verify()
        XCTAssertEqual(model.remainingAttempts, 4)
        for _ in 0..<100 { model.tickCooldown() }

        let result = await model.resend()

        XCTAssertFalse(result)
        XCTAssertEqual(model.remainingAttempts, 4, "resend 失敗（含冷卻）不該動到既有的驗證次數")
        XCTAssertEqual(model.code, "111111", "resend 失敗不該清空既有輸入")
    }

    // MARK: - R2 F1：resend 撞 rate limit 不得清掉次數用盡的鎖定理由

    func test_resend_rateLimited_afterAttemptsExhausted_keepsLockMessageAndLockedState() async {
        // 原 bug 根因：resend() 的 rate-limit 分支曾經無條件清掉共用的 errorMessage，
        // 連「已達上限」這個鎖定理由也一起清掉，使用者會看到輸入還是鎖著、卻找不到原因。
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        let (model, _) = makeModel(maxAttempts: 1, cooldownSeconds: 1, stub: stub)
        model.updateCode("111111")
        _ = await model.verify()
        XCTAssertTrue(model.isLocked)
        let lockMessageBeforeResend = model.lockMessage
        XCTAssertNotNil(lockMessageBeforeResend)
        model.tickCooldown()
        XCTAssertTrue(model.canResend)
        stub.setSendEmailOTPHandler { _ in
            throw AppError.validationRetryable(message: "Email rate limit exceeded", code: "over_email_send_rate_limit")
        }

        let result = await model.resend()

        XCTAssertFalse(result)
        XCTAssertEqual(model.lockMessage, lockMessageBeforeResend, "F1：resend 撞 rate limit 不得清掉鎖定理由")
        XCTAssertTrue(model.isLocked, "次數仍是 0，鎖定狀態不受 resend 失敗影響")
        XCTAssertTrue(model.isResendRateLimited)
    }

    // MARK: - R2 F3：顯示秒數必須來自伺服器訊息，不能是 app 的 60 秒常數

    func test_resend_rateLimited_parsesRealSecondsFromMessage_notAppConstant() async {
        let stub = StubAuthService()
        stub.setSendEmailOTPHandler { _ in
            throw AppError.validationRetryable(
                message: "For security purposes, you can only request this after 17 seconds.",
                code: "over_email_send_rate_limit"
            )
        }
        let (model, _) = makeModel(cooldownSeconds: 60, stub: stub)
        for _ in 0..<100 { model.tickCooldown() }

        _ = await model.resend()

        XCTAssertTrue(model.resendRateLimitSecondsAreReal)
        XCTAssertEqual(model.resendCooldown, 17, "必須顯示伺服器真實秒數，不是 app 的 60 秒常數")
    }

    func test_resend_rateLimited_withoutParseableSeconds_marksSecondsAsNotReal() async {
        let stub = StubAuthService()
        stub.setSendEmailOTPHandler { _ in
            throw AppError.validationRetryable(message: "Email rate limit exceeded", code: "over_email_send_rate_limit")
        }
        let (model, _) = makeModel(cooldownSeconds: 60, stub: stub)
        for _ in 0..<100 { model.tickCooldown() }

        _ = await model.resend()

        XCTAssertFalse(
            model.resendRateLimitSecondsAreReal,
            "沒有可信秒數就不能標成真實——View 端靠這個旗標決定要不要顯示數字"
        )
    }

    func test_resendCooldown_countsDownAndClearsRateLimitFlagsAtZero() async {
        let stub = StubAuthService()
        stub.setSendEmailOTPHandler { _ in
            throw AppError.validationRetryable(
                message: "For security purposes, you can only request this after 2 seconds.",
                code: "over_email_send_rate_limit"
            )
        }
        let (model, _) = makeModel(stub: stub)
        for _ in 0..<100 { model.tickCooldown() }
        _ = await model.resend()
        XCTAssertEqual(model.resendCooldown, 2)

        model.tickCooldown()
        XCTAssertEqual(model.resendCooldown, 1)
        XCTAssertTrue(model.isResendRateLimited)

        model.tickCooldown()
        XCTAssertEqual(model.resendCooldown, 0)
        XCTAssertFalse(model.isResendRateLimited, "冷卻歸零後要解除冷卻狀態")
        XCTAssertFalse(model.resendRateLimitSecondsAreReal)
    }
}

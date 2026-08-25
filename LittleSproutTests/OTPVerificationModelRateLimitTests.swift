import Foundation
@testable import LittleSprout
import XCTest

/// LS-92 I-3：429／`over_request_rate_limit`／`over_email_send_rate_limit` 冷卻。跟
/// `OTPVerificationModelTests` 是同一個測試對象，拆成獨立檔案純粹是為了 SwiftLint
/// `type_body_length`（250 行）——共用該檔的 `makeModel(...)` 測試工廠方法。
extension OTPVerificationModelTests {
    func test_verify_rateLimited_doesNotDecrementAttempts_startsCooldownInsteadOfErrorMessage() async {
        // 429／over_request_rate_limit 是打太快，跟這組碼本身無關，才是唯一不扣次數的情境。
        // I-3：冷卻不是碼錯，不該走 errorMessage／OTP 欄位紅框那條文法，改用既有的
        // resendCooldown 冷卻機制（resendRow 顯示剩餘秒數）。
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in
            throw AppError.validationRetryable(message: "rate limited", code: "over_request_rate_limit")
        }
        let (model, _) = makeModel(maxAttempts: 5, cooldownSeconds: 30, stub: stub)
        model.updateCode("111111")

        let result = await model.verify()

        XCTAssertFalse(result)
        XCTAssertEqual(model.remainingAttempts, 5, "打太快是頻率限制，不是碼錯，不該扣次數")
        XCTAssertNil(model.errorMessage, "冷卻不是碼錯，不該誤觸發 OTP 欄位的紅框文法")
        XCTAssertTrue(model.isRateLimited)
        XCTAssertEqual(model.resendCooldown, 30, "冷卻列要顯示剩餘秒數，起始值就是完整冷卻秒數")
    }

    func test_verify_rateLimited_cooldownCountsDownAndClearsAtZero() async {
        // 顯示剩餘秒數＋秒數會倒數（I-3 驗收條件）；冷卻歸零後解除 isRateLimited，
        // resendRow 自然切回一般「重新寄一次」按鈕（canResend 由同一個 resendCooldown 驅動）。
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in
            throw AppError.validationRetryable(message: "rate limited", code: "over_request_rate_limit")
        }
        let (model, _) = makeModel(cooldownSeconds: 2, stub: stub)
        model.updateCode("111111")
        _ = await model.verify()
        XCTAssertEqual(model.resendCooldown, 2)

        model.tickCooldown()
        XCTAssertEqual(model.resendCooldown, 1)
        XCTAssertTrue(model.isRateLimited)

        model.tickCooldown()
        XCTAssertEqual(model.resendCooldown, 0)
        XCTAssertFalse(model.isRateLimited, "冷卻歸零後要解除冷卻狀態")
    }

    func test_resend_emailSendRateLimited_startsCooldownWithoutResettingAttemptsOrCode() async {
        // over_email_send_rate_limit 發生在 resend() 本身（寄信寄太頻繁），跟 verify() 打太快
        // 是同一條冷卻機制、不同 call site（I-3）：不扣既有次數、不清既有輸入。
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        stub.setSendEmailOTPHandler { _ in
            throw AppError.validationRetryable(message: "rate limited", code: "over_email_send_rate_limit")
        }
        let (model, _) = makeModel(maxAttempts: 5, cooldownSeconds: 45, stub: stub)
        model.updateCode("111111")
        _ = await model.verify()
        XCTAssertEqual(model.remainingAttempts, 4)
        for _ in 0..<100 { model.tickCooldown() }
        XCTAssertTrue(model.canResend)

        let result = await model.resend()

        XCTAssertFalse(result)
        XCTAssertEqual(model.remainingAttempts, 4, "resend 失敗（含冷卻）不該動到既有的驗證次數")
        XCTAssertEqual(model.code, "111111", "resend 失敗不該清空既有輸入")
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isRateLimited)
        XCTAssertEqual(model.resendCooldown, 45)
    }
}

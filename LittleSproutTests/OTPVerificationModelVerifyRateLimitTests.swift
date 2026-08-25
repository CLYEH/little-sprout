import Foundation
@testable import LittleSprout
import XCTest

/// LS-92 R2（PR #155 review R1，`comment 5412440073`）F2／F3／F4：`verify()` 自己撞
/// `over_request_rate_limit`（或裸 429）。跟 `OTPVerificationModelTests` 是同一個測試對象，
/// 拆成獨立檔案純粹是為了 SwiftLint `type_body_length`（250 行）——共用該檔的
/// `makeModel(...)` 測試工廠方法。`resend()` 自己的 429 另見
/// `OTPVerificationModelRateLimitTests.swift`。
extension OTPVerificationModelTests {
    // MARK: - R2 F2：verify() 的 429 完全不碰 resendCooldown

    func test_verify_rateLimited_doesNotTouchResendCooldown() async {
        // 原 bug 根因：verify() 的 429 曾經呼叫跟 resend() 共用的 `beginRateLimitCooldown()`，
        // 把 resendCooldown 重設回滿格——等於每按一次「確認登入」就把「重新寄一次」往後推。
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in
            throw AppError.validationRetryable(message: "please wait", code: "over_request_rate_limit")
        }
        let (model, _) = makeModel(cooldownSeconds: 60, stub: stub)
        model.updateCode("111111")
        for _ in 0..<55 { model.tickCooldown() }
        XCTAssertEqual(model.resendCooldown, 5)

        _ = await model.verify()

        XCTAssertEqual(model.resendCooldown, 5, "verify() 的 429 不該動到 resendCooldown")
        XCTAssertFalse(model.canResend, "更不該把已經快到的冷卻推回滿格、餓死「重新寄一次」")
        XCTAssertFalse(model.isResendRateLimited, "這是 verify() 的頻率限制，不是 resend() 的")
    }

    func test_verify_rateLimited_withRealCountdown_guardsRepeatedBackendCalls() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in
            throw AppError.validationRetryable(
                message: "For security purposes, you can only request this after 30 seconds.",
                code: "over_request_rate_limit"
            )
        }
        let (model, stub2) = makeModel(stub: stub)
        model.updateCode("111111")

        _ = await model.verify()
        XCTAssertEqual(stub2.verifyAttempts.count, 1)
        XCTAssertEqual(model.verifyRateLimitSecondsRemaining, 30)

        let secondResult = await model.verify()

        XCTAssertFalse(secondResult)
        XCTAssertEqual(stub2.verifyAttempts.count, 1, "真實倒數還在時，按下確認登入不該再打一次後端")
    }

    func test_verify_rateLimited_countdownTicksDownAndClearsAtZero() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in
            throw AppError.validationRetryable(
                message: "For security purposes, you can only request this after 2 seconds.",
                code: "over_request_rate_limit"
            )
        }
        let (model, _) = makeModel(stub: stub)
        model.updateCode("111111")
        _ = await model.verify()
        XCTAssertEqual(model.verifyRateLimitSecondsRemaining, 2)

        model.tickVerifyRateLimit()
        XCTAssertEqual(model.verifyRateLimitSecondsRemaining, 1)

        model.tickVerifyRateLimit()
        XCTAssertNil(model.verifyRateLimitSecondsRemaining, "倒數歸零後要解除，讓下一次 verify() 可以再打後端")
    }

    // MARK: - R2 F3：顯示秒數必須來自伺服器訊息，不能是 app 的常數；沒有就不編數字也不擋人

    func test_verify_rateLimited_parsesRealSecondsFromMessage_notAppConstant() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in
            throw AppError.validationRetryable(
                message: "For security purposes, you can only request this after 42 seconds.",
                code: "over_request_rate_limit"
            )
        }
        let (model, _) = makeModel(cooldownSeconds: 60, stub: stub)
        model.updateCode("111111")

        _ = await model.verify()

        XCTAssertEqual(model.verifyRateLimitSecondsRemaining, 42, "必須用伺服器訊息的真實秒數，不能是 app 的 60 常數")
    }

    func test_verify_rateLimited_withoutParseableSeconds_doesNotFabricateCountdownOrBlockRetry() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in
            throw AppError.validationRetryable(message: "Request rate limit reached", code: "over_request_rate_limit")
        }
        let (model, stub2) = makeModel(cooldownSeconds: 60, stub: stub)
        model.updateCode("111111")

        _ = await model.verify()

        XCTAssertEqual(model.verifyRateLimitSecondsRemaining, 0, "沒有可信秒數就不編數字，用 0 代表「有訊息、不倒數」")

        let secondResult = await model.verify()

        XCTAssertFalse(secondResult)
        XCTAssertEqual(stub2.verifyAttempts.count, 2, "沒有真實秒數就不該假裝在擋，下一次 verify() 應該能再打後端")
    }

    // MARK: - R2 F4：裸 429（無法解析出 error_code）不扣次

    func test_verify_bareHTTP429_doesNotConsumeAttempt() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in
            throw AppError.validationRetryable(message: "Too Many Requests", code: "bare_http_429")
        }
        let (model, _) = makeModel(maxAttempts: 5, stub: stub)
        model.updateCode("111111")

        _ = await model.verify()

        XCTAssertEqual(model.remainingAttempts, 5, "裸 429 不該扣使用者的嘗試次數")
    }
}

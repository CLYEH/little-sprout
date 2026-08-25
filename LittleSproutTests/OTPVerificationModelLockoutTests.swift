import Foundation
@testable import LittleSprout
import XCTest

/// LS-92 I-2：次數用盡輸入鎖定。跟 `OTPVerificationModelTests` 是同一個測試對象，拆成
/// 獨立檔案純粹是為了 SwiftLint `type_body_length`（250 行）——共用該檔的 `makeModel(...)`
/// 測試工廠方法（已改為非 `private` 供本檔 extension 呼叫）。
extension OTPVerificationModelTests {
    func test_verify_attemptsExhausted_locksInput() async {
        // 「已達上限」不只是換句話，還要讓輸入跟著鎖定——不然使用者會繼續打新號碼，
        // 以為還能重試，實際上 verify() 早就被 guard 擋住了。
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        let (model, _) = makeModel(maxAttempts: 1, stub: stub)
        model.updateCode("111111")

        _ = await model.verify()

        XCTAssertTrue(model.isLocked)
        model.updateCode("222222")
        XCTAssertEqual(model.code, "111111", "次數用盡後輸入鎖定，不該再接受新的按鍵輸入")
    }

    // MARK: - 鎖定時仍允許退格（R2，LS-92 PR #155 review R1 F5）

    func test_updateCode_whenLocked_allowsBackspaceToShortenOrClear() async {
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        let (model, _) = makeModel(maxAttempts: 1, stub: stub)
        model.updateCode("111111")
        _ = await model.verify()
        XCTAssertTrue(model.isLocked)

        model.updateCode("11111")
        XCTAssertEqual(model.code, "11111", "F5：鎖定時仍要放行退格（刪掉尾端字元）")

        model.updateCode("")
        XCTAssertEqual(model.code, "", "F5：鎖定時仍要放行清空")
    }

    func test_updateCode_whenLocked_blocksReplacingWithDifferentCode() async {
        // 跟純退格不同：置換成完全不同的一串數字（即使長度相同或更短）不該放行——
        // 使用者在次數用盡後打的任何「新猜測」都沒有意義，只有刪字例外。
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        let (model, _) = makeModel(maxAttempts: 1, stub: stub)
        model.updateCode("111111")
        _ = await model.verify()
        model.updateCode("111")
        XCTAssertEqual(model.code, "111")

        model.updateCode("121")

        XCTAssertEqual(model.code, "111", "F5：置換數字（非單純刪字）鎖定時仍要擋下")
    }

    func test_updateCode_whenLocked_blockedAttemptIncrementsFeedbackTick() async {
        // F5：被擋下的按鍵要讓 View 能觸發回饋（震動／訊息輕微強調），不讓長輩以為鍵盤壞了。
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        let (model, _) = makeModel(maxAttempts: 1, stub: stub)
        model.updateCode("111111")
        _ = await model.verify()
        let before = model.lockedInputFeedbackTick

        model.updateCode("222222")

        XCTAssertEqual(model.lockedInputFeedbackTick, before + 1)

        model.updateCode("11111") // 退格不算被擋下，tick 不該再動
        XCTAssertEqual(model.lockedInputFeedbackTick, before + 1)
    }

    func test_resend_whileAttemptsLocked_stillSucceedsAndUnlocksInput() async {
        // 「重寄入口可用」（I-2 驗收條件）：次數用盡鎖定只擋 updateCode／後續 verify()，
        // 不能連重寄這條唯一出路都一併擋掉；重寄成功後次數重置，鎖定要跟著解除。
        let stub = StubAuthService()
        stub.setVerifyEmailOTPHandler { _, _ in throw AppError.validationRetryable(message: "bad", code: nil) }
        let (model, _) = makeModel(maxAttempts: 1, cooldownSeconds: 1, stub: stub)
        model.updateCode("111111")
        _ = await model.verify()
        XCTAssertTrue(model.isLocked)
        model.tickCooldown()
        XCTAssertTrue(model.canResend)

        let result = await model.resend()

        XCTAssertTrue(result)
        XCTAssertFalse(model.isLocked, "重寄成功後次數重置為滿額，輸入鎖定隨之解除")
        XCTAssertEqual(model.code, "")
    }
}

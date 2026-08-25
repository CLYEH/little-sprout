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

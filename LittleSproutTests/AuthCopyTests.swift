@testable import LittleSprout
import XCTest

/// LS-499：Email OTP 有效期文案與後端（`otp_expiry = 3600`）一致，且只有一個真值來源。
final class AuthCopyTests: XCTestCase {
    func testOTPValidityTextMatchesBackendOneHour() {
        XCTAssertEqual(AuthCopy.otpValiditySeconds, 3600, "後端 config.toml otp_expiry = 3600")
        XCTAssertTrue(AuthCopy.otpValidityText.contains("1 小時"), "實際：\(AuthCopy.otpValidityText)")
    }

    func testEmailPageAndOTPPageUseSharedValidityText() {
        XCTAssertEqual(AuthCopy.emailHelpText, "驗證碼會寄到這個信箱，1 小時內有效。")
        XCTAssertEqual(AuthCopy.otpFooterNote(hasMessages: false), "驗證碼 1 小時內有效。找不到信時，請看一下垃圾郵件匣。")
        XCTAssertTrue(AuthCopy.otpFooterNote(hasMessages: true).contains("1 小時內有效"))
        XCTAssertFalse(AuthCopy.emailHelpText.contains("10 分鐘"))
    }
}

import Foundation

/// 登入流程共用文案。Email OTP 有效期只在這裡定義一次（LS-499）：後端真值是
/// `supabase/config.toml` 的 `otp_expiry = 3600`（正式站 `mailer_otp_exp = 3600`），
/// 後端改了只要同步改 `otpValiditySeconds`，三個畫面的文案自動跟著變。
enum AuthCopy {
    static let otpValiditySeconds = 3600

    /// 3600 → 「1 小時」；非整小時用「N 分鐘」。
    static var otpValidityText: String {
        if otpValiditySeconds % 3600 == 0 {
            return "\(otpValiditySeconds / 3600) 小時"
        }
        return "\(otpValiditySeconds / 60) 分鐘"
    }

    static var emailHelpText: String {
        "驗證碼會寄到這個信箱，\(otpValidityText)內有效。"
    }

    static func otpFooterNote(hasMessages: Bool) -> String {
        hasMessages
            ? "驗證碼 \(otpValidityText)內有效。沒看到信？看一下垃圾郵件匣。"
            : "驗證碼 \(otpValidityText)內有效。找不到信時，請看一下垃圾郵件匣。"
    }
}

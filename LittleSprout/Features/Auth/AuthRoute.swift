import Foundation

/// 歡迎頁之後的登入子路由（Email 輸入 → OTP 驗證）。
enum AuthRoute: Hashable {
    case emailInput
    case otpVerification(email: String)
}

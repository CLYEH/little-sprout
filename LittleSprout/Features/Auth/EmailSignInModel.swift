import Foundation
import Observation

/// 02「輸入信箱」畫面的狀態機。格式錯誤（02b）純粹是客戶端檢查，不打後端；打後端失敗
/// （網路／伺服器錯誤）則顯示 `AppError.userFacingMessage`，兩種訊息來源不同但共用同一個
/// `errorMessage` 欄位與同一段錯誤態版式（Handoff Notes「錯誤態文法」）。
@MainActor
@Observable
final class EmailSignInModel {
    private let authStore: AuthStore

    private(set) var email: String = ""
    private(set) var isSending = false
    private(set) var errorMessage: String?

    init(authStore: AuthStore) {
        self.authStore = authStore
    }

    /// LS-156：貼上帶前後空白／換行的 email 時，`EmailFormat.isValid` 可能放行未 trim 的
    /// 原始字串，讓 GoTrue 收到帶空白的值回泛用 400。格式驗證與 `sendEmailOTP` 統一改用
    /// 這個 trimmed 值；`EmailSignInView` 導到下一頁時也用它（不是 `email`），確保
    /// `OTPVerificationView` 的 `verifyEmailOTP` 路徑收到的是同一個值，寄碼與驗證不會不一致。
    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateEmail(_ newValue: String) {
        email = newValue
        errorMessage = nil
    }

    @discardableResult
    func sendCode() async -> Bool {
        guard !isSending else { return false }
        guard EmailFormat.isValid(trimmedEmail) else {
            errorMessage = "這個 Email 好像沒打完，請再看一次，格式像 name@example.com"
            return false
        }
        isSending = true
        defer { isSending = false }
        do {
            try await authStore.sendEmailOTP(email: trimmedEmail)
            return true
        } catch {
            errorMessage = AppError.map(error).userFacingMessage
            return false
        }
    }
}

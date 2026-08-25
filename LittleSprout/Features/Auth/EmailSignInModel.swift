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

    func updateEmail(_ newValue: String) {
        email = newValue
        errorMessage = nil
    }

    @discardableResult
    func sendCode() async -> Bool {
        guard !isSending else { return false }
        guard EmailFormat.isValid(email) else {
            errorMessage = "這個 Email 好像沒打完，請再看一次，格式像 name@example.com"
            return false
        }
        isSending = true
        defer { isSending = false }
        do {
            try await authStore.sendEmailOTP(email: email)
            return true
        } catch {
            errorMessage = AppError.map(error).userFacingMessage
            return false
        }
    }
}

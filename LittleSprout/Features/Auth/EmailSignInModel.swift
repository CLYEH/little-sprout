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
    /// LS-156 R2（merge-review R1 F1）：`sendCode()` 這次呼叫實際送出去的 email。輸入框
    /// 在送出中未被禁用，`email` 可能在 `await authStore.sendEmailOTP` 期間被使用者改寫——
    /// `EmailSignInView` 不能等 `sendCode()` 回來後再重讀 `trimmedEmail` 轉送給下一頁
    /// （那會讀到改寫後的新值，跟已經寄出去的碼對不上，見 R1 handoff 情境重現）。這裡由
    /// model 記下「驗證通過並真正送出」那個時間點的值，View 端改用這個值呼叫
    /// `onCodeSent`，讓寄碼與 verify 拿到同一個字串。
    private(set) var lastSentEmail: String?

    init(authStore: AuthStore) {
        self.authStore = authStore
    }

    /// LS-156：貼上帶前後空白／換行的 email 時，`EmailFormat.isValid` 可能放行未 trim 的
    /// 原始字串，讓 GoTrue 收到帶空白的值回泛用 400。格式驗證與 `sendEmailOTP` 統一改用
    /// 這個 trimmed 值（見 `sendCode()` 內的 `sending`）。
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
        // R1 F1：只在這裡求值一次，`await` 之後不再重讀 `trimmedEmail`——避免使用者在網路
        // 往返期間改寫 `email`，讓「驗證通過的值」與「實際送出的值」出現落差。
        let sending = trimmedEmail
        guard EmailFormat.isValid(sending) else {
            errorMessage = "這個 Email 好像沒打完，請再看一次，格式像 name@example.com"
            return false
        }
        isSending = true
        defer { isSending = false }
        do {
            try await authStore.sendEmailOTP(email: sending)
            lastSentEmail = sending
            return true
        } catch {
            errorMessage = AppError.map(error).userFacingMessage
            return false
        }
    }
}

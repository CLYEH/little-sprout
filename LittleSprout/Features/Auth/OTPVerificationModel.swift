import Foundation
import Observation

/// 03「輸入驗證碼」畫面的狀態機：驗證失敗計次、重寄冷卻倒數。
///
/// 輸錯行為（03b）維持既有設計：保留輸入內容＋顯示剩餘次數，不清空（Handoff Notes
/// 「OTP 輸錯行為維持既有」段）——`recordFailure()` 只遞減 `remainingAttempts`，不動 `code`。
/// 重寄才會清空並重置次數（新的一組碼理應重新給滿次數）。
@MainActor
@Observable
final class OTPVerificationModel {
    let email: String
    let maxAttempts: Int
    let cooldownSeconds: Int

    private let authStore: AuthStore

    private(set) var code: String = ""
    private(set) var remainingAttempts: Int
    private(set) var errorMessage: String?
    private(set) var isVerifying = false
    private(set) var isResending = false
    private(set) var resendCooldown: Int
    /// 沒有配 `deinit` 取消它：`@MainActor` class 的 `deinit` 不能同步存取 isolated 屬性，
    /// 這裡改用 `[weak self]`（見 `startCooldown()`）——model 被釋放後迴圈下一次
    /// `guard let self` 就會自然結束，不需要額外的取消路徑。
    private var cooldownTask: Task<Void, Never>?
    /// 每次 `resend()` 成功遞增的世代計數。`verify()` 在 await 前記下當時的世代，await 回來後
    /// 若世代已變（代表使用者在等待期間重寄了新碼），整包結果（成功／失敗）都要丟棄，不能
    /// 用舊碼的驗證結果去污染新碼的 `remainingAttempts`／`errorMessage`（R2 review M2）。
    private var codeGeneration = 0

    init(email: String, authStore: AuthStore, maxAttempts: Int = 5, cooldownSeconds: Int = 60) {
        self.email = email
        self.authStore = authStore
        self.maxAttempts = maxAttempts
        self.cooldownSeconds = cooldownSeconds
        remainingAttempts = maxAttempts
        resendCooldown = cooldownSeconds
    }

    var canResend: Bool { resendCooldown <= 0 }
    var isCodeComplete: Bool { code.count == 6 }

    func updateCode(_ newValue: String) {
        code = String(newValue.filter(\.isNumber).prefix(6))
    }

    /// 錯誤先依 `AppError` 四層文法分流才決定要不要扣次數：只有真的是「這組碼不對」
    /// （`.validationRetryable`／`.rejected`）才算使用者用掉一次機會；`.network`／
    /// `.retryableSystem`／`.server` 是環境或系統的問題，不是碼錯，不該扣長輩的嘗試次數
    /// （R2 review M1——電梯／收訊死角按下確認登入時，網路錯誤原本會被誤判成碼錯）。
    @discardableResult
    func verify() async -> Bool {
        guard !isVerifying, isCodeComplete else { return false }
        guard remainingAttempts > 0 else {
            errorMessage = "已經試了 \(maxAttempts) 次，請重新寄一組驗證碼再試。"
            return false
        }
        isVerifying = true
        defer { isVerifying = false }
        let generationAtStart = codeGeneration
        do {
            try await authStore.verifyEmailOTP(email: email, token: code)
            // 驗證中若使用者已重寄新碼，這個成功結果對應的是舊碼，不該用來放行（見 resend()）。
            guard generationAtStart == codeGeneration else { return false }
            errorMessage = nil
            return true
        } catch {
            // 同上：世代已變就整包丟棄，不動 remainingAttempts／errorMessage（R2 review M2）。
            guard generationAtStart == codeGeneration else { return false }
            applyVerificationFailure(error)
            return false
        }
    }

    /// 這幾個後端錯誤碼不是「這組碼打錯了」——即使打的碼完全正確也會出現，不該算使用者
    /// 用掉一次嘗試（R3 review B3）：`otp_expired` 是碼本身過期（在 `.validationRetryable`
    /// 或 `.rejected` 都觀察到過，見 `AppErrorTests` 400 案例與正式環境實測的 403 案例，
    /// `mapAPIStatus` 只依 HTTP 狀態碼分層、不看 `code`），三個 rate-limit 碼是打太快，
    /// 兩者都該提示使用者換一個動作（重寄／等一下），不是暗示「碼打錯了」。
    private static let nonAttemptConsumingCodes: Set<String> = [
        "otp_expired",
        "over_request_rate_limit",
        "over_email_send_rate_limit",
        "over_sms_send_rate_limit"
    ]

    private func applyVerificationFailure(_ error: Error) {
        let appError = AppError.map(error)
        switch appError {
        case .validationRetryable(_, let code), .rejected(_, let code):
            if let code, Self.nonAttemptConsumingCodes.contains(code) {
                errorMessage = message(forNonAttemptConsumingCode: code)
            } else {
                recordFailure()
            }
        case .network, .retryableSystem, .server:
            errorMessage = appError.userFacingMessage
        }
    }

    private func message(forNonAttemptConsumingCode code: String) -> String {
        switch code {
        case "otp_expired":
            return "這組驗證碼已經過期了，請重新寄一組新的再試。"
        default:
            return "太多次嘗試了，請稍候一下再試一次。"
        }
    }

    private func recordFailure() {
        remainingAttempts = max(0, remainingAttempts - 1)
        errorMessage = "驗證碼不對，還可以再試 \(remainingAttempts) 次"
    }

    @discardableResult
    func resend() async -> Bool {
        guard canResend, !isResending else { return false }
        isResending = true
        defer { isResending = false }
        do {
            try await authStore.sendEmailOTP(email: email)
            codeGeneration += 1
            code = ""
            remainingAttempts = maxAttempts
            errorMessage = nil
            startCooldown()
            return true
        } catch {
            errorMessage = AppError.map(error).userFacingMessage
            return false
        }
    }

    func startCooldown() {
        resendCooldown = cooldownSeconds
        cooldownTask?.cancel()
        cooldownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.resendCooldown > 0 else { return }
                self.tickCooldown()
            }
        }
    }

    /// 冷卻倒數的一次遞減，跟驅動它的計時器（`startCooldown()`）分開，測試才能不靠真的
    /// `Task.sleep` 就驗證倒數邏輯（Rule 5：不用模型跑計時器測試，用確定性的呼叫）。
    func tickCooldown() {
        resendCooldown = max(0, resendCooldown - 1)
    }
}

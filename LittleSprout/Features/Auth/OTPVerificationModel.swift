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

    @discardableResult
    func verify() async -> Bool {
        guard isCodeComplete, remainingAttempts > 0 else { return false }
        isVerifying = true
        defer { isVerifying = false }
        do {
            try await authStore.verifyEmailOTP(email: email, token: code)
            errorMessage = nil
            return true
        } catch {
            recordFailure()
            return false
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
            guard let self else { return }
            while !Task.isCancelled && self.resendCooldown > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
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

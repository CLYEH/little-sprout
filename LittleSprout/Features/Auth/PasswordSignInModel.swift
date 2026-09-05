import Foundation
import Observation

/// LS-164 / P1 帳號密碼登入的狀態機（審核帳號用，方案 B）——只有 admin API 建立的指定帳號能用，
/// app 內沒有任何密碼註冊入口。
///
/// 錯誤態分兩種、版面位置不同（LS-163 核可頁 P1c／P1d 板）：
/// - 帳號或密碼錯誤（`AppError.validationRetryable`，涵蓋 `invalid_credentials` 與泛用 400）：
///   Email／密碼兩欄一起變紅（不指名哪一個錯，避免被用來猜帳號），單一文案「帳號或密碼錯誤，
///   請再試一次。」顯示在密碼欄正下方（`isCredentialsError`）。
/// - 其他錯誤（網路／伺服器…）：欄位維持一般樣式，`AppError.userFacingMessage` 顯示在畫面下方、
///   登入鈕正上方（既有 `AppError` 文案，不另外造字——票文 scope 1 明記「網路錯誤沿用既有
///   AppError」）。
@MainActor
@Observable
final class PasswordSignInModel {
    private let authStore: AuthStore

    private(set) var email: String = ""
    private(set) var password: String = ""
    private(set) var isSigningIn = false
    private(set) var errorMessage: String?
    private(set) var isCredentialsError = false

    init(authStore: AuthStore) {
        self.authStore = authStore
    }

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateEmail(_ newValue: String) {
        email = newValue
        clearError()
    }

    func updatePassword(_ newValue: String) {
        password = newValue
        clearError()
    }

    private func clearError() {
        errorMessage = nil
        isCredentialsError = false
    }

    /// 空欄位不送出（票文驗收）：沒有對應的設計態，靜默不動作即可，同 `EmailSignInModel.
    /// sendCode()` 對再入呼叫的處理方式（提早 return，不顯示任何錯誤）。
    @discardableResult
    func signIn() async -> Bool {
        guard !isSigningIn else { return false }
        let signingEmail = trimmedEmail
        guard !signingEmail.isEmpty, !password.isEmpty else { return false }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await authStore.signInWithPassword(email: signingEmail, password: password)
            return true
        } catch {
            apply(AppError.map(error))
            return false
        }
    }

    private func apply(_ appError: AppError) {
        if case .validationRetryable = appError {
            isCredentialsError = true
            errorMessage = "帳號或密碼錯誤，請再試一次。"
        } else {
            isCredentialsError = false
            errorMessage = appError.userFacingMessage
        }
    }
}

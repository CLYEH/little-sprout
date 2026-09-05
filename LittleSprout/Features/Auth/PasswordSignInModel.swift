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

    /// 空欄位不送出（票文驗收）；merge-review R1 N3：純粹提早 return 讓主 CTA 按下去毫無反應，
    /// 跟姊妹畫面 `EmailSignInModel.sendCode()`（格式錯會給「這個 Email 好像沒打完…」）行為不
    /// 一致——稿面沒有這個態，這裡不動欄位紅框（`isCredentialsError` 維持 false），只補一句
    /// 提示，走跟網路錯誤同一個「登入鈕上方」版面位置。
    @discardableResult
    func signIn() async -> Bool {
        guard !isSigningIn else { return false }
        let signingEmail = trimmedEmail
        guard !signingEmail.isEmpty, !password.isEmpty else {
            errorMessage = "請輸入帳號與密碼。"
            return false
        }
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

    /// merge-review R1 N1：`AppError.mapAPIStatus` 把 400／404／422／429 全部歸進
    /// `.validationRetryable`（見該檔），429 還帶 `code: "bare_http_429"` sentinel——這裡原本
    /// 拿整個 tier 當「帳密錯誤」的判準太寬，審核人員撞限流（或裸 429／404）時會被導向「一直
    /// 重試密碼」，跟 `OTPVerificationModel.nonAttemptConsumingCodes` 要防的是同一類事故。
    /// 限流碼排除在外，落到跟其他非帳密錯誤共用的分支——沿用同一句 `appError.userFacingMessage`，
    /// 不新造文案。
    private static let rateLimitCodes: Set<String> = ["over_request_rate_limit", "bare_http_429"]

    private func apply(_ appError: AppError) {
        if case .validationRetryable(_, let code) = appError, !Self.isRateLimited(code) {
            isCredentialsError = true
            errorMessage = "帳號或密碼錯誤，請再試一次。"
        } else {
            isCredentialsError = false
            errorMessage = appError.userFacingMessage
        }
    }

    private static func isRateLimited(_ code: String?) -> Bool {
        guard let code else { return false }
        return rateLimitCodes.contains(code)
    }
}

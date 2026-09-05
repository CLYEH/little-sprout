@testable import LittleSprout
import XCTest

/// LS-164 / P1 帳號密碼登入（審核帳號用，方案 B）狀態機測試。
@MainActor
final class PasswordSignInModelTests: XCTestCase {
    private let userID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func test_signIn_success_updatesStoreSessionAndReturnsTrue() async {
        let stub = StubAuthService()
        let expected = AuthSession(userID: userID, email: "reviewer@example.com", expiresAt: .distantFuture)
        stub.setSignInWithPasswordHandler { _, _ in expected }
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updateEmail("reviewer@example.com")
        model.updatePassword("correct-horse-battery-staple")

        let result = await model.signIn()

        XCTAssertTrue(result)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(store.session, expected)
    }

    // 票文 scope 1：`invalid_credentials`／400 一律映成單一文案，不指名哪一個錯——
    // `AppError.map` 對 400 的一般分流結果是 `.validationRetryable`（見 `AppError.swift`
    // `mapAPIStatus`），這裡直接注入這一類錯誤，不依賴真的 Auth SDK 型別。
    func test_signIn_invalidCredentials_showsSingleMessageAndMarksFieldsAsCredentialsError() async {
        let stub = StubAuthService()
        stub.setSignInWithPasswordHandler { _, _ in
            throw AppError.validationRetryable(message: "Invalid login credentials", code: "invalid_credentials")
        }
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updateEmail("reviewer@example.com")
        model.updatePassword("wrong-password")

        let result = await model.signIn()

        XCTAssertFalse(result)
        XCTAssertEqual(model.errorMessage, "帳號或密碼錯誤，請再試一次。")
        XCTAssertTrue(model.isCredentialsError, "帳密錯誤時 Email／密碼欄要一起變紅")
        XCTAssertNil(store.session)
    }

    func test_signIn_bare400WithoutCode_stillShowsSingleCredentialsMessage() async {
        // 泛用 400（沒有結構化 error code，見 AppError.mapAPIStatus）同樣要落在「帳號或密碼
        // 錯誤」——不只認 invalid_credentials 這個字面碼。
        let stub = StubAuthService()
        stub.setSignInWithPasswordHandler { _, _ in
            throw AppError.validationRetryable(message: "Bad Request", code: nil)
        }
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updateEmail("reviewer@example.com")
        model.updatePassword("wrong-password")

        _ = await model.signIn()

        XCTAssertEqual(model.errorMessage, "帳號或密碼錯誤，請再試一次。")
        XCTAssertTrue(model.isCredentialsError)
    }

    // 票文 scope 1：網路錯誤沿用既有 AppError 文案，不是帳密錯誤那句——版面位置也不同
    // （PasswordSignInView 顯示在登入鈕上方，不是欄位下方，見 `isCredentialsError`）。
    func test_signIn_networkFailure_showsExistingAppErrorMessageWithoutMarkingCredentialsError() async {
        let stub = StubAuthService()
        stub.setSignInWithPasswordHandler { _, _ in throw AppError.network(message: "offline") }
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updateEmail("reviewer@example.com")
        model.updatePassword("correct-horse-battery-staple")

        let result = await model.signIn()

        XCTAssertFalse(result)
        XCTAssertEqual(model.errorMessage, AppError.network(message: "offline").userFacingMessage)
        XCTAssertFalse(model.isCredentialsError, "網路錯誤不該讓欄位變紅——那是帳密錯誤才有的視覺")
        XCTAssertNil(store.session)
    }

    func test_signIn_emptyEmail_doesNotCallAuthService() async {
        let stub = StubAuthService()
        stub.setSignInWithPasswordHandler { _, _ in
            XCTFail("空欄位不該打到 AuthService")
            throw StubAuthService.StubError.unconfigured
        }
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updatePassword("some-password")

        let result = await model.signIn()

        XCTAssertFalse(result)
        // merge-review R1 N3：稿面沒有這個態，但主 CTA 按下去不能毫無反應（跟姊妹畫面
        // EmailSignInModel.sendCode() 對齊）；欄位仍維持一般樣式，不是帳密錯誤。
        XCTAssertEqual(model.errorMessage, "請輸入帳號與密碼。")
        XCTAssertFalse(model.isCredentialsError)
    }

    func test_signIn_emptyPassword_doesNotCallAuthService() async {
        let stub = StubAuthService()
        stub.setSignInWithPasswordHandler { _, _ in
            XCTFail("空欄位不該打到 AuthService")
            throw StubAuthService.StubError.unconfigured
        }
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updateEmail("reviewer@example.com")

        let result = await model.signIn()

        XCTAssertFalse(result)
        XCTAssertEqual(model.errorMessage, "請輸入帳號與密碼。")
    }

    func test_signIn_whitespaceOnlyEmail_treatedAsEmpty() async {
        // trimmedEmail 同 EmailSignInModel 的既有理由——純空白不算「有填」。
        let stub = StubAuthService()
        stub.setSignInWithPasswordHandler { _, _ in
            XCTFail("空欄位（純空白）不該打到 AuthService")
            throw StubAuthService.StubError.unconfigured
        }
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updateEmail("   ")
        model.updatePassword("some-password")

        let result = await model.signIn()

        XCTAssertFalse(result)
        XCTAssertEqual(model.errorMessage, "請輸入帳號與密碼。")
    }

    func test_updateEmail_clearsPreviousError() async {
        let stub = StubAuthService()
        stub.setSignInWithPasswordHandler { _, _ in throw AppError.network(message: "offline") }
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updateEmail("reviewer@example.com")
        model.updatePassword("wrong")
        _ = await model.signIn()
        XCTAssertNotNil(model.errorMessage)

        model.updateEmail("reviewer2@example.com")

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isCredentialsError)
    }

    func test_updatePassword_clearsPreviousCredentialsError() async {
        let stub = StubAuthService()
        stub.setSignInWithPasswordHandler { _, _ in
            throw AppError.validationRetryable(message: "Invalid login credentials", code: "invalid_credentials")
        }
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updateEmail("reviewer@example.com")
        model.updatePassword("wrong")
        _ = await model.signIn()
        XCTAssertTrue(model.isCredentialsError)

        model.updatePassword("try-again")

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isCredentialsError)
    }

    func test_signIn_reentrantCallWhileSigningIn_isIgnored() async {
        // 同 EmailSignInModel.sendCode() 既有的再入 guard（R2 review M5 那條規則）：登入進行中
        // 再被觸發一次（例如鍵盤 Go 鍵與主按鈕重疊觸發）不該再打一次後端。呼叫次數靠
        // `stub.passwordSignInAttempts`（測試替身自己記錄）斷言，不靠捕捉一個可變區域變數——
        // `SessionHandler` 是 `@Sendable` closure，不能捕捉可變 var（同 `EmailSignInModelTests`
        // 用 `stub.sentEmails` 斷言次數的既有理由）。
        //
        // merge-review R1 N4（mutation 3 實測）：拿掉 `signIn()` 的 `guard !isSigningIn` 之後，
        // handler 裡原本無條件的 `_ = await model.signIn()` 會遞迴呼叫回同一個 handler、
        // 無限遞迴——迴歸時整個 test suite 卡住直到 CI job timeout（600s 都不結束），而不是
        // 一條看得懂原因的紅。改成只在 `passwordSignInAttempts.count < 2` 時才重入一次
        // （reviewer 建議的修法）：guard 還在時只呼叫得到 1 次、後面斷言綠；guard 被拿掉時
        // 最多遞迴到 2 次就停（不會無限），斷言 `count == 1` 直接紅，秒級失敗、原因清楚。
        let stub = StubAuthService()
        let expected = AuthSession(userID: userID, email: "reviewer@example.com", expiresAt: .distantFuture)
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updateEmail("reviewer@example.com")
        model.updatePassword("correct-horse-battery-staple")
        stub.setSignInWithPasswordHandler { _, _ in
            if stub.passwordSignInAttempts.count < 2 {
                _ = await model.signIn()
            }
            return expected
        }

        let result = await model.signIn()

        XCTAssertTrue(result)
        XCTAssertEqual(
            stub.passwordSignInAttempts.count, 1,
            "isSigningIn 時的重入呼叫不該再打一次後端"
        )
    }

    // MARK: - merge-review R1 N1：限流／泛用非帳密狀態碼不能被誤判成「帳號或密碼錯誤」

    // `AppError.mapAPIStatus` 把 429 歸進 `.validationRetryable` 並帶 `code: "bare_http_429"`
    // sentinel（見 AppError.swift）——429 是限流，換帳密重試沒有用，且會誤導審核人員一直重試、
    // 越拉越長冷卻窗口。這裡直接注入這個 code，不依賴真的網路往返。
    func test_signIn_bareHTTP429_doesNotShowCredentialsErrorMessage() async {
        let stub = StubAuthService()
        let underlying = AppError.validationRetryable(message: "Too Many Requests", code: "bare_http_429")
        stub.setSignInWithPasswordHandler { _, _ in throw underlying }
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updateEmail("reviewer@example.com")
        model.updatePassword("correct-horse-battery-staple")

        let result = await model.signIn()

        XCTAssertFalse(result)
        XCTAssertFalse(
            model.isCredentialsError,
            "429 是限流，不是帳密打錯——標成帳密錯誤會誤導審核人員一直重試密碼"
        )
        XCTAssertEqual(model.errorMessage, underlying.userFacingMessage)
        XCTAssertNotEqual(model.errorMessage, "帳號或密碼錯誤，請再試一次。")
    }

    // GoTrue 結構化的限流碼（有 JSON body 時），同 `bare_http_429`（反向代理裸 429）的理由，
    // 見 `OTPVerificationModel.nonAttemptConsumingCodes` 既有前例。
    func test_signIn_overRequestRateLimit_doesNotShowCredentialsErrorMessage() async {
        let stub = StubAuthService()
        let underlying = AppError.validationRetryable(message: "rate limited", code: "over_request_rate_limit")
        stub.setSignInWithPasswordHandler { _, _ in throw underlying }
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updateEmail("reviewer@example.com")
        model.updatePassword("correct-horse-battery-staple")

        let result = await model.signIn()

        XCTAssertFalse(result)
        XCTAssertFalse(model.isCredentialsError)
        XCTAssertEqual(model.errorMessage, underlying.userFacingMessage)
    }
}

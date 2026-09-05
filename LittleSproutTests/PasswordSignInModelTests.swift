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
        XCTAssertNil(model.errorMessage, "空欄位沒有對應設計態，靜默不動作即可")
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
        XCTAssertNil(model.errorMessage)
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
        let stub = StubAuthService()
        let expected = AuthSession(userID: userID, email: "reviewer@example.com", expiresAt: .distantFuture)
        let store = AuthStore(authService: stub)
        let model = PasswordSignInModel(authStore: store)
        model.updateEmail("reviewer@example.com")
        model.updatePassword("correct-horse-battery-staple")
        stub.setSignInWithPasswordHandler { _, _ in
            _ = await model.signIn()
            return expected
        }

        let result = await model.signIn()

        XCTAssertTrue(result)
        XCTAssertEqual(
            stub.passwordSignInAttempts.count, 1,
            "isSigningIn 時的重入呼叫不該再打一次後端"
        )
    }
}

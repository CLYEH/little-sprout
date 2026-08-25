@testable import LittleSprout
import XCTest

@MainActor
final class EmailSignInModelTests: XCTestCase {
    func test_sendCode_invalidFormat_setsErrorWithoutCallingAuthService() async {
        let stub = StubAuthService()
        let store = AuthStore(authService: stub)
        let model = EmailSignInModel(authStore: store)
        model.updateEmail("grandma@example")

        let result = await model.sendCode()

        XCTAssertFalse(result)
        XCTAssertEqual(model.errorMessage, "這個 Email 好像沒打完，請再看一次，格式像 name@example.com")
        XCTAssertTrue(stub.sentEmails.isEmpty, "格式錯誤是純客戶端檢查，不該打到後端")
    }

    func test_sendCode_validFormat_callsAuthServiceAndClearsError() async {
        let stub = StubAuthService()
        let store = AuthStore(authService: stub)
        let model = EmailSignInModel(authStore: store)
        model.updateEmail("grandma@example.com")

        let result = await model.sendCode()

        XCTAssertTrue(result)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(stub.sentEmails, ["grandma@example.com"])
    }

    func test_sendCode_networkFailure_setsUserFacingMessage() async {
        let stub = StubAuthService()
        stub.setSendEmailOTPHandler { _ in throw AppError.network(message: "offline") }
        let store = AuthStore(authService: stub)
        let model = EmailSignInModel(authStore: store)
        model.updateEmail("grandma@example.com")

        let result = await model.sendCode()

        XCTAssertFalse(result)
        XCTAssertEqual(model.errorMessage, AppError.network(message: "offline").userFacingMessage)
    }

    func test_updateEmail_clearsPreviousError() async {
        let stub = StubAuthService()
        let store = AuthStore(authService: stub)
        let model = EmailSignInModel(authStore: store)
        model.updateEmail("bad-format")
        _ = await model.sendCode()
        XCTAssertNotNil(model.errorMessage)

        model.updateEmail("grandma@example.com")

        XCTAssertNil(model.errorMessage)
    }
}

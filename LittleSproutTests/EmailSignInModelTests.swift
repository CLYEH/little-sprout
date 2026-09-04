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

    func test_sendCode_reentrantCallWhileSending_isIgnored() async {
        // R2 review M5：sendCode() 少一道與 resend() 對稱的再入 guard，鍵盤 Send 鍵與主按鈕
        // 理論上可在 isSending 傳播到 .disabled() 之前重疊觸發第二次送出。
        let stub = StubAuthService()
        let store = AuthStore(authService: stub)
        let model = EmailSignInModel(authStore: store)
        model.updateEmail("grandma@example.com")
        stub.setSendEmailOTPHandler { _ in
            _ = await model.sendCode()
        }

        let result = await model.sendCode()

        XCTAssertTrue(result)
        XCTAssertEqual(stub.sentEmails, ["grandma@example.com"], "isSending 時的重入呼叫不該再打一次後端")
    }

    // LS-156 (a)：貼上帶前後空白／換行的合法 email 仍能寄碼，且後端收到的是 trimmed 值
    // （避免 GoTrue 因為帶空白的格式回泛用 400，見 ticket 來源 LS-146 QA R1 觀察 (c)）。
    func test_sendCode_trimsLeadingTrailingWhitespaceAndNewlines() async {
        let stub = StubAuthService()
        let store = AuthStore(authService: stub)
        let model = EmailSignInModel(authStore: store)
        model.updateEmail("  a@b.com\n")

        let result = await model.sendCode()

        XCTAssertTrue(result)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(stub.sentEmails, ["a@b.com"])
    }

    // LS-156 (b)：只有空白（trim 後為空字串）仍要落在既有的格式錯誤文案，不打後端。
    func test_sendCode_whitespaceOnlyInput_showsFormatErrorWithoutCallingAuthService() async {
        let stub = StubAuthService()
        let store = AuthStore(authService: stub)
        let model = EmailSignInModel(authStore: store)
        model.updateEmail("   ")

        let result = await model.sendCode()

        XCTAssertFalse(result)
        XCTAssertEqual(model.errorMessage, "這個 Email 好像沒打完，請再看一次，格式像 name@example.com")
        XCTAssertTrue(stub.sentEmails.isEmpty)
    }

    // LS-156 (c)：verify 路徑不經過 EmailSignInModel（OTPVerificationModel 是獨立畫面的
    // model，`verifyEmailOTP` 直接用建構時拿到的 email，本身不做 trim）——一致性靠
    // `EmailSignInView.send()` 用 `trimmedEmail`（不是 `email`）餵給 `onCodeSent`，這個值會
    // 原封不動流進 `OTPVerificationView(email:)` → `OTPVerificationModel.verify()` 呼叫的
    // `verifyEmailOTP(email:)`。這裡確認 `trimmedEmail` 本身就是那個會被轉送的值，
    // 跟 sendCode() 實際打後端用的值同源。
    func test_trimmedEmail_isSameValueForwardedToVerifyPath() {
        let stub = StubAuthService()
        let store = AuthStore(authService: stub)
        let model = EmailSignInModel(authStore: store)
        model.updateEmail("  a@b.com\n")

        XCTAssertEqual(model.trimmedEmail, "a@b.com")
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

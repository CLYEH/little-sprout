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

    // LS-156 R1 review F3：唯一能區分「驗證用 raw」與「驗證用 trimmed」的輸入——`isValid`
    // 對兩邊的輸出不同（trim 前 local part 是空字串前的一個空白字元，parts 仍然合法切成
    // local="" 前導空白／domain；trim 後 local part 真的變空字串才會判定失敗）。把 `sendCode()`
    // 內的驗證改回讀原始 `email`（拿掉 trim）時，這一案必須變紅——mutation 實跑見 R2 handoff。
    func test_sendCode_leadingSpaceBeforeAt_isRejectedAfterTrim() async {
        let stub = StubAuthService()
        let store = AuthStore(authService: stub)
        let model = EmailSignInModel(authStore: store)
        model.updateEmail(" @b.com")

        let result = await model.sendCode()

        XCTAssertFalse(result)
        XCTAssertEqual(model.errorMessage, "這個 Email 好像沒打完，請再看一次，格式像 name@example.com")
        XCTAssertTrue(stub.sentEmails.isEmpty)
    }

    // LS-156 R2（merge-review R1 F1／F2）：verify 路徑不經過 EmailSignInModel
    // （OTPVerificationModel 是獨立畫面的 model，`verifyEmailOTP` 直接用建構時拿到的 email，
    // 本身不做 trim）——一致性靠 `EmailSignInView.send()` 轉送 `model.lastSentEmail` 給
    // `onCodeSent`，原封不動流進 `OTPVerificationView(email:)` → `OTPVerificationModel.verify()`
    // 呼叫的 `verifyEmailOTP(email:)`。這裡確認 `lastSentEmail` 就是 `sendCode()` 實際打後端
    // 用的那個值（跟 stub 收到的一致）。
    func test_lastSentEmail_matchesValueSentToAuthService() async {
        let stub = StubAuthService()
        let store = AuthStore(authService: stub)
        let model = EmailSignInModel(authStore: store)
        model.updateEmail("  a@b.com\n")

        let result = await model.sendCode()

        XCTAssertTrue(result)
        XCTAssertEqual(model.lastSentEmail, "a@b.com")
        XCTAssertEqual(stub.sentEmails, ["a@b.com"])
    }

    // LS-156 R2（merge-review R1 F1 回歸測試）：`sendCode()` 送出中（`await
    // authStore.sendEmailOTP` 尚未回來）使用者把輸入框改成別的 email——`lastSentEmail`
    // 必須仍是驗證通過、真正寄出去的那個舊值，不能被之後的 `updateEmail` 污染。這一案要能在
    // 把 `sendCode()`／`EmailSignInView.send()` 改回「await 之後才重讀 `trimmedEmail`」時
    // 變紅（見 R1 handoff 情境重現：`sendEmailOTPHandler` 模擬「送出中使用者繼續打字」，
    // 跟 `test_sendCode_reentrantCallWhileSending_isIgnored` 同一種注入手法）。
    func test_lastSentEmail_unaffectedByEditsDuringInFlightSend() async {
        let stub = StubAuthService()
        let store = AuthStore(authService: stub)
        let model = EmailSignInModel(authStore: store)
        model.updateEmail("  a@b.com\n")
        stub.setSendEmailOTPHandler { _ in
            await model.updateEmail("typo@x.com")
        }

        let result = await model.sendCode()

        XCTAssertTrue(result)
        XCTAssertEqual(stub.sentEmails, ["a@b.com"])
        XCTAssertEqual(model.lastSentEmail, "a@b.com", "轉送給 verify 路徑的必須是實際寄碼的那個值")
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

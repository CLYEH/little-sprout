import XCTest

/// LS-164 票文驗收：「UITests 補『歡迎頁存在小字連結且 tap 進入密碼畫面』」。共用
/// `TapTargetGateHarness`（`.welcome`）直接啟動到歡迎頁，不需要真的登入或建立家庭——見
/// `TapTargetGateScreenName.welcome` 文件註解（這個 case 不掛進 `TapTargetGateTests`，
/// WelcomeView 本身仍因 Apple 官方按鈕留在 tap-target-exemptions.txt）。
@MainActor
final class PasswordSignInUITests: XCTestCase {
    func testWelcomeViewShowsPasswordSignInLinkAndNavigatesToPasswordSignIn() {
        let app = TapTargetMeasurement.launch(.welcome)
        TapTargetMeasurement.assertScreenRendered(.welcome, in: app)

        let link = app.buttons["以帳號密碼登入"]
        XCTAssertTrue(link.waitForExistence(timeout: 5), "歡迎頁三顆登入鈕下方應該有帳號密碼登入的小字連結")
        // 票文明記「≥44pt 熱區」——這顆連結不在 `TapTargetGateTests` 覆蓋範圍內（`.welcome`
        // 不掛逐元件量測，見上方文件註解），單獨在這裡釘住高度，不靠通用 gate 補到。
        XCTAssertGreaterThanOrEqual(link.frame.height, TapTargetMeasurement.minSide, "連結熱區必須 ≥44pt，長輩硬約束")

        link.tap()

        TapTargetMeasurement.assertScreenRendered(.passwordSignIn, in: app)
    }
}

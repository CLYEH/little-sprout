import XCTest

/// LS-191 票文驗收：「UITests（歡迎頁點《使用條款》→ sheet 出現 → 關閉；Footer 可見）」。
/// 共用 `TapTargetGateHarness`（`.welcome`）直接啟動到歡迎頁，同
/// `PasswordSignInUITests`（LS-164）既有作法，不需要真的登入或建立家庭。
@MainActor
final class LegalDocumentSheetUITests: XCTestCase {
    func testWelcomeViewLegalLink_opensTermsOfServiceSheet_thenCloses() {
        let app = TapTargetMeasurement.launch(.welcome)
        TapTargetMeasurement.assertScreenRendered(.welcome, in: app)

        // `Text(AttributedString)` 的 `.link` range 曝露成獨立的 `XCUIElementTypeLink`
        // accessibility 元件（不是 staticText 的一部分），可直接查詢／點擊。
        let termsLink = app.links["《使用條款》"]
        XCTAssertTrue(termsLink.waitForExistence(timeout: 5), "歡迎頁法務行應含可點擊的《使用條款》連結")
        termsLink.tap()

        let docTitle = app.staticTexts["使用條款"]
        XCTAssertTrue(docTitle.waitForExistence(timeout: 5), "點擊連結後應開啟 LegalDocumentSheet，顯示 Doc Title「使用條款」")

        let closeButton = app.buttons["關閉"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Footer 關閉鈕應可見（safeAreaInset 釘底，不需捲動就看得到）")
        XCTAssertGreaterThanOrEqual(
            closeButton.frame.height, TapTargetMeasurement.minSide, "關閉鈕熱區必須 ≥44pt，長輩硬約束"
        )

        closeButton.tap()
        XCTAssertFalse(docTitle.waitForExistence(timeout: 3), "點擊關閉後 sheet 應消失")
    }

    func testWelcomeViewLegalLink_privacyPolicy_opensCorrectDocument() {
        let app = TapTargetMeasurement.launch(.welcome)
        TapTargetMeasurement.assertScreenRendered(.welcome, in: app)

        let privacyLink = app.links["《隱私權政策》"]
        XCTAssertTrue(privacyLink.waitForExistence(timeout: 5), "歡迎頁法務行應含可點擊的《隱私權政策》連結")
        privacyLink.tap()

        XCTAssertTrue(
            app.staticTexts["隱私權政策"].waitForExistence(timeout: 5),
            "點擊《隱私權政策》連結應開啟對應文件，不是誤開使用條款"
        )
    }
}

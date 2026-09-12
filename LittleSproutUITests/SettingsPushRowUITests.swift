import XCTest

/// LS-217 票文驗收：「設定列三態文案」——`design/littlesprout.pen` `y7KAW`／`y66AzT` `DVEow`。
/// 三態各用一個 `TapTargetGateHarness` 變體（`.settings`＝`.notDetermined`、
/// `.settingsPushDenied`、`.settingsPushAuthorized`，見該檔），驗證 value 文案與點擊後的行為
/// （票文範圍 3）。
@MainActor
final class SettingsPushRowUITests: XCTestCase {
    func testNotDetermined_showsOffValue_tapPresentsPreprompt() {
        let app = TapTargetMeasurement.launch(.settings)
        TapTargetMeasurement.assertScreenRendered(.settings, in: app)

        let row = app.buttons[QAAccessibilityID.settingsPushRow]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["關閉"].waitForExistence(timeout: 5), ".notDetermined 態 value 應顯示「關閉」"
        )

        row.tap()

        XCTAssertTrue(
            app.buttons["開啟通知"].waitForExistence(timeout: 5),
            ".notDetermined 點擊應走第 1 項流程，重新呈現 PushPrepromptView（票文範圍 3）"
        )
    }

    func testDenied_showsOffValue_tapShowsGoToSettingsAlert() {
        let app = TapTargetMeasurement.launch(.settingsPushDenied)
        TapTargetMeasurement.assertScreenRendered(.settingsPushDenied, in: app)

        let row = app.buttons[QAAccessibilityID.settingsPushRow]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["關閉"].waitForExistence(timeout: 5), ".denied 態 value 應顯示「關閉」")

        row.tap()

        XCTAssertTrue(
            app.staticTexts["要開啟推播通知嗎？"].waitForExistence(timeout: 5),
            ".denied 點擊應顯示「要開啟推播通知嗎？」alert（票文範圍 3）"
        )
        XCTAssertTrue(app.buttons["前往設定"].exists)
        XCTAssertTrue(app.buttons["取消"].exists)
    }

    func testAuthorized_showsOnValue_tapShowsDisableConfirmation() {
        let app = TapTargetMeasurement.launch(.settingsPushAuthorized)
        TapTargetMeasurement.assertScreenRendered(.settingsPushAuthorized, in: app)

        let row = app.buttons[QAAccessibilityID.settingsPushRow]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["開啟"].waitForExistence(timeout: 5), ".authorized 態 value 應顯示「開啟」")

        row.tap()

        XCTAssertTrue(
            app.staticTexts["要關閉推播通知嗎？"].waitForExistence(timeout: 5),
            ".authorized 點擊（想關閉）應顯示定案文案「要關閉推播通知嗎？」（Handoff Notes `Z7vNe`）"
        )
        XCTAssertTrue(
            app.staticTexts["這需要在「設定」App 裡調整通知權限。"].waitForExistence(timeout: 5),
            "確認 alert 內文應逐字符合定案文案"
        )
        XCTAssertTrue(app.buttons["前往設定"].exists)
        XCTAssertTrue(app.buttons["取消"].exists)

        // 取消後列應維持「開啟」——沒有另外的本地「待定」狀態，Toggle 直接讀
        // `authorizationStatus`（Notes `Z7vNe`：「取消則 Toggle 彈回開啟」）。
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["開啟"].waitForExistence(timeout: 5), "取消後 value 應維持「開啟」")
    }
}

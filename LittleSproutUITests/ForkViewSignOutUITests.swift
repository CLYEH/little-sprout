import XCTest

/// LS-505：一般（無家庭、未停權）三岔路頁要有「登出」出口——新帳號登入後不想建立也不想加入
/// 家庭時不能被卡住。用 `.forkViewNoFamily` harness host（`ForkViewSignOutHost`，不打真網路）。
@MainActor
final class ForkViewSignOutUITests: XCTestCase {
    func testPlainForkView_signOutButton_existsAndReturnsToWelcome() {
        let app = TapTargetMeasurement.launch(.forkViewNoFamily)
        TapTargetMeasurement.assertScreenRendered(.forkViewNoFamily, in: app)

        let signOutButton = app.buttons["登出"]
        XCTAssertTrue(signOutButton.waitForExistence(timeout: 5), "一般三岔路頁應該要有「登出」出口")
        XCTAssertEqual(app.buttons.matching(identifier: "登出").count, 1, "不該同時出現兩顆登出鈕")
        XCTAssertTrue(signOutButton.isHittable, "「登出」鈕應該可點（minHeight 48）")

        signOutButton.tap()

        XCTAssertTrue(
            TapTargetGateScreenName.welcome.sentinel.element(in: app).waitForExistence(timeout: 5),
            "登出後 session 清除，應該回到歡迎（登入）頁"
        )
        XCTAssertFalse(app.buttons["我要自己建立家庭"].exists, "回到歡迎頁後不該還看得到三岔路")
    }

    /// 帳號在後端被刪、存的 access token 仍有效時，家庭查詢失敗落在 `FamilyLookupFailedView`——
    /// 同樣要有「登出」出口。
    func testFamilyLookupFailedView_signOutButton_existsAndReturnsToWelcome() {
        let app = TapTargetMeasurement.launch(.familyLookupFailed)
        TapTargetMeasurement.assertScreenRendered(.familyLookupFailed, in: app)

        let signOutButton = app.buttons["登出"]
        XCTAssertTrue(signOutButton.waitForExistence(timeout: 5), "家庭查詢失敗頁應該要有「登出」出口")
        XCTAssertTrue(signOutButton.isHittable, "「登出」鈕應該可點（minHeight 48）")

        signOutButton.tap()

        XCTAssertTrue(
            TapTargetGateScreenName.welcome.sentinel.element(in: app).waitForExistence(timeout: 5),
            "登出後 session 清除，應該回到歡迎（登入）頁"
        )
        XCTAssertFalse(app.buttons["重試"].exists, "回到歡迎頁後不該還看得到失敗頁")
    }
}

import XCTest

/// LS-381：記錄詳情 04-iPad（`orGax`）——沖印品（寬 290，照片 274×350）與反應欄左右並排（Memory Row `TkCHZ`），
/// 貼紙 120；04b／04c「同 04-iPad」各截一張對稿。
///
/// 只在 iPad idiom 執行；類別名以 `IPadTests` 結尾讓 CI `ci-ipad`（`scripts/gates/list-ipad-tests.sh`）選得到。
@MainActor
final class FoodRecordDetailIPadTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad 專屬版面測試，非 iPad 裝置（例如 push-gate 常態用的 iPhone 專屬機）略過"
        )
    }

    func testRegular_printAndSideColumnSideBySide() {
        let app = launch(.foodRecordDetail, dark: false)
        let print = app.descendants(matching: .any)["foodRecordDetail.photo"].firstMatch
        let reaction = app.descendants(matching: .any)["foodRecordDetail.reaction"].firstMatch
        let allergen = app.descendants(matching: .any)["foodRecordDetail.allergen"].firstMatch
        XCTAssertTrue(print.waitForExistence(timeout: 5))
        XCTAssertEqual(print.frame.width, 274, accuracy: 1, "04-iPad 照片窗 274（沖印品寬 290＝274＋白邊 8×2）")
        XCTAssertEqual(print.frame.height, 350, accuracy: 1, "04-iPad 照片窗高 350")
        XCTAssertGreaterThan(reaction.frame.minX, print.frame.maxX, "反應欄在沖印品右側")
        XCTAssertEqual(reaction.frame.minY, print.frame.minY - 8, accuracy: 2, "兩欄頂端對齊（沖印品頂＝照片窗頂 − 白邊 8）")
        XCTAssertGreaterThan(allergen.frame.minX, print.frame.maxX, "iPad 過敏原句也在右側欄")
        XCTAssertTrue(app.buttons["編輯這筆記錄"].exists)
        attach(app, "04-iPad-light")
    }

    func testRegular_screenshots() {
        attach(launch(.foodRecordDetail, dark: true), "04-iPad-dark")
        attach(launch(.foodRecordDetailNoPhoto, dark: false), "04b-iPad-light")
        attach(launch(.foodRecordDetailOwner, dark: false), "04c-iPad-light")
    }

    private func launch(_ screen: TapTargetGateScreenName, dark: Bool) -> XCUIApplication {
        let app = TapTargetMeasurement.launch(
            screen, contentSizeCategory: "UICTContentSizeCategoryL",
            extraLaunchArguments: dark ? ["-LSFoodRecordDetailDark", "YES"] : []
        )
        TapTargetMeasurement.assertScreenRendered(screen, in: app)
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "LS-381-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

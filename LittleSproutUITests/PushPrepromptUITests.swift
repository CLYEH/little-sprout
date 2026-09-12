import XCTest

/// LS-217 票文驗收：「UITests（前置頁元素與 AX3）」——`design/littlesprout.pen` `j7WwV`
/// （一般字級）／`KyxGc`（AX3）。
@MainActor
final class PushPrepromptUITests: XCTestCase {
    private static let headline = "開啟通知，不錯過家人的每一刻"
    private static let bodyText =
        "當家人新增照片、寫日記，或在你的動態下留言、按愛心時，我們會通知你——不會太吵，同一段時間的更新會合併成一則。"

    func testElementsExist() {
        let app = TapTargetMeasurement.launch(.pushPreprompt)
        TapTargetMeasurement.assertScreenRendered(.pushPreprompt, in: app)

        XCTAssertTrue(app.staticTexts[Self.headline].waitForExistence(timeout: 5), "標題應存在")
        XCTAssertTrue(app.staticTexts[Self.bodyText].waitForExistence(timeout: 5), "內文應存在")
        XCTAssertTrue(app.staticTexts["萌芽日記"].waitForExistence(timeout: 5), "通知預覽卡的 app 名稱應存在")
        XCTAssertTrue(
            app.staticTexts["爸爸新增了 50 張照片"].waitForExistence(timeout: 5), "通知預覽卡的範例文字應存在"
        )
        let enableButton = app.buttons["開啟通知"]
        let skipButton = app.buttons["稍後再說"]
        XCTAssertTrue(enableButton.exists, "CTA「開啟通知」應存在")
        XCTAssertTrue(skipButton.exists, "「稍後再說」應存在")
        XCTAssertTrue(enableButton.isHittable)
        XCTAssertTrue(skipButton.isHittable)
    }

    /// AX3（`accessibility-extra-large`）壓力板——標題／內文／兩顆按鈕都必須維持可達，不能被
    /// 放大字級擠出畫面外（同 `DeleteConfirmationAX3UITests` 等既有先例，字級常數見該檔文件
    /// 註解）。
    func testAX3_headlineBodyAndButtonsRemainReachable() {
        let app = TapTargetMeasurement.launch(
            .pushPreprompt, contentSizeCategory: "UICTContentSizeCategoryAccessibilityXL"
        )
        TapTargetMeasurement.assertScreenRendered(.pushPreprompt, in: app)

        XCTAssertTrue(app.staticTexts[Self.headline].waitForExistence(timeout: 10), "AX3 下標題不應消失")
        XCTAssertTrue(app.staticTexts[Self.bodyText].waitForExistence(timeout: 10), "AX3 下內文不應消失")

        let enableButton = app.buttons["開啟通知"]
        let skipButton = app.buttons["稍後再說"]
        XCTAssertTrue(enableButton.waitForExistence(timeout: 5))
        XCTAssertTrue(skipButton.waitForExistence(timeout: 5))
        XCTAssertTrue(enableButton.isHittable, "AX3 下 CTA 仍應可點")
        XCTAssertTrue(skipButton.isHittable, "AX3 下「稍後再說」仍應可點")
        XCTAssertGreaterThanOrEqual(enableButton.frame.height, TapTargetMeasurement.minSide)
        XCTAssertGreaterThanOrEqual(skipButton.frame.height, TapTargetMeasurement.minSide)
    }
}

import XCTest

/// LS-380 票文驗收「對稿截圖：03／03b／03c／03d／03e × 淺深 × xSmall／預設／AX3」——一支方法一組（淺深 × 字級），
/// 每組依序截 03（上半＋Footer）、03d、03e、03b（上半＋Footer）、03c，全部 `XCTAttachment(.keepAlways)`，
/// 名稱 `LS-380-<板>-<light|dark>-<xSmall|default|AX3>`。對稿板：03 `FP2An`／深色 `TRLN6`／AX3 `qV7XY`；03b
/// `ekxHM`／`K6MMar`；03c `Oob1d`／`d56YR`；03d `OoYLu`／`CkOy9`；03e `NgnYl`／`Yufqp`。
///
/// 截圖之外也順手斷言每一板的關鍵元素確實出現（不是截到空白或錯的畫面）。
@MainActor
final class FoodRecordSheetScreenshotTests: XCTestCase {
    private typealias Support = FoodRecordUITestSupport

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone 對稿截圖")
    }

    func testScreenshots_light_xSmall() { captureAll(dark: false, size: Support.xSmall, sizeName: "xSmall") }
    func testScreenshots_light_default() { captureAll(dark: false, size: Support.standard, sizeName: "default") }
    func testScreenshots_light_AX3() { captureAll(dark: false, size: Support.ax3, sizeName: "AX3") }
    func testScreenshots_dark_xSmall() { captureAll(dark: true, size: Support.xSmall, sizeName: "xSmall") }
    func testScreenshots_dark_default() { captureAll(dark: true, size: Support.standard, sizeName: "default") }
    func testScreenshots_dark_AX3() { captureAll(dark: true, size: Support.ax3, sizeName: "AX3") }

    private func captureAll(dark: Bool, size: String, sizeName: String) {
        let suffix = "\(dark ? "dark" : "light")-\(sizeName)"

        // 03 ＋ 03d
        var app = Support.launch(.foodRecordSheet, size, dark: dark)
        Support.openTaroSheet(in: app)
        attach(app, "03-\(suffix)")
        let family = app.buttons["從家庭相簿挑"]
        Support.scrollUntilHittable(family, in: app)
        family.tap()
        XCTAssertTrue(app.staticTexts["從家庭相簿挑一張"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["foodPhoto.00000000-0000-0000-0000-000000000001"].waitForExistence(timeout: 5))
        app.buttons["foodPhoto.00000000-0000-0000-0000-000000000001"].tap()
        attach(app, "03d-\(suffix)")
        app.buttons.matching(identifier: "取消").allElementsBoundByIndex.first { $0.isHittable }?.tap()
        XCTAssertTrue(app.staticTexts["從家庭相簿挑一張"].waitUntilGone(timeout: 5))
        let save = app.buttons["foodRecord.save"]
        Support.scrollUntilHittable(save, in: app)
        attach(app, "03-\(suffix)-footer")
        app.terminate()

        // 03e（稿面示範選了「普通」）
        app = Support.launch(.foodRecordSheetFailure, size, dark: dark)
        Support.openTaroSheet(in: app)
        let neutral = app.buttons["foodRecord.reaction.neutral"]
        Support.scrollUntilHittable(neutral, in: app)
        neutral.tap()
        let failureSave = app.buttons["foodRecord.save"]
        Support.scrollUntilHittable(failureSave, in: app)
        failureSave.tap()
        XCTAssertTrue(Support.waitForLabel(
            Support.element("foodRecord.statusText", in: app), where: "CONTAINS", "沒有存起來"
        ))
        attach(app, "03e-\(suffix)")
        app.terminate()

        // 03b ＋ 03c
        app = Support.launch(.foodRecordSheetEdit, size, dark: dark)
        XCTAssertTrue(Support.element("foodRecord.photoThumb", in: app).waitForExistence(timeout: 5))
        attach(app, "03b-\(suffix)")
        let delete = app.buttons["foodRecord.delete"]
        Support.scrollUntilHittable(delete, in: app)
        attach(app, "03b-\(suffix)-footer")
        delete.tap()
        XCTAssertTrue(app.staticTexts["要刪除吐司麵包這筆記錄嗎？"].waitForExistence(timeout: 5))
        attach(app, "03c-\(suffix)")
        app.terminate()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        // 等 sheet／捲動動畫停穩再截（截到半途的轉場沒有對稿價值）。
        Thread.sleep(forTimeInterval: 0.8)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "LS-380-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

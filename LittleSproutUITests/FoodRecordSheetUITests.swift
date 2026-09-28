import XCTest

/// LS-380：第一次記錄 sheet 家族的行為回歸（iPhone）。對稿截圖在 `FoodRecordSheetScreenshotTests`。
///
/// sheet 內容在 iOS 26.2+ 會套約 0.96 縮放（LS-167）——座標斷言一律拿「同一顆元件前後」或「同一畫面的兩個
/// 元件」相比，不用絕對常數。
@MainActor
final class FoodRecordSheetUITests: XCTestCase {
    private typealias Support = FoodRecordUITestSupport

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone（compact）行為測試")
    }

    // MARK: - 03 → 儲存 → 06 收下

    /// 票文範圍 1／4：點空位開 03、反應再點一次取消、儲存後 sheet 收起、那一格變吃過（紙片＋今天日期）、
    /// 計數＋1（示範資料 38 → 39）。
    func testFirstRecord_saveClosesSheetAndCellBecomesTried() {
        let app = Support.launch(.foodRecordSheet, Support.standard)
        XCTAssertEqual(app.buttons["foodCell.taro"].label, "芋頭，還沒吃過")
        Support.openTaroSheet(in: app)

        XCTAssertTrue(app.staticTexts["穀物根莖"].exists, "表頭副標＝類別")
        XCTAssertTrue(app.buttons["foodRecord.date"].label.hasSuffix("（今天）"), "日期預設今天")
        let liked = app.buttons["foodRecord.reaction.liked"]
        Support.scrollUntilHittable(liked, in: app)
        liked.tap()
        XCTAssertTrue(liked.isSelected)
        liked.tap()
        XCTAssertFalse(liked.isSelected, "已選再點一次＝取消（Notes m18MTy）")
        liked.tap()

        let save = app.buttons["foodRecord.save"]
        Support.scrollUntilHittable(save, in: app)
        save.tap()

        XCTAssertTrue(app.staticTexts["記下小安第一次吃芋頭"].waitUntilGone(timeout: 5), "儲存成功要收起 sheet")
        let taro = app.buttons["foodCell.taro"]
        XCTAssertTrue(Support.waitForLabel(taro, where: "CONTAINS", "第一次吃到"), "那一格要變吃過：\(taro.label)")
        XCTAssertEqual(app.staticTexts["foodBook.progress"].label, "小安吃過 39\u{00A0}種，全部 274\u{00A0}種。")
    }

    // MARK: - 03e：儲存鈕不位移＋Status Slot max()

    func testFailureKeepsSaveButtonInPlace_default() {
        assertFailureKeepsSaveButtonInPlace(size: Support.standard)
    }

    /// AX3 下一般句與失敗句行數差最多（稿面 A11y/03e `Yufqp`），拿掉「疊兩句取較高者」就一定位移。
    func testFailureKeepsSaveButtonInPlace_AX3() {
        assertFailureKeepsSaveButtonInPlace(size: Support.ax3)
    }

    /// 儲存鈕 y 在失敗前後相同（票文範圍 2）；Status Slot 高度前後相同、且＝兩句中較高那句（不是寫死的 348／56）。
    private func assertFailureKeepsSaveButtonInPlace(size: String, line: UInt = #line) {
        let app = Support.launch(.foodRecordSheetFailure, size)
        Support.openTaroSheet(in: app)
        let save = app.buttons["foodRecord.save"]
        Support.scrollUntilHittable(save, in: app)
        let slot = Support.element("foodRecord.statusSlot", in: app)
        let statusText = Support.element("foodRecord.statusText", in: app)
        XCTAssertTrue(statusText.label.contains("儲存後芋頭會變成彩色"), statusText.label, line: line)
        let saveBefore = save.frame
        let slotBefore = slot.frame
        let normalRowHeight = statusText.frame.height

        save.tap()

        XCTAssertTrue(
            Support.waitForLabel(statusText, where: "CONTAINS", "沒有存起來：網路好像斷了"), "失敗句要出現在同一格：\(statusText.label)",
            line: line
        )
        XCTAssertTrue(save.waitForHittable(timeout: 5), line: line)
        let failureRowHeight = statusText.frame.height
        XCTAssertEqual(save.frame.minY, saveBefore.minY, accuracy: 0.5, "失敗態儲存鈕不位移", line: line)
        XCTAssertEqual(slot.frame.height, slotBefore.height, accuracy: 0.5, "Status Slot 前後同高", line: line)
        XCTAssertEqual(
            slot.frame.height, max(normalRowHeight, failureRowHeight), accuracy: 1,
            "Status Slot 高＝兩句較高者（max 規則，不寫死）：slot \(slot.frame.height)、一般 \(normalRowHeight)、失敗 \(failureRowHeight)",
            line: line
        )
        XCTAssertTrue(app.staticTexts["記下小安第一次吃芋頭"].exists, "失敗不關 sheet（內容保留）", line: line)
    }

    // MARK: - 03d

    /// 03d：依記錄日期分「今天拍的」／「其他照片」兩段；點一張＝選中，「用這張」才回填；「不用照片」退回兩個來源鈕。
    func testFamilyPicker_useThisPhotoFillsPhotoField() {
        let app = Support.launch(.foodRecordSheet, Support.standard)
        Support.openTaroSheet(in: app)
        app.buttons["從家庭相簿挑"].tap()

        XCTAssertTrue(app.staticTexts["從家庭相簿挑一張"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["今天拍的"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["其他照片"].exists)
        let firstPhoto = app.buttons["foodPhoto.00000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(firstPhoto.waitForHittable(timeout: 5))
        XCTAssertLessThan(firstPhoto.frame.minY, app.staticTexts["其他照片"].frame.minY, "今天拍的在前")
        firstPhoto.tap()
        XCTAssertTrue(firstPhoto.isSelected)
        app.buttons["foodPhoto.use"].tap()

        XCTAssertTrue(app.staticTexts["從家庭相簿挑一張"].waitUntilGone(timeout: 5))
        XCTAssertTrue(Support.element("foodRecord.photoThumb", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["換一張"].exists)
        app.buttons["不用照片"].tap()
        XCTAssertTrue(app.buttons["從家庭相簿挑"].waitForExistence(timeout: 5), "不用照片 → 回到兩個來源鈕")
    }

    // MARK: - 03b → 03c → 格子回未吃

    /// 票文範圍 3＋驗收「刪除→格子回未吃」：03b 按「刪除這筆記錄」→ 03c 文案逐字 → 確認後兩層 sheet 都收起、
    /// 吐司麵包那一格退回「還沒吃過」、計數 −1。
    func testDeleteReturnsCellToUntried() {
        let app = Support.launch(.foodRecordSheetEdit, Support.standard)
        XCTAssertTrue(app.buttons["foodRecord.reaction.liked"].isSelected, "03b 帶入既有反應")
        let delete = app.buttons["foodRecord.delete"]
        Support.scrollUntilHittable(delete, in: app)
        delete.tap()

        XCTAssertTrue(app.staticTexts["要刪除吐司麵包這筆記錄嗎？"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["吐司麵包會變回灰色，時間軸上的卡片也會拿掉。照片會留在家庭相簿。"].exists)
        Support.confirmDeleteButton(in: app).tap()

        XCTAssertTrue(app.staticTexts["編輯吐司麵包這筆記錄"].waitUntilGone(timeout: 5), "確認後編輯 sheet 也要收起")
        let bread = app.buttons["foodCell.bread"]
        XCTAssertTrue(Support.waitForLabel(bread, where: "BEGINSWITH", "吐司麵包，還沒吃過"), "格子要退回未吃：\(bread.label)")
        XCTAssertEqual(app.staticTexts["foodBook.progress"].label, "小安吃過 37\u{00A0}種，全部 274\u{00A0}種。")
    }

    /// 03c AX3（稿 `d56YR`）：刪除鈕與取消都在首屏內。
    func testDeleteConfirmation_AX3_buttonsOnFirstScreen() {
        let app = Support.launch(.foodRecordSheetEdit, Support.ax3)
        let delete = app.buttons["foodRecord.delete"]
        Support.scrollUntilHittable(delete, in: app)
        delete.tap()
        XCTAssertTrue(app.staticTexts["要刪除吐司麵包這筆記錄嗎？"].waitForExistence(timeout: 5))
        let confirm = Support.confirmDeleteButton(in: app)
        XCTAssertTrue(confirm.waitForHittable(timeout: 5), "刪除鈕要在首屏內可點")
        XCTAssertLessThanOrEqual(confirm.frame.maxY, app.frame.maxY)
        // 底下 03b 也有一顆「取消」（被確認 sheet 蓋住、不可點）——只要確認 sheet 那顆可點。
        let cancels = app.buttons.matching(identifier: "取消").allElementsBoundByIndex
        XCTAssertTrue(cancels.contains { $0.isHittable && $0.frame.minY > confirm.frame.minY }, "取消要在首屏內可點")
    }
}

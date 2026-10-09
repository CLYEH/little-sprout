import XCTest

/// LS-380 R2：圖鑑 → 04 記錄詳情（LS-381）→ LS-380 的 03b／03c／04b 加照片——兩票接縫①④⑥⑦的行為回歸。
/// host 見 `TapTargetGateHarness+FoodRecord.swift` 的 `FoodRecordDetailFlowHarnessHost`（媽媽＝登入者＝owner：
/// 吐司麵包、南瓜（沒照片）是媽媽記的；米精是爸爸記的）。
@MainActor
final class FoodRecordDetailFlowUITests: XCTestCase {
    private typealias Support = FoodRecordUITestSupport

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone（compact）行為測試")
    }

    /// 接縫①（編輯）＋⑦：詳情 → 03b 改反應 → 儲存 → 回到詳情頁就是新值（不必離開再進來）。
    func testEditFromDetail_detailShowsSavedValues() {
        let app = Support.launch(.foodRecordDetailFlow, Support.standard)
        openDetail("bread", in: app)
        let reaction = Support.element("foodRecordDetail.reaction", in: app)
        XCTAssertTrue(Support.waitForLabel(reaction, where: "==", "喜歡"))

        app.buttons["foodRecordDetail.edit"].tap()
        XCTAssertTrue(app.staticTexts["編輯吐司麵包這筆記錄"].waitForExistence(timeout: 5))
        let neutral = app.buttons["foodRecord.reaction.neutral"]
        Support.scrollUntilHittable(neutral, in: app)
        neutral.tap()
        let save = app.buttons["foodRecord.save"]
        Support.scrollUntilHittable(save, in: app)
        save.tap()

        XCTAssertTrue(app.staticTexts["編輯吐司麵包這筆記錄"].waitUntilGone(timeout: 5))
        XCTAssertTrue(app.staticTexts["foodRecordDetail.title"].exists, "儲存後留在詳情頁")
        XCTAssertTrue(Support.waitForLabel(reaction, where: "==", "普通"), "詳情頁要換成剛存的反應：\(reaction.label)")
    }

    /// LS-380 R3（QA `a27eafaf`，真後端重現）：呼叫端給詳情頁的記錄推入後永遠不更新（同真入口）、API 回伺服器
    /// 那一列——03b 儲存收起後，詳情頁仍要立刻顯示新值（router 自己記住存好的那一筆，不能只靠呼叫端回傳）。
    func testEditWithFrozenCallerRecord_serverShapedClient_detailShowsSavedValues() {
        let app = Support.launch(.foodRecordDetailServer, Support.standard)
        let reaction = Support.element("foodRecordDetail.reaction", in: app)
        XCTAssertTrue(Support.waitForLabel(reaction, where: "==", "喜歡"))
        let edit = app.buttons["foodRecordDetail.edit"]
        Support.scrollUntilHittable(edit, in: app)
        edit.tap()
        XCTAssertTrue(app.staticTexts["編輯吐司麵包這筆記錄"].waitForExistence(timeout: 5))
        let disliked = app.buttons["foodRecord.reaction.disliked"]
        Support.scrollUntilHittable(disliked, in: app)
        disliked.tap()
        let save = app.buttons["foodRecord.save"]
        Support.scrollUntilHittable(save, in: app)
        save.tap()

        XCTAssertTrue(app.staticTexts["編輯吐司麵包這筆記錄"].waitUntilGone(timeout: 5))
        XCTAssertTrue(
            Support.waitForLabel(reaction, where: "==", "不愛吃"), "儲存後詳情頁要立刻換成新反應：\(reaction.label)"
        )
    }

    /// 接縫①（刪除，04c 呼叫路徑②）＋④⑥：非作者 owner 在詳情頁刪除 → 03c → 確認後返回圖鑑、格子回未吃。
    func testOwnerDeletesFromDetail_popsAndCellReturnsToUntried() {
        let app = Support.launch(.foodRecordDetailFlow, Support.standard)
        let progressBefore = app.staticTexts["foodBook.progress"].label
        openDetail("rice_cereal", in: app)
        XCTAssertFalse(app.buttons["foodRecordDetail.edit"].exists, "04c 不是作者：沒有編輯")
        app.buttons["foodRecordDetail.delete"].tap()
        XCTAssertTrue(app.staticTexts["要刪除米精這筆記錄嗎？"].waitForExistence(timeout: 5))
        Support.confirmDeleteButton(in: app).tap()

        XCTAssertTrue(app.staticTexts["foodRecordDetail.title"].waitUntilGone(timeout: 5), "刪除後要返回圖鑑")
        assertCellUntried("rice_cereal", "米精", in: app)
        XCTAssertNotEqual(app.staticTexts["foodBook.progress"].label, progressBefore, "計數要跟著減一")
    }

    /// 接縫⑥（03b 內刪除，呼叫路徑①）：作者在 03b 按「刪除這筆記錄」→ 03c → 兩層 sheet 收起、詳情頁也返回。
    func testAuthorDeletesInEditSheet_popsBackToBook() {
        let app = Support.launch(.foodRecordDetailFlow, Support.standard)
        openDetail("bread", in: app)
        app.buttons["foodRecordDetail.edit"].tap()
        let delete = app.buttons["foodRecord.delete"]
        Support.scrollUntilHittable(delete, in: app)
        delete.tap()
        XCTAssertTrue(app.staticTexts["要刪除吐司麵包這筆記錄嗎？"].waitForExistence(timeout: 5))
        Support.confirmDeleteButton(in: app).tap()

        XCTAssertTrue(app.staticTexts["編輯吐司麵包這筆記錄"].waitUntilGone(timeout: 5))
        XCTAssertTrue(app.staticTexts["foodRecordDetail.title"].waitUntilGone(timeout: 5), "詳情頁要一起返回")
        assertCellUntried("bread", "吐司麵包", in: app)
    }

    /// 接縫①（加照片，Notes `xFvkL`）：04b 空白沖印品 → 從家庭相簿挑 → 用這張 → 直接存、詳情頁換成照片。
    func testAddPhotoFromBlankPrint_savesAndShowsPhoto() {
        let app = Support.launch(.foodRecordDetailFlow, Support.standard)
        openDetail("pumpkin", in: app)
        let addPhoto = Support.element("foodRecordDetail.addPhoto", in: app)
        XCTAssertTrue(addPhoto.waitForExistence(timeout: 5))
        addPhoto.tap()
        let fromAlbum = app.buttons["從家庭相簿挑"]
        XCTAssertTrue(fromAlbum.waitForExistence(timeout: 5))
        fromAlbum.tap()
        let photo = app.buttons["foodPhoto.00000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(photo.waitForHittable(timeout: 5))
        photo.tap()
        app.buttons["foodPhoto.use"].tap()

        XCTAssertTrue(app.staticTexts["從家庭相簿挑一張"].waitUntilGone(timeout: 5))
        XCTAssertTrue(addPhoto.waitUntilGone(timeout: 5), "存好後空白沖印品要換成照片")
        XCTAssertTrue(Support.element("foodRecordDetail.photo", in: app).waitForExistence(timeout: 5))
    }

    /// LS-434 04f（稿 `liRRE`）：04b 選好照片即存、存不起來 → 開 03b 帶入已選照片，Status Slot 是專屬句
    /// `food.add_photo_failed`；恢復路徑不放「刪除這筆記錄」（Notes `PfdtV`）。
    func testAddPhotoSaveFails_opensEditSheetWithPhotoAndDedicatedSentenceWithoutDelete() {
        let app = Support.launch(
            .foodRecordDetailFlow, Support.standard, extraArguments: ["-LSFoodRecordFlowUpsertFails", "YES"]
        )
        openDetail("pumpkin", in: app)
        Support.element("foodRecordDetail.addPhoto", in: app).tap()
        app.buttons["從家庭相簿挑"].tap()
        let photo = app.buttons["foodPhoto.00000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(photo.waitForHittable(timeout: 5))
        photo.tap()
        app.buttons["foodPhoto.use"].tap()

        XCTAssertTrue(app.staticTexts["編輯南瓜這筆記錄"].waitForExistence(timeout: 10), "存不起來要開 03b")
        XCTAssertTrue(Support.element("foodRecord.photoThumb", in: app).waitForExistence(timeout: 5), "剛選的照片已在照片欄")
        let status = Support.element("foodRecord.statusText", in: app)
        XCTAssertTrue(
            Support.waitForLabel(
                status, where: "==", "照片沒有加上去：網路好像斷了。照片還在這裡，連上網路後按「儲存」。"
            ),
            "04f 專屬句逐字：\(status.label)"
        )
        XCTAssertTrue(app.buttons["foodRecord.save"].exists)
        let save = app.buttons["foodRecord.save"]
        Support.scrollUntilHittable(save, in: app)
        XCTAssertFalse(app.buttons["foodRecord.delete"].exists, "恢復路徑不放「刪除這筆記錄」")
    }

    /// 接縫④：記錄已在後端被刪（圖鑑還以為吃過）→ 開詳情一重讀就發現、返回圖鑑，格子退回未吃。
    func testRecordGoneOnRefresh_popsAndCellReturnsToUntried() {
        let app = Support.launch(
            .foodRecordDetailFlow, Support.standard, extraArguments: ["-LSFoodRecordFlowGone", "YES"]
        )
        let cell = app.buttons["foodCell.pumpkin"]
        Support.scrollUntilHittable(cell, in: app)
        XCTAssertTrue(cell.label.contains("第一次吃到"), "前提：圖鑑還以為吃過")
        cell.tap()
        // 詳情頁推入後重讀發現已刪即返回——可能快到來不及看見標題，直接等格子退回未吃（在圖鑑上才看得到格子）。
        assertCellUntried("pumpkin", "南瓜", in: app)
        XCTAssertFalse(app.staticTexts["foodRecordDetail.title"].exists, "不能停在一筆已刪的記錄上")
    }

    // MARK: - helpers

    private func openDetail(_ foodID: String, in app: XCUIApplication, line: UInt = #line) {
        let cell = app.buttons["foodCell.\(foodID)"]
        Support.scrollUntilHittable(cell, in: app)
        XCTAssertTrue(cell.waitForHittable(timeout: 5), "找不到格子 \(foodID)", line: line)
        cell.tap()
        XCTAssertTrue(app.staticTexts["foodRecordDetail.title"].waitForExistence(timeout: 5), line: line)
    }

    private func assertCellUntried(_ foodID: String, _ name: String, in app: XCUIApplication, line: UInt = #line) {
        let cell = app.buttons["foodCell.\(foodID)"]
        XCTAssertTrue(
            Support.waitForLabel(cell, where: "BEGINSWITH", "\(name)，還沒吃過"), "格子要退回未吃：\(cell.label)",
            line: line
        )
    }
}

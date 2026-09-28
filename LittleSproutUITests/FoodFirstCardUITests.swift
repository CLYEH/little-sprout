import XCTest

/// LS-383：時間軸「第一次吃到〇〇」卡片（`FoodFirstCardView`，稿 05 `SLjde`／深色 `QGdHY`／AX3 `CgmBD`）——
/// host 是真的 `TimelineView`（`TapTargetGateHarness+FoodFirstCard.swift`），驗：
/// - 驗收②「Book Row 導向該類別」：點 Book Row 推圖鑑、選在那項食物的類別（優格＝乳製品，不是預設的穀物根莖）。
/// - 整張卡點了開記錄詳情（範圍 3）。
/// - 驗收②「無互動列」：食物卡沒有愛心／留言；同屏的日記卡照樣有（證明 harness 會畫互動列）。
/// - 四態念出來的內容（反應／一句話有就念、沒有就不念）。
/// - 驗收①截圖：四態 × 淺深 × xSmall／預設／AX3（`XCTAttachment` `.keepAlways`，名稱 `LS-383-<字級>-<色>-<序號>`）。
@MainActor
final class FoodFirstCardUITests: XCTestCase {
    private static let xSmall = "UICTContentSizeCategoryXS"
    private static let standard = "UICTContentSizeCategoryL"
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"
    private static let cardID = "qa.timeline.foodFirstCard"
    private static let bookRowID = "qa.timeline.foodFirstBookRow"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone（compact）時間軸版面")
    }

    // MARK: - Book Row 導向該類別

    func testBookRow_opensFoodBookOnTheFoodsCategory() {
        let app = launch(fixture: "dairy", size: Self.standard)
        let bookRow = app.buttons[Self.bookRowID]
        XCTAssertTrue(bookRow.waitForHittable(timeout: 5), "Book Row 應是可點的獨立按鈕")
        XCTAssertEqual(bookRow.label, "收進小安的飲食圖鑑 · 乳製品")

        bookRow.tap()

        let dairyTab = app.buttons["foodTab.dairy"]
        XCTAssertTrue(dairyTab.waitForExistence(timeout: 5), "應推入飲食圖鑑 02")
        XCTAssertTrue(dairyTab.isSelected, "圖鑑應直接選在乳製品，不是預設第一類")
        XCTAssertFalse(app.buttons["foodTab.grain_root"].isSelected)
        XCTAssertEqual(app.staticTexts["foodBook.categoryCount"].label, "吃過 1／7", "乳製品 7 樣裡吃過優格 1 樣")
    }

    // MARK: - 整張卡 → 記錄詳情

    func testCardTap_opensRecordDetail() {
        let app = launch(fixture: "dairy", size: Self.standard)
        let card = app.buttons[Self.cardID]
        XCTAssertTrue(card.waitForHittable(timeout: 5))

        // 點貼紙／標題那一帶（卡片左上），不點到卡內另一顆 Book Row。
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.12)).tap()

        let title = app.staticTexts["foodRecordDetail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "整張卡點了應推入記錄詳情 04")
        XCTAssertEqual(title.label, "優格")
    }

    /// R2（LS-380 併入後的接縫）：從時間軸推入的詳情頁走 `FoodRecordDetailRouter`——作者按「編輯這筆記錄」真的開出
    /// 03b，改反應存檔後回到詳情頁就是新值（不再是空的 `onRoute`）。R3：時間軸這一側不再自己握存好的那筆，
    /// 「存檔後顯示新值」完全靠 router 的 `shownRecord(caller:saved:)`（推入的快照 `initialRecord` 不會變）。
    func testCardDetail_editHookOpensSheetAndSaves() {
        let app = launch(fixture: "dairy", size: Self.standard)
        let card = app.buttons[Self.cardID]
        XCTAssertTrue(card.waitForHittable(timeout: 5))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.12)).tap()

        let edit = app.buttons["foodRecordDetail.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "作者看得到編輯鈕")
        edit.tap()
        XCTAssertTrue(app.staticTexts["編輯優格這筆記錄"].waitForExistence(timeout: 5), "編輯 hook 應開出 03b")
        let neutral = app.buttons["foodRecord.reaction.neutral"]
        scrollUntilHittable(neutral, in: app)
        neutral.tap()
        let save = app.buttons["foodRecord.save"]
        scrollUntilHittable(save, in: app)
        save.tap()

        XCTAssertTrue(app.staticTexts["編輯優格這筆記錄"].waitUntilGone(timeout: 5))
        let reaction = app.descendants(matching: .any)["foodRecordDetail.reaction"].firstMatch
        // push gate 實測：sheet 收起的那一刻直接對 label 求值，可能在元素重新出現前就取 snapshot 失敗
        // （「No matches found」），不會重試——先等元素存在，再等 label。
        XCTAssertTrue(reaction.waitForExistence(timeout: 5), "存檔後應回到詳情頁的反應 chip")
        let updated = NSPredicate(format: "label == %@", "普通")
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation(for: updated, evaluatedWith: reaction)], timeout: 5), .completed,
            "詳情頁要換成剛存的反應：\(reaction.label)"
        )
    }

    /// LS-393（merge-review LS-383 R3 i8）：詳情頁存檔後時間軸要**強制**重讀（`TimelineView+Food.swift`
    /// `refreshAfterFoodRecordChange` → `refreshWithCurrentFilter()`：用 store 自己記的 familyID、不合流到存檔前
    /// 那一輪）——返回時間軸，卡片念出剛存的反應，不是推入前的舊值。harness 的時間軸 client 回假 client 目前的
    /// 記錄（`FoodFirstCardTimelineAPIClient`），重讀有跑就換新；harness 不種 `myFamily`，改回依賴
    /// `familyStore.myFamily` 的寫法就不會重讀，本測試轉紅。
    func testCardDetail_saveThenBack_timelineCardShowsSavedReaction() {
        let app = launch(fixture: "dairy", size: Self.standard)
        let card = app.buttons[Self.cardID]
        XCTAssertTrue(card.waitForHittable(timeout: 5))
        XCTAssertTrue(card.label.contains("喜歡"), "前提：優格卡原本是「喜歡」，實際：\(card.label)")
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.12)).tap()

        let edit = app.buttons["foodRecordDetail.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "作者看得到編輯鈕")
        edit.tap()
        let neutral = app.buttons["foodRecord.reaction.neutral"]
        scrollUntilHittable(neutral, in: app)
        neutral.tap()
        let save = app.buttons["foodRecord.save"]
        scrollUntilHittable(save, in: app)
        save.tap()
        XCTAssertTrue(app.staticTexts["編輯優格這筆記錄"].waitUntilGone(timeout: 5))
        XCTAssertTrue(app.staticTexts["foodRecordDetail.title"].waitForExistence(timeout: 5), "存檔後留在詳情頁")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "返回時間軸")
        let updated = NSPredicate(format: "label CONTAINS %@", "普通")
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation(for: updated, evaluatedWith: card)], timeout: 5), .completed,
            "存檔後時間軸要重讀、卡片換成剛存的反應「普通」，實際：\(card.label)"
        )
    }

    // MARK: - 無互動列

    func testFoodCards_haveNoInteractionRow_whileDiaryCardDoes() {
        let app = launch(fixture: "spec", size: Self.standard)
        XCTAssertTrue(
            app.buttons["qa.interactionRow.diary.likeToggle"].waitForExistence(timeout: 5),
            "同屏日記卡應有互動列（證明 harness 會畫互動列）"
        )
        let foodInteraction = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "qa.interactionRow.food_first")).count
        XCTAssertEqual(foodInteraction, 0, "v1 食物卡不畫留言／愛心列")
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: Self.cardID).count, 1)
    }

    // MARK: - 四態念出來的內容

    func testFourStates_spokenContent() {
        let app = launch(fixture: "spec", size: Self.standard)
        // 同日並列：芋頭卡與日記卡在同一個 Day Divider 底下，芋頭排第一張。
        assertCard(in: app, containing: "第一次吃到芋頭", includes: ["普通", "有點黏"], excludes: [])
        assertCard(in: app, containing: "第一次吃到吐司麵包", includes: ["喜歡", "滿臉都是麵包屑", "照片"], excludes: [])
        assertCard(in: app, containing: "第一次吃到玉米", includes: [], excludes: ["喜歡", "普通", "不愛吃", "照片"])
        assertCard(in: app, containing: "第一次吃到南瓜", includes: ["喜歡", "把整碗吃光了"], excludes: ["照片"])
    }

    // MARK: - 截圖矩陣（驗收①）

    func testScreenshotMatrix() {
        for (sizeName, size) in [("xSmall", Self.xSmall), ("L", Self.standard), ("AX3", Self.ax3)] {
            for scheme in ["light", "dark"] {
                let app = launch(fixture: "spec", size: size, scheme: scheme)
                let last = app.buttons.matching(
                    NSPredicate(format: "identifier == %@ AND label CONTAINS %@", Self.cardID, "第一次吃到南瓜")
                ).firstMatch
                var index = 0
                while true {
                    attach(app, name: "LS-383-\(sizeName)-\(scheme)-\(index)")
                    if last.exists && last.isHittable && lastSignatureVisible(app) { break }
                    XCTAssertLessThan(index, 12, "[\(sizeName)-\(scheme)] 捲 12 次仍看不到最後一張卡的署名")
                    app.swipeUp(velocity: .slow)
                    index += 1
                }
                app.terminate()
            }
        }
    }

    // MARK: - helpers

    private func launch(fixture: String, size: String, scheme: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = "FoodFirstCardView"
        app.launchEnvironment["LS_FOOD_FIRST_FIXTURE"] = fixture
        app.launchEnvironment["LS_FOOD_FIRST_SCHEME"] = scheme
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        app.launch()
        XCTAssertTrue(app.buttons[Self.cardID].firstMatch.waitForExistence(timeout: 10), "食物卡沒渲染")
        return app
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
    }

    private func assertCard(
        in app: XCUIApplication, containing headline: String, includes: [String], excludes: [String],
        line: UInt = #line
    ) {
        let card = app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", Self.cardID, headline)
        ).firstMatch
        var attempts = 0
        while !card.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(card.exists, "找不到「\(headline)」卡", line: line)
        let label = card.label
        for text in includes {
            XCTAssertTrue(label.contains(text), "「\(headline)」卡應念出「\(text)」，實際：\(label)", line: line)
        }
        for text in excludes {
            XCTAssertFalse(label.contains(text), "「\(headline)」卡不該念出「\(text)」，實際：\(label)", line: line)
        }
    }

    /// 最後一張（南瓜）卡的署名整段在畫面內——卡片 button 的 frame 包含署名列，底緣在視窗內即可。
    private func lastSignatureVisible(_ app: XCUIApplication) -> Bool {
        let last = app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", Self.cardID, "第一次吃到南瓜")
        ).firstMatch
        return last.exists && last.frame.maxY <= app.windows.firstMatch.frame.maxY
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

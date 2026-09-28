import XCTest

/// LS-382：寶貝詳情「飲食圖鑑」入口（01 `QRoGt`／01b `J58vyP`／01c `ls2g6`／A11y/01 `BSWDH`／深色 `LNHXU`／`wcpNj`）
/// ——iPhone（compact）專用；iPad 五格見 `FoodBookEntryIPadTests`。fixture 見 `TapTargetGateHarness+FoodEntry.swift`。
///
/// 截圖（`XCTAttachment`，`.keepAlways`）：01／01b／01c × 淺深 × xSmall／預設／AX3，對稿用。
@MainActor
final class FoodBookEntryUITests: XCTestCase {
    private static let xSmall = "UICTContentSizeCategoryXS"
    private static let standard = "UICTContentSizeCategoryL"
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone（compact）版面測試；iPad 見 FoodBookEntryIPadTests")
    }

    // MARK: - 範圍 2：三態等高、按鈕不位移

    /// 0 筆（01b）／1 筆（01c）／38 筆（01）三態：區塊高度（標題頂 → 按鈕底）相同、按鈕 y 相同（上方成長區塊三個
    /// fixture 一樣，所以直接比絕對座標，不捲動）；三格同高。Notes `h752D`「01 與 01b 同高、按鈕不位移」。
    func testThreeStates_blockHeightAndButtonPositionAreEqual() {
        struct Measured {
            let screen: String, buttonY: CGFloat, height: CGFloat, cellHeight: CGFloat, cellCount: Int
        }
        var measured: [Measured] = []
        for screen in [TapTargetGateScreenName.growthDetailFood, .growthDetailFoodOne, .growthDetailFoodEmpty] {
            let app = launch(screen, Self.standard)
            let title = element("foodEntry.title", in: app)
            let button = app.buttons["foodEntry.openBook"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(screen.rawValue) 沒有圖鑑按鈕")
            let cells = entryCells(in: app)
            measured.append(Measured(
                screen: screen.rawValue, buttonY: button.frame.minY, height: button.frame.maxY - title.frame.minY,
                cellHeight: cells.map(\.frame.height).max() ?? 0, cellCount: cells.count
            ))
        }
        let reference = measured[0]
        for other in measured.dropFirst() {
            let pair = "\(other.screen) vs \(reference.screen)"
            XCTAssertEqual(other.buttonY, reference.buttonY, accuracy: 0.5, "按鈕 y：\(pair)")
            XCTAssertEqual(other.height, reference.height, accuracy: 0.5, "區塊高：\(pair)")
            XCTAssertEqual(other.cellHeight, reference.cellHeight, accuracy: 0.5, "格子高：\(other.screen)")
        }
        // 位置先比、格數後比：格數少了（沒補空位）的主要後果就是按鈕上移，讓斷言訊息直接指出這件事。
        XCTAssertEqual(measured.map(\.cellCount), [3, 3, 3], "三態都固定三格")
    }

    // MARK: - 範圍 1：計數句、三格內容與順序（逐字對稿）

    func testDemo_01_recentThreeNewestFirst() {
        let app = launch(.growthDetailFood, Self.standard)
        XCTAssertEqual(countLine(in: app), "陳小安吃過 38／274\u{00A0}種，最近三樣：")
        XCTAssertEqual(entryFoodIDs(in: app), ["banana", "tofu", "egg_yolk"])
        XCTAssertEqual(app.buttons["foodCell.banana"].label, "香蕉，2026/8/2 第一次吃到")
        XCTAssertEqual(app.buttons["foodCell.tofu"].label, "豆腐，2026/7/19 第一次吃到，含大豆")
        XCTAssertEqual(app.buttons["foodEntry.openBook"].label, "看整本飲食圖鑑")
    }

    func testEmpty_01b_firstThreeBySortOrder() {
        let app = launch(.growthDetailFoodEmpty, Self.standard)
        XCTAssertEqual(countLine(in: app), "陳小安吃過 0／274\u{00A0}種，可以從這三樣開始：")
        XCTAssertEqual(entryFoodIDs(in: app), ["rice_cereal", "rice_porridge", "oatmeal"])
        XCTAssertEqual(app.buttons["foodCell.rice_cereal"].label, "米精，還沒吃過")
        XCTAssertEqual(app.buttons["foodEntry.openBook"].label, "打開飲食圖鑑")
    }

    func testOne_01c_triedFirstThenUntriedBySortOrder() {
        let app = launch(.growthDetailFoodOne, Self.standard)
        XCTAssertEqual(countLine(in: app), "陳小安吃過 1／274\u{00A0}種，最近和接著試的：")
        XCTAssertEqual(entryFoodIDs(in: app), ["rice_cereal", "rice_porridge", "oatmeal"])
        XCTAssertEqual(app.buttons["foodCell.rice_cereal"].label, "米精，2025/10/22 第一次吃到")
        XCTAssertEqual(app.buttons["foodCell.rice_porridge"].label, "白粥，還沒吃過")
    }

    // MARK: - 範圍 2：點空位 → 03 → 收下；吃過 → 04；次要鈕 → 02（共用 store）

    /// 01b 點「白粥」空位 → 03 → 儲存 → sheet 收起 → 白粥變吃過並排到第一格、計數與文案跟著換。
    func testTappingEmptySlot_savesAndCellBecomesFirstTried() {
        let app = launch(.growthDetailFoodEmpty, Self.standard)
        let porridge = app.buttons["foodCell.rice_porridge"]
        scrollUntilHittable(porridge, in: app)
        porridge.tap()
        XCTAssertTrue(app.staticTexts["記下陳小安第一次吃白粥"].waitForExistence(timeout: 5), "點空位要開 03")
        let save = app.buttons["foodRecord.save"]
        scrollUntilHittable(save, in: app)
        save.tap()
        XCTAssertTrue(app.staticTexts["記下陳小安第一次吃白粥"].waitUntilGone(timeout: 5), "儲存成功要收起 sheet")

        XCTAssertTrue(waitForLabel(porridge, contains: "第一次吃到"), "白粥要變吃過：\(porridge.label)")
        XCTAssertEqual(
            entryFoodIDs(in: app), ["rice_porridge", "rice_cereal", "oatmeal"], "剛記的（今天）排第一，空位依 sort_order 補"
        )
        XCTAssertEqual(countLine(in: app), "陳小安吃過 1／274\u{00A0}種，最近和接著試的：")
    }

    /// 「看整本飲食圖鑑」推 02；在圖鑑裡記下糙米飯、返回——入口不重抓也已經是新的（兩處共用同一顆 store）。
    func testBookButton_opensBook_andSaveInBookUpdatesEntry() {
        let app = launch(.growthDetailFood, Self.standard)
        let open = app.buttons["foodEntry.openBook"]
        scrollUntilHittable(open, in: app)
        open.tap()
        XCTAssertTrue(
            app.staticTexts["foodBook.progress"].waitForExistence(timeout: 5), "次要鈕要推整本圖鑑（02）"
        )
        XCTAssertEqual(app.staticTexts["foodBook.progress"].label, "陳小安吃過 38\u{00A0}種，全部 274\u{00A0}種。")
        let brownRice = app.buttons["foodCell.brown_rice"]
        scrollUntilHittable(brownRice, in: app)
        brownRice.tap()
        let save = app.buttons["foodRecord.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        scrollUntilHittable(save, in: app)
        save.tap()
        XCTAssertTrue(save.waitUntilGone(timeout: 5))
        XCTAssertTrue(waitForLabel(brownRice, contains: "第一次吃到"))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("foodEntry.countLine", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(countLine(in: app), "陳小安吃過 39／274\u{00A0}種，最近三樣：")
        XCTAssertEqual(entryFoodIDs(in: app).first, "brown_rice", "圖鑑裡記的（今天）要排進入口第一格")
    }

    /// 吃過的格子推 04 記錄詳情（正式詳情頁，不是 LS-381 佔位）。
    func testTappingTriedCell_opensRecordDetail() {
        let app = launch(.growthDetailFood, Self.standard)
        let banana = app.buttons["foodCell.banana"]
        scrollUntilHittable(banana, in: app)
        banana.tap()
        XCTAssertTrue(element("foodRecordDetail.title", in: app).waitForExistence(timeout: 5), "吃過的格子要推 04")
        XCTAssertFalse(app.staticTexts["這個畫面由 LS-381 實作，尚未完成。"].exists)
    }

    /// Notes 01 列「失敗文案鍵 42501」：首次讀取失敗＝錯誤句＋「重新載入」，不畫全灰三格。
    func testLoadFailure_showsErrorAndReload_noCells() {
        let app = launch(.growthDetailFoodFailure, Self.standard)
        XCTAssertTrue(app.buttons["foodEntry.reload"].waitForExistence(timeout: 5))
        XCTAssertTrue(entryCells(in: app).isEmpty, "讀取失敗不能落回全灰格子")
        XCTAssertFalse(app.buttons["foodEntry.openBook"].exists)
        attachScreenshotAfterScrolling(app, to: app.buttons["foodEntry.reload"], "01-failure")
    }

    // MARK: - 範圍 3：AX3（A11y/01 `BSWDH`）

    func testAX3_cellsStackVerticallyAndShortButtonTitle() {
        let app = launch(.growthDetailFood, Self.ax3)
        let cells = entryCells(in: app)
        XCTAssertEqual(cells.count, 3)
        XCTAssertEqual(cells[0].frame.minX, cells[1].frame.minX, accuracy: 1, "AX3 直排清單：左緣對齊")
        XCTAssertGreaterThan(cells[1].frame.minY, cells[0].frame.maxY - 1, "AX3 一列一格")
        XCTAssertEqual(app.buttons["foodEntry.openBook"].label, "看整本圖鑑", "A11y/01 `Gke1S` 短文案")
    }

    // MARK: - 對稿截圖

    func testScreenshots_01() { screenshots(.growthDetailFood, "01") }
    func testScreenshots_01b() { screenshots(.growthDetailFoodEmpty, "01b") }
    func testScreenshots_01c() { screenshots(.growthDetailFoodOne, "01c") }

    private func screenshots(_ screen: TapTargetGateScreenName, _ board: String) {
        let sizes = [("xSmall", Self.xSmall), ("default", Self.standard), ("AX3", Self.ax3)]
        for dark in [false, true] {
            for (sizeName, size) in sizes {
                let app = launch(screen, size, dark: dark)
                attachScreenshotAfterScrolling(
                    app, to: app.buttons["foodEntry.openBook"], "\(board)-\(dark ? "dark" : "light")-\(sizeName)"
                )
            }
        }
    }

    // MARK: - helpers

    private func launch(_ screen: TapTargetGateScreenName, _ size: String, dark: Bool = false) -> XCUIApplication {
        let app = TapTargetMeasurement.launch(
            screen, contentSizeCategory: size, extraLaunchArguments: dark ? ["-LSFoodEntryDark", "YES"] : []
        )
        TapTargetMeasurement.assertScreenRendered(screen, in: app)
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func countLine(in app: XCUIApplication) -> String {
        let line = element("foodEntry.countLine", in: app)
        XCTAssertTrue(line.waitForExistence(timeout: 5), "找不到計數句")
        return line.label
    }

    /// 入口的格子（依畫面位置排序：先 y 再 x）。宿主畫面只有入口有 `foodCell.*`。
    private func entryCells(in app: XCUIApplication) -> [XCUIElement] {
        _ = element("foodEntry.title", in: app).waitForExistence(timeout: 5)
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "foodCell.")
        let query = app.descendants(matching: .any).matching(predicate)
        return query.allElementsBoundByIndex.sorted {
            abs($0.frame.minY - $1.frame.minY) > 1 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        }
    }

    private func entryFoodIDs(in app: XCUIApplication) -> [String] {
        entryCells(in: app).map { String($0.identifier.dropFirst("foodCell.".count)) }
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !element.waitForHittable(timeout: 1) && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
    }

    private func waitForLabel(_ element: XCUIElement, contains value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", value), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    private func attachScreenshotAfterScrolling(_ app: XCUIApplication, to target: XCUIElement, _ name: String) {
        scrollUntilHittable(target, in: app)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "LS-382-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

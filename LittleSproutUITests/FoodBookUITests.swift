import XCTest

/// LS-379：飲食圖鑑 02 家族（`hWu6N`／`XuCDh`／`x3aELx`／`SYefI`／`jo5h8`）的版面與互動回歸——iPhone
/// （compact）專用；iPad 4 欄見 `FoodBookIPadTests`。共用 `TapTargetGateHarness+Food.swift` 的四個 host
/// （示範資料：陳小安 38／274、穀物根莖 10／16）。
///
/// 每支都附整頁截圖（`XCTAttachment`，`.keepAlways`），xSmall／預設／AX3 × 淺／深對稿用。AX 字級走
/// `launchArguments`（`TapTargetMeasurement.launch(_:contentSizeCategory:)`，LS-210 教訓）。
@MainActor
final class FoodBookUITests: XCTestCase {
    private static let xSmall = "UICTContentSizeCategoryXS"
    private static let standard = "UICTContentSizeCategoryL"
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone（compact）版面測試；iPad 見 FoodBookIPadTests")
    }

    // MARK: - 02 預設字級（範圍 1／2／3）

    func testDefault_headerCountTabsGridMatchDesign() {
        let app = launch(.foodBook, Self.standard)

        XCTAssertEqual(
            app.staticTexts["foodBook.progress"].label, "陳小安吃過 38\u{00A0}種，全部 274\u{00A0}種。",
            "計數句（稿 `azRUz`，「種」前 U+00A0）"
        )
        XCTAssertEqual(app.staticTexts["foodBook.categoryCount"].label, "吃過 10／16")
        XCTAssertTrue(app.staticTexts["點灰色的格子，就能記下第一次吃到的日子。"].exists)
        assertTabsTwoRowsOfFour(in: app)
        assertSelectedTab(.grainRoot, in: app)

        // 3 欄：前三格同一列、第四格換列（稿 `M6HLFN`／`lFvdW`）。
        let first = cell("rice_cereal", in: app), second = cell("rice_porridge", in: app)
        let third = cell("oatmeal", in: app), fourth = cell("white_rice", in: app)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1)
        XCTAssertEqual(first.frame.minY, third.frame.minY, accuracy: 1)
        XCTAssertGreaterThan(fourth.frame.minY, first.frame.maxY - 1, "第四格應該換到下一列")
        XCTAssertTrue(app.buttons["foodCell.brown_rice"].exists, "member 的空位是按鈕（開第一次記錄）")
        XCTAssertTrue(app.buttons["foodCell.pumpkin"].exists, "吃過的格子是按鈕（開記錄詳情）")
        XCTAssertEqual(
            app.buttons["foodCell.oatmeal"].label, "燕麥粥，2026/1/5 第一次吃到，含麩質",
            "吃過＝日期 yyyy/M/d＋過敏原小標（稿 `G7yV0U`）"
        )
        XCTAssertEqual(app.buttons["foodCell.brown_rice"].label, "糙米飯，還沒吃過")
        attachScreenshot(app, "02-light-default")
    }

    func testDefault_disclaimerSitsAfterGrid() {
        let app = launch(.foodBook, Self.standard)
        let disclaimer = app.descendants(matching: .any)["foodBook.disclaimer"].firstMatch
        let lastCell = cell("steamed_bun", in: app)
        scrollUntilHittable(disclaimer, in: app)
        XCTAssertTrue(disclaimer.label.contains("這些只是提醒，不是醫療建議；有疑問請問醫師。"), disclaimer.label)
        XCTAssertGreaterThan(disclaimer.frame.minY, lastCell.frame.maxY, "免責句固定排在格子之後（MJ-2）")
    }

    func testSelectingDairyTab_switchesCategoryCountAndTags() {
        let app = launch(.foodBook, Self.standard)
        app.buttons["foodTab.dairy"].tap()

        assertSelectedTab(.dairy, in: app)
        XCTAssertTrue(app.staticTexts["foodBook.categoryCount"].waitForLabel("吃過 1／7", timeout: 5))
        XCTAssertEqual(app.buttons["foodCell.fresh_milk"].label, "鮮奶，還沒吃過，含牛奶，一歲後")
        XCTAssertEqual(app.buttons["foodCell.milk_pudding"].label, "布丁，還沒吃過，含牛奶等")
        XCTAssertEqual(app.buttons["foodCell.yogurt"].label, "優格，2026/5/2 第一次吃到，含牛奶")
    }

    /// 本票先接 placeholder：空位開第一次記錄 sheet（LS-380）、吃過的格子推記錄詳情（LS-381）。
    func testTappingCells_opensPendingDestinations() {
        let app = launch(.foodBook, Self.standard)
        app.buttons["foodCell.brown_rice"].tap()
        XCTAssertTrue(app.staticTexts["這個畫面由 LS-380 實作，尚未完成。"].waitForExistence(timeout: 5))
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.staticTexts["這個畫面由 LS-380 實作，尚未完成。"].waitUntilGone(timeout: 5))

        app.buttons["foodCell.pumpkin"].tap()
        XCTAssertTrue(app.staticTexts["這個畫面由 LS-381 實作，尚未完成。"].waitForExistence(timeout: 5))
    }

    /// 未吃＝灰階（App 端 `.saturation(0).opacity(0.6)`，Notes `DpExV`）、吃過＝彩色——以像素色度量：
    /// 灰階貼紙疊在粉底上，最鮮豔的也只是底色／`$text-secondary` 文字的色度（< 40）；紫地瓜、南瓜原圖
    /// 色度遠超 60。拿「高色度像素佔比」判斷，不依賴特定座標。
    func testUntriedStickerIsGrayscale_triedStickerIsColored() {
        let app = launch(.foodBook, Self.standard)
        let untried = cell("purple_sweet_potato", in: app)
        let tried = cell("pumpkin", in: app)
        scrollUntilHittable(tried, in: app)
        let untriedRatio = vividPixelRatio(in: untried)
        let triedRatio = vividPixelRatio(in: tried)
        XCTAssertLessThan(untriedRatio, 0.005, "未吃的紫地瓜應該是灰階，高色度像素佔比 \(untriedRatio)")
        XCTAssertGreaterThan(triedRatio, 0.05, "吃過的南瓜應該是彩色，高色度像素佔比 \(triedRatio)（量測自我檢查）")
    }

    // MARK: - 02b／02c

    func testDairyVariant_02b_rendersAgeAndAllergenTags() {
        let app = launch(.foodBookDairy, Self.standard)
        assertSelectedTab(.dairy, in: app)
        XCTAssertTrue(app.buttons["foodCell.fresh_milk"].label.hasSuffix("含牛奶，一歲後"))
        attachScreenshot(app, "02b-dairy")
    }

    /// 02c viewer：空位不是按鈕（稿 `jo5h8`、Notes `J8qvq5`），提示句換唯讀版；吃過的格子仍可看詳情。
    func testViewerVariant_02c_untriedCellsAreNotButtons() {
        let app = launch(.foodBookViewer, Self.standard)
        XCTAssertFalse(app.buttons["foodCell.brown_rice"].exists, "viewer 的空位不能是按鈕")
        XCTAssertTrue(
            app.descendants(matching: .any)["foodCell.brown_rice"].exists, "空位本身仍要顯示（只是不能點）"
        )
        XCTAssertTrue(app.buttons["foodCell.pumpkin"].exists, "吃過的格子 viewer 也能點進去看")
        XCTAssertFalse(app.staticTexts["點灰色的格子，就能記下第一次吃到的日子。"].exists)
        attachScreenshot(app, "02c-viewer")
    }

    // MARK: - 字級與深色（範圍 5）

    func testXSmall_keepsThreeColumnsAndTwoByFourTabs() {
        let app = launch(.foodBook, Self.xSmall)
        assertTabsTwoRowsOfFour(in: app)
        XCTAssertEqual(cell("rice_cereal", in: app).frame.minY, cell("oatmeal", in: app).frame.minY, accuracy: 1)
        attachScreenshot(app, "02-light-xSmall")
    }

    func testDark_rendersSameStructure() {
        let app = launch(.foodBookDark, Self.standard)
        XCTAssertEqual(app.staticTexts["foodBook.categoryCount"].label, "吃過 10／16")
        assertTabsTwoRowsOfFour(in: app)
        attachScreenshot(app, "02-dark-default")
    }

    func testDarkXSmall_screenshot() {
        let app = launch(.foodBookDark, Self.xSmall)
        assertTabsTwoRowsOfFour(in: app)
        attachScreenshot(app, "02-dark-xSmall")
    }

    /// AX3（A11y/02 `x3aELx`）：分頁 4 列 × 2 欄、格子改單欄橫排清單、空位可見「還沒吃過」。
    func testAX3_tabsFourByTwoAndSingleColumnList() {
        let app = launch(.foodBook, Self.ax3)
        let grain = app.buttons["foodTab.grain_root"], vegetable = app.buttons["foodTab.vegetable"]
        let fruit = app.buttons["foodTab.fruit"]
        XCTAssertEqual(grain.frame.minY, vegetable.frame.minY, accuracy: 1, "AX3 第一列：穀物根莖＋蔬菜")
        XCTAssertGreaterThan(fruit.frame.minY, grain.frame.maxY - 1, "AX3 水果換到第二列（4×2）")
        for tab in [grain, vegetable, fruit] {
            XCTAssertLessThanOrEqual(tab.frame.maxX, app.frame.maxX, "分頁不橫捲：每顆都在螢幕寬度內")
        }

        let first = cell("rice_cereal", in: app)
        scrollUntilHittable(first, in: app)
        let second = cell("rice_porridge", in: app)
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 1, "單欄清單：左緣對齊")
        XCTAssertGreaterThan(second.frame.minY, first.frame.maxY - 1, "單欄清單：一列一格")
        XCTAssertGreaterThan(first.frame.width, app.frame.width * 0.8, "清單列應接近全寬")
        attachScreenshot(app, "02-light-AX3")
    }

    func testDarkAX3_screenshot() {
        let app = launch(.foodBookDark, Self.ax3)
        XCTAssertTrue(app.buttons["foodTab.grain_root"].exists)
        attachScreenshot(app, "02-dark-AX3")
    }

    // MARK: - helpers

    private func launch(_ screen: TapTargetGateScreenName, _ size: String) -> XCUIApplication {
        let app = TapTargetMeasurement.launch(screen, contentSizeCategory: size)
        TapTargetMeasurement.assertScreenRendered(screen, in: app)
        return app
    }

    private func cell(_ foodID: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any)["foodCell.\(foodID)"].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "找不到格子 \(foodID)")
        return element
    }

    private enum Category: String {
        case grainRoot = "grain_root", vegetable, fruit, protein, dairy
        case fatNut = "fat_nut", twHome = "tw_home", snackDrink = "snack_drink"
        static let all: [Category] = [.grainRoot, .vegetable, .fruit, .protein, .dairy, .fatNut, .twHome, .snackDrink]
    }

    private func assertSelectedTab(_ selected: Category, in app: XCUIApplication, line: UInt = #line) {
        for category in Category.all {
            let tab = app.buttons["foodTab.\(category.rawValue)"]
            XCTAssertEqual(tab.isSelected, category == selected, "分頁 \(category.rawValue) 選中態錯誤", line: line)
        }
    }

    /// 2 列 × 4 欄、8 顆全部在螢幕寬度內（不橫捲）。
    private func assertTabsTwoRowsOfFour(in app: XCUIApplication, line: UInt = #line) {
        let tabs = Category.all.map { app.buttons["foodTab.\($0.rawValue)"] }
        for tab in tabs {
            XCTAssertTrue(tab.waitForExistence(timeout: 5), line: line)
            XCTAssertLessThanOrEqual(tab.frame.maxX, app.frame.maxX, "分頁不橫捲", line: line)
            // 容忍浮點雜訊（xSmall 實測 43.99999999999997），同 `TapTargetMeasurement.violations` 的 tolerance。
            XCTAssertGreaterThanOrEqual(tab.frame.height, 44 - 0.001, "分頁 ≥44pt", line: line)
        }
        for index in 1..<4 {
            XCTAssertEqual(tabs[index].frame.minY, tabs[0].frame.minY, accuracy: 1, "第一列四顆同高", line: line)
            XCTAssertEqual(tabs[index + 4].frame.minY, tabs[4].frame.minY, accuracy: 1, "第二列四顆同高", line: line)
        }
        XCTAssertGreaterThan(tabs[4].frame.minY, tabs[0].frame.maxY - 1, "乳製品起第二列", line: line)
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
    }

    /// 元件截圖中 max(R,G,B) − min(R,G,B) > 60 的像素佔比（重畫進 8-bit sRGB，同
    /// `InteractionRowUITests.maxTextContrast` 的取像手法）。
    private func vividPixelRatio(in element: XCUIElement) -> Double {
        guard let image = element.screenshot().image.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            XCTFail("元件截圖沒有 cgImage")
            return 0
        }
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, width * height > 0 else {
            XCTFail("無法建立 sRGB 點陣 context")
            return 0
        }
        var vivid = 0
        for pixel in 0..<(width * height) {
            let rgb = bytes[(pixel * 4)..<(pixel * 4 + 3)]
            if Int(rgb.max() ?? 0) - Int(rgb.min() ?? 0) > 60 { vivid += 1 }
        }
        return Double(vivid) / Double(width * height)
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "LS-379-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
            == .completed
    }
}

import XCTest

/// LS-380：`FoodRecordSheetUITests`／`FoodRecordSheetScreenshotTests` 共用的啟動與操作（一份實作，不在兩個
/// 測試檔各貼一份 `private func`，同 `AssertNoOverlap.swift` 的拆檔先例）。
@MainActor
enum FoodRecordUITestSupport {
    static let xSmall = "UICTContentSizeCategoryXS"
    static let standard = "UICTContentSizeCategoryL"
    static let ax1 = "UICTContentSizeCategoryAccessibilityM"
    static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    static func launch(
        _ screen: TapTargetGateScreenName, _ size: String, dark: Bool = false, extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = TapTargetMeasurement.launch(
            screen, contentSizeCategory: size,
            extraLaunchArguments: (dark ? ["-LSFoodRecordDark", "YES"] : []) + extraArguments
        )
        TapTargetMeasurement.assertScreenRendered(screen, in: app)
        return app
    }

    /// 從圖鑑點「芋頭」空位開 03（稿面示範食物），等表頭出現。
    static func openTaroSheet(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let taro = app.buttons["foodCell.taro"]
        // 芋頭是穀物根莖第 11 格（第 4 列），一般字級就在首屏之外；AX3 是 LazyVStack 清單，捲到之前根本還沒建出來。
        scrollUntilHittable(taro, in: app)
        XCTAssertTrue(taro.waitForHittable(timeout: 5), "找不到芋頭空位", file: file, line: line)
        taro.tap()
        XCTAssertTrue(
            app.staticTexts["記下小安第一次吃芋頭"].waitForExistence(timeout: 5), "03 表頭沒出現", file: file, line: line
        )
    }

    /// sheet 內容隨 sheet 捲動（Footer 不釘底）——往上滑直到元素可點。`waitForHittable` 不會自動捲動
    /// （`XCUIElement+Waits.swift` 文件註解）。
    static func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 10) {
        var swipes = 0
        while !element.waitForHittable(timeout: 1) && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
    }

    /// 03c 確認 sheet 的「刪除這筆記錄」——底下 03b（identifier `foodRecord.delete`）與 04c 詳情頁（`foodRecordDetail.delete`）
    /// 也各有一顆同字的，排除它們。
    static func confirmDeleteButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@ AND identifier != %@",
            "刪除這筆記錄", "foodRecord.delete", "foodRecordDetail.delete"
        )).firstMatch
    }

    static func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    static func waitForLabel(
        _ element: XCUIElement, where predicate: String, _ value: String, timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label \(predicate) %@", value), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

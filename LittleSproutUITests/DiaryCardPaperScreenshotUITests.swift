import XCTest

/// LS-446（LS-442 C3a）：日記卡改整張紙面——時間軸「照片卡＋食物卡＋日記卡」並列的對稿截圖
/// （稿 `Qohx3` 第三欄；淺／深／AX3），host 是真的 `TimelineView`
/// （`TapTargetGateHarness+FoodFirstCard.swift` 的 `paper` fixture）。
///
/// 除了截圖（`XCTAttachment` `.keepAlways`，名稱 `LS-446-<字級>-<色>-<序號>`），也斷言兩件機器可驗的事：
/// - 已按讚日記卡的 Like Toggle 念「已按愛心」（證明這張卡走的是已按讚分支，截圖裡的 #8E2447 才有意義）。
/// - 照片卡、日記卡的互動列都在（日記卡改紙面不得弄丟互動列；照片卡維持頁面底色那組）。
@MainActor
final class DiaryCardPaperScreenshotUITests: XCTestCase {
    private static let standard = "UICTContentSizeCategoryL"
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"
    private static let foodCardID = "qa.timeline.foodFirstCard"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone（compact）時間軸版面")
    }

    func testPaperDiaryCard_hasLikedStateAndInteractionRows() {
        let app = launch(size: Self.standard, scheme: "light")
        let liked = app.buttons["qa.interactionRow.diary.likeToggle"].firstMatch
        var attempts = 0
        while !liked.exists && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        let likedLabel = app.buttons.matching(NSPredicate(format: "label == %@", "已按愛心")).firstMatch
        XCTAssertTrue(likedLabel.exists, "種子裡有一張已按讚日記卡")
        XCTAssertTrue(app.buttons["qa.interactionRow.media.likeToggle"].firstMatch.exists, "照片卡互動列仍在")
        XCTAssertTrue(liked.exists, "日記卡互動列仍在")
    }

    func testScreenshotMatrix_lightDarkAX3() {
        for (sizeName, size) in [("L", Self.standard), ("AX3", Self.ax3)] {
            for scheme in ["light", "dark"] {
                let app = launch(size: size, scheme: scheme)
                let food = app.buttons[Self.foodCardID].firstMatch
                var index = 0
                while true {
                    attach(app, name: "LS-446-\(sizeName)-\(scheme)-\(index)")
                    if food.exists && food.frame.maxY <= app.windows.firstMatch.frame.maxY { break }
                    XCTAssertLessThan(index, 14, "[\(sizeName)-\(scheme)] 捲 14 次仍看不到食物卡")
                    app.swipeUp(velocity: .slow)
                    index += 1
                }
                app.terminate()
            }
        }
    }

    // MARK: - helpers

    private func launch(size: String, scheme: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = "FoodFirstCardView"
        app.launchEnvironment["LS_FOOD_FIRST_FIXTURE"] = "paper"
        app.launchEnvironment["LS_FOOD_FIRST_SCHEME"] = scheme
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        app.launch()
        XCTAssertTrue(
            app.buttons["qa.interactionRow.media.likeToggle"].firstMatch.waitForExistence(timeout: 10),
            "paper fixture 沒渲染（照片卡互動列不見）"
        )
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

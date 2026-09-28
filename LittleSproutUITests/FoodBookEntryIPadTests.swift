import XCTest

/// LS-382 範圍 3：寶貝詳情「飲食圖鑑」入口 01-iPad（`h5PBGH`）——Content Pane 內一列五格、計數句「最近五樣」；
/// 0 筆（01b 同版位）也是五格、按鈕位置不變。
///
/// 只在 iPad idiom 執行（`XCTSkipUnless`，理由同 `FoodBookIPadTests`）；類別名以 `IPadTests` 結尾讓 CI `ci-ipad`
/// 選得到。
@MainActor
final class FoodBookEntryIPadTests: XCTestCase {
    func testFoodEntryRegular_fiveCellsInOneRow_equalHeightAcrossStates() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad 專屬版面測試，非 iPad 裝置（例如 push-gate 常態用的 iPhone 專屬機）略過"
        )
        var blockHeights: [CGFloat] = []
        for (screen, expectedLine, expectedIDs) in [
            (TapTargetGateScreenName.growthDetailFood, "陳小安吃過 38／274\u{00A0}種，最近五樣：",
             ["banana", "tofu", "egg_yolk", "bread", "yogurt"]),
            (.growthDetailFoodEmpty, "陳小安吃過 0／274\u{00A0}種，可以從這五樣開始：",
             ["rice_cereal", "rice_porridge", "oatmeal", "white_rice", "brown_rice"])
        ] {
            let app = TapTargetMeasurement.launch(screen)
            TapTargetMeasurement.assertScreenRendered(screen, in: app)
            let line = app.descendants(matching: .any)["foodEntry.countLine"].firstMatch
            XCTAssertTrue(line.waitForExistence(timeout: 5))
            XCTAssertEqual(line.label, expectedLine)
            let cells = expectedIDs.map { app.descendants(matching: .any)["foodCell.\($0)"].firstMatch }
            for cell in cells { XCTAssertTrue(cell.waitForExistence(timeout: 5), "\(screen.rawValue) 缺 \(cell)") }
            for index in 1..<5 {
                XCTAssertEqual(cells[index].frame.minY, cells[0].frame.minY, accuracy: 1, "五格同一列")
                XCTAssertGreaterThan(cells[index].frame.minX, cells[index - 1].frame.minX, "依序由左到右")
            }
            let title = app.descendants(matching: .any)["foodEntry.title"].firstMatch
            let button = app.buttons["foodEntry.openBook"]
            blockHeights.append(button.frame.maxY - title.frame.minY)

            var swipes = 0
            while !button.waitForHittable(timeout: 1) && swipes < 10 {
                app.swipeUp()
                swipes += 1
            }
            app.swipeUp()  // 「可點」只要按鈕中心露出來就成立，再推一次讓整顆按鈕進截圖
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "LS-382-01-iPad-\(screen == .growthDetailFood ? "populated" : "empty")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(blockHeights[0], blockHeights[1], accuracy: 0.5, "iPad 兩態區塊等高")
    }
}

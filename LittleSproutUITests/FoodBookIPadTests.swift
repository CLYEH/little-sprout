import XCTest

/// LS-379 範圍 5：飲食圖鑑 02-iPad（`oFpsV`）——Content Pane 內 4 欄格子、分頁仍 2×4 全部可見。
///
/// 只在 iPad idiom 執行（`XCTSkipUnless`，理由同 `AlbumsViewIPadTests`）；類別名以 `IPadTests` 結尾讓 CI
/// `ci-ipad`（`scripts/gates/list-ipad-tests.sh`）選得到。
@MainActor
final class FoodBookIPadTests: XCTestCase {
    func testFoodBookRegular_fourColumnGridAndTwoByFourTabs() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad 專屬版面測試，非 iPad 裝置（例如 push-gate 常態用的 iPhone 專屬機）略過"
        )
        let app = TapTargetMeasurement.launch(.foodBook)
        TapTargetMeasurement.assertScreenRendered(.foodBook, in: app)

        let ids = ["rice_cereal", "rice_porridge", "oatmeal", "white_rice", "brown_rice"]
        let cells = ids.map { app.descendants(matching: .any)["foodCell.\($0)"].firstMatch }
        for cell in cells { XCTAssertTrue(cell.waitForExistence(timeout: 5)) }
        for index in 1..<4 {
            XCTAssertEqual(cells[index].frame.minY, cells[0].frame.minY, accuracy: 1, "iPad 4 欄：前四格同一列")
        }
        XCTAssertGreaterThan(cells[4].frame.minY, cells[0].frame.maxY - 1, "第五格換列")

        let tabs = ["grain_root", "vegetable", "fruit", "protein", "dairy"].map { app.buttons["foodTab.\($0)"] }
        for index in 1..<4 {
            XCTAssertEqual(tabs[index].frame.minY, tabs[0].frame.minY, accuracy: 1, "分頁第一列四顆")
        }
        XCTAssertGreaterThan(tabs[4].frame.minY, tabs[0].frame.maxY - 1, "乳製品起第二列（2×4）")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "LS-379-02-iPad"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

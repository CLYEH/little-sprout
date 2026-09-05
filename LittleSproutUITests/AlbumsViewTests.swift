import XCTest

/// LS-165 票文驗收：「UITests（tab root 存在、空狀態→新增相簿）」。共用
/// `TapTargetGateHarness.albumsDefaultStateHost`（`.albumsDefaultState`，見
/// `TapTargetGateScreenName.swift`）——`familyStore` 帶一個測試家庭、`albumsStore` 空狀態，
/// 讓「新增相簿」sheet 能真的點開（見該 host 文件註解）。
///
/// entry-conditions.md ⑬（tab-root 首屏系統導覽列標題）已由 `SectionTabBarTests.
/// testAlbumsRootShowsAlbumsHeading` 覆蓋，這裡不重複；本檔專注在票文要求的「畫面存在」與
/// 「空狀態 → 新增相簿」互動路徑。
@MainActor
final class AlbumsViewTests: XCTestCase {
    func testTabRootShowsHeaderAndEmptyState() {
        let app = TapTargetMeasurement.launch(.albumsDefaultState)
        TapTargetMeasurement.assertScreenRendered(.albumsDefaultState, in: app)

        XCTAssertTrue(app.staticTexts["相簿"].firstMatch.exists, "Header 應該顯示「相簿」自畫標題")
        XCTAssertTrue(
            app.staticTexts["還沒有相簿"].waitForExistence(timeout: 5),
            "沒有任何相簿時應該顯示空狀態文案"
        )
    }

    func testTappingAddAlbumButtonOpensCreateAlbumSheet() {
        let app = TapTargetMeasurement.launch(.albumsDefaultState)
        TapTargetMeasurement.assertScreenRendered(.albumsDefaultState, in: app)

        app.buttons["新增相簿"].tap()

        // Sheet 的標題（純 Text，非 Button 標籤）與送出鈕——兩者同時存在才代表
        // `CreateAlbumView` 真的呈現出表單內容，不是空白 sheet（見
        // `albumsDefaultStateHost` 文件註解點名的「`familyStore.myFamily` 為 nil 時 sheet
        // 呈現空白」既有陷阱）。
        XCTAssertTrue(app.staticTexts["新增相簿"].waitForExistence(timeout: 5), "應該開啟「新增相簿」sheet")
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["建立相簿"].waitForExistence(timeout: 5))
    }

    func testCreateAlbumSheetCancelDismissesWithoutCreating() {
        let app = TapTargetMeasurement.launch(.albumsDefaultState)
        TapTargetMeasurement.assertScreenRendered(.albumsDefaultState, in: app)

        app.buttons["新增相簿"].tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()

        // sheet 關閉後應該回到空狀態（仍然還沒有相簿）。
        XCTAssertTrue(app.staticTexts["還沒有相簿"].waitForExistence(timeout: 5))
    }
}

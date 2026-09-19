import XCTest

/// LS-344 R2（merge-review R1 M1）：`AlbumsView` 曾經無條件 `.toolbar(.hidden, for:
/// .navigationBar)`，在 iPad（regular 寬度）的 `RootView.SectionSplitView` detail 欄把系統
/// nav bar 一併藏掉——detail 欄的 nav bar 正是「顯示側邊欄」鈕的容身處，使用者在相簿分頁收起
/// 側邊欄後，畫面上不存在任何可點的路徑回其他分頁（entry-conditions.md ⑬「非手勢替代路徑，
/// 不是建議」要擋的那一類；左緣右滑手勢仍可用，但不是非手勢替代路徑）。
///
/// 共用 `TapTargetGateHarness.sectionSplitViewHost`（`.sectionSplitView`，強制
/// `horizontalSizeClass = .regular`，見 `TapTargetGateScreenName.swift`）——`.sectionTabView`
/// 強制 compact，測不到這個場景；既有的 `.settingsRegular` 繞過 `AuthenticatedRootView`，
/// 也測不到（見該 host 文件註解）。
///
/// mutation（改回 `AlbumsView` 無條件 `.toolbar(.hidden, for: .navigationBar)`）：這條測試轉紅
/// （見 PR 討論／handoff 貼的失敗原文）。
///
/// 只在 iPad idiom 執行（`XCTSkipUnless`，同 `LegalDocumentSheetUITests
/// .testLegalDocumentSheet_onIPad_contentColumnWidthMatchesDesign` 既有先例）：
/// `.environment(\.horizontalSizeClass, .regular)` 只覆寫 size class，`NavigationSplitView`
/// 在實體螢幕窄（如 push-gate／CI 常態用的 iPhone 專屬機）時仍會自行收成單欄——sidebar 的
/// `List` 根本不會渲染，`app.staticTexts["相簿"]` 找不到（實測：push-gate 在
/// `LS-344-iPhone17Pro` 上跑這條紅在這一步）。`UIDevice.current.userInterfaceIdiom` 量的是
/// 執行這支測試的模擬器本身，才是判斷式的正確依據；要驗證這支測試本身，需在 iPad 模擬器上跑
/// `-only-testing:LittleSproutUITests/AlbumsIPadSidebarRegressionTests`。
@MainActor
final class AlbumsIPadSidebarRegressionTests: XCTestCase {
    func testAlbumsDetailKeepsSidebarToggleAfterHidingSidebar() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad 專屬版面測試，非 iPad 裝置（例如 push-gate 常態用的 iPhone 專屬機）略過"
        )
        let app = TapTargetMeasurement.launch(.sectionSplitView)
        TapTargetMeasurement.assertScreenRendered(.sectionSplitView, in: app)
        // sidebar 的 `List(selection:)` row 是 `Cell`（不是 `Button`），label 落在裡面的
        // `StaticText` 子節點——同 compact `SectionTabBar` 用 `Button` 語意不同，不能沿用
        // `app.buttons["相簿"]`（實測 debug tree：`Cell` 包住 `StaticText, label: '相簿'`）。
        app.staticTexts["相簿"].tap()
        XCTAssertTrue(
            app.staticTexts["還沒有相簿"].waitForExistence(timeout: 5),
            "切到相簿分頁後 detail 欄應該顯示 AlbumsView 的空狀態"
        )
        // 側邊欄展開狀態下，NavigationSplitView 系統提供的側欄開關鈕存在——不管當下 label 是
        // 「隱藏側邊欄」還是別的措辭，用 CONTAINS 找到它就點一下（收起側邊欄）。
        let sidebarToggle = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "側邊欄")).firstMatch
        XCTAssertTrue(
            sidebarToggle.waitForExistence(timeout: 5),
            "相簿分頁 detail 欄應該有系統提供的側邊欄開關鈕（不應被無條件的 .toolbar(.hidden, for:" +
            " .navigationBar) 一併藏掉）"
        )
        sidebarToggle.tap()
        let showSidebarButton = app.buttons["顯示側邊欄"]
        XCTAssertTrue(
            showSidebarButton.waitForExistence(timeout: 5),
            "收起側邊欄後，相簿分頁應該還有「顯示側邊欄」鈕可以點回去——這是收起側邊欄後，" +
            "非手勢（entry-conditions.md ⑬）能回到其他分頁的唯一路徑"
        )
    }
}

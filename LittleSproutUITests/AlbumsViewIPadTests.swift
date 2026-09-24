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
/// `-only-testing:LittleSproutUITests/AlbumsViewIPadTests`。
///
/// **LS-344 R3（merge-review R2 M1）**：類別名必須以 `IPadTests` 結尾——CI `ci-ipad` job 與 push-gate
/// 的 iPad best-effort 都用 `scripts/gates/list-ipad-tests.sh` 依名稱自動選測試，舊名
/// `AlbumsIPadSidebarRegressionTests` 選不到、iPhone job 又被上面的 `XCTSkipUnless` 略過，等於在任何
/// CI 都沒跑過。取 `AlbumsViewIPadTests`（而非別的字首）是讓 push-gate 去掉 `IPadTests` 字尾猜 SUT 時
/// 對得上 `AlbumsView.swift`，改到它就觸發本機 best-effort iPad 補跑（同 `SettingsViewIPadTests` 慣例）。
@MainActor
final class AlbumsViewIPadTests: XCTestCase {
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

    /// LS-355：LS-344 R2 只在 compact 隱藏系統 nav bar，iPad（regular）detail 欄保留 nav bar 給
    /// 側欄開關鈕，副作用是系統 large title「相簿」與 `headerRow` 自畫的「相簿」同時出現。稿面
    /// `X9PfG`（14-iPad 相簿）Content Pane 只有 Header Row 的自畫 Title，沒有系統標題——所以要鎖的是
    /// 「nav bar 裡沒有『相簿』、自畫 heading 仍在」，同時側欄開關鈕不能跟著消失（LS-344 R1 M1）。
    ///
    /// 判準沿用 `SectionTabBarTests.assertTabRootHeadingAppearsExactlyOnce`（LS-344 R3，merge-review
    /// R2 M2）：數 `app.navigationBars.staticTexts`——系統標題不論 large 或 inline 都長在 nav bar 裡，
    /// 自畫 header 與側欄 `Cell` 裡的「相簿」都不在 nav bar 裡，不需要座標過濾。
    ///
    /// 走完「切到相簿 → 收起側邊欄 → 顯示側邊欄 → 切去時間軸 → 切回相簿」後再斷言一次，鎖住側欄
    /// 切換與返回之後標題仍只出現一次（不是只有首次進場時碰巧對）。
    func testAlbumsRootShowsAlbumsTitleExactlyOnceInSplitView() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad 專屬版面測試，非 iPad 裝置（例如 push-gate 常態用的 iPhone 專屬機）略過"
        )
        let app = TapTargetMeasurement.launch(.sectionSplitView)
        TapTargetMeasurement.assertScreenRendered(.sectionSplitView, in: app)
        app.staticTexts["相簿"].tap()
        XCTAssertTrue(
            app.staticTexts["還沒有相簿"].waitForExistence(timeout: 5),
            "切到相簿分頁後 detail 欄應該顯示 AlbumsView 的空狀態"
        )
        assertAlbumsTitleAppearsExactlyOnce(in: app, context: "首次切到相簿")

        let sidebarToggle = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "側邊欄")).firstMatch
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5), "相簿分頁 detail 欄應該有系統側邊欄開關鈕")
        sidebarToggle.tap()
        let showSidebarButton = app.buttons["顯示側邊欄"]
        XCTAssertTrue(showSidebarButton.waitForExistence(timeout: 5), "收起側邊欄後應該有「顯示側邊欄」鈕")
        assertAlbumsTitleAppearsExactlyOnce(in: app, context: "收起側邊欄後")
        showSidebarButton.tap()

        app.cells.staticTexts["時間軸"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["還沒有相簿"].waitForNonExistence(timeout: 5),
            "切去時間軸後 detail 欄不應該還是相簿空狀態"
        )
        app.cells.staticTexts["相簿"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["還沒有相簿"].waitForExistence(timeout: 5), "切回相簿後應該回到空狀態")
        assertAlbumsTitleAppearsExactlyOnce(in: app, context: "切去時間軸再切回相簿")
    }

    private func assertAlbumsTitleAppearsExactlyOnce(
        in app: XCUIApplication, context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let titlePredicate = NSPredicate(format: "label == %@", "相簿")
        let navBarTitleCount = app.navigationBars.staticTexts.matching(titlePredicate).count
        // 畫面上所有「相簿」StaticText 扣掉側欄 `Cell` 內那顆（sidebar row，見上一支測試的註解）與
        // nav bar 內的，剩下的就是 detail 欄頁內自畫的 heading——必須恰好一顆，否則代表修法把
        // 自畫標題也一起拿掉了（稿面要的是自畫那顆，不是系統那顆）。
        let inPageTitleCount = app.staticTexts.matching(titlePredicate).count
            - app.cells.staticTexts.matching(titlePredicate).count - navBarTitleCount
        XCTAssertEqual(
            inPageTitleCount, 1,
            "［\(context)］detail 欄應該恰好有一顆 headerRow 自畫的「相簿」（稿面 X9PfG Header Row Title）",
            file: file, line: line
        )
        XCTAssertEqual(
            navBarTitleCount, 0,
            "［\(context)］系統 nav bar 裡不應該有「相簿」——iPad 相簿根頁的標題只該是 headerRow 自畫的那一顆" +
            "（稿面 X9PfG Header Row Title），系統 large／inline title 不得同時可見（LS-355）",
            file: file, line: line
        )
    }
}

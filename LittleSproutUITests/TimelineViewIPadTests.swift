import XCTest

/// LS-369：`TimelineView` 曾經無條件 `.toolbar(.hidden, for: .navigationBar)`——在 iPad（regular
/// 寬度）的 `RootView.SectionSplitView` detail 欄把系統 nav bar 一併藏掉，而 detail 欄的 nav bar
/// 正是「顯示側邊欄」鈕的容身處：使用者在時間軸分頁收起側邊欄後，畫面上沒有任何可點的路徑回其他
/// 分頁，只剩左緣右滑手勢（entry-conditions.md ⑬「非手勢替代路徑」；與 LS-344 R1 M1 的相簿頁同型，
/// LS-355 盤點發現）。
///
/// 修法比照 `AlbumsView`（LS-355）：regular 保留 nav bar，用 `.inline`＋零尺寸 `.principal` 關掉系統
/// 標題——稿面 `go7f9`（LS-21 / 11-iPad 時間軸）Content Pane 只有 Header Row 的自畫 Title
/// （`D67gr`「時間軸」），沒有系統標題。所以這裡同時鎖兩件事：側欄開關鈕在、而且標題只出現一次
/// （nav bar 內 0、頁內自畫 1）——只修前者會把 LS-344 R2 的雙標題帶回時間軸。
///
/// 共用 `TapTargetGateHarness.sectionSplitViewHost`（`.sectionSplitView`，強制
/// `horizontalSizeClass = .regular`，走生產路徑 `AuthenticatedRootView` → `SectionSplitView`），
/// 首頁即時間軸（`AppSection` 預設選取）；preview 時間軸 API 回空陣列，detail 欄是空狀態。
///
/// 只在 iPad idiom 執行（`XCTSkipUnless`，理由同 `AlbumsViewIPadTests`：iPhone 實體螢幕窄時
/// `NavigationSplitView` 會收成單欄，sidebar 不渲染）；類別名以 `IPadTests` 結尾，讓 CI `ci-ipad`
/// （`scripts/gates/list-ipad-tests.sh`）選得到，去掉字尾對得上 `TimelineView.swift`。
@MainActor
final class TimelineViewIPadTests: XCTestCase {
    private static let emptyStateTitle = "這裡還沒有任何回憶"

    func testTimelineKeepsShowSidebarButtonAfterHidingSidebar() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad 專屬版面測試，非 iPad 裝置（例如 push-gate 常態用的 iPhone 專屬機）略過"
        )
        let app = launchOnTimeline()
        collapseSidebar(in: app)

        let showSidebarButton = app.buttons["顯示側邊欄"]
        XCTAssertTrue(
            showSidebarButton.waitForHittable(timeout: 5),
            "收起側邊欄後，時間軸分頁應該還有可點的「顯示側邊欄」鈕——這是收起側邊欄後，非手勢" +
            "（entry-conditions.md ⑬）能回到其他分頁的唯一路徑（LS-369）"
        )
        showSidebarButton.tap()
        XCTAssertTrue(
            app.cells.staticTexts["相簿"].firstMatch.waitForHittable(timeout: 5),
            "點「顯示側邊欄」後側欄應該回來，其他分頁的導覽列（例如「相簿」）要可點"
        )
    }

    /// 三個時點各斷言一次：首次進入、收起側邊欄後、切去相簿再切回時間軸——鎖住側欄切換與來回
    /// 切換分頁之後標題仍只出現一次（不是只有首次進場碰巧對）。判準沿用
    /// `AlbumsViewIPadTests.assertAlbumsTitleAppearsExactlyOnce`：系統標題不論 large 或 inline 都長在
    /// nav bar 裡，自畫 header 與側欄 `Cell` 裡的「時間軸」都不在 nav bar 裡。
    func testTimelineRootShowsTimelineTitleExactlyOnceInSplitView() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad 專屬版面測試，非 iPad 裝置（例如 push-gate 常態用的 iPhone 專屬機）略過"
        )
        let app = launchOnTimeline()
        assertTimelineTitleAppearsExactlyOnce(in: app, context: "首次進入")

        collapseSidebar(in: app)
        let showSidebarButton = app.buttons["顯示側邊欄"]
        XCTAssertTrue(showSidebarButton.waitForHittable(timeout: 5), "收起側邊欄後應該有可點的「顯示側邊欄」鈕")
        assertTimelineTitleAppearsExactlyOnce(in: app, context: "收起側邊欄後")
        showSidebarButton.tap()

        app.cells.staticTexts["相簿"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["還沒有相簿"].waitForExistence(timeout: 5), "切去相簿後 detail 欄應該是相簿空狀態")
        app.cells.staticTexts["時間軸"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts[Self.emptyStateTitle].waitForExistence(timeout: 5),
            "切回時間軸後 detail 欄應該回到時間軸空狀態"
        )
        assertTimelineTitleAppearsExactlyOnce(in: app, context: "切去相簿再切回時間軸")
    }

    private func launchOnTimeline(file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = TapTargetMeasurement.launch(.sectionSplitView)
        TapTargetMeasurement.assertScreenRendered(.sectionSplitView, in: app)
        XCTAssertTrue(
            app.staticTexts[Self.emptyStateTitle].waitForExistence(timeout: 5),
            "iPad 首頁 detail 欄應該是時間軸空狀態（preview 時間軸 API 回空陣列）",
            file: file, line: line
        )
        return app
    }

    /// 側邊欄展開時，`NavigationSplitView` 系統提供的側欄開關鈕在 detail 欄 nav bar 上——label 措辭
    /// 不綁死，用 CONTAINS「側邊欄」找到就點（同 `AlbumsViewIPadTests`）。
    private func collapseSidebar(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let sidebarToggle = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "側邊欄")).firstMatch
        XCTAssertTrue(
            sidebarToggle.waitForHittable(timeout: 5),
            "時間軸分頁 detail 欄應該有系統提供的側邊欄開關鈕（不應被無條件的 .toolbar(.hidden, for:" +
            " .navigationBar) 一併藏掉，LS-369）",
            file: file, line: line
        )
        sidebarToggle.tap()
    }

    private func assertTimelineTitleAppearsExactlyOnce(
        in app: XCUIApplication, context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let titlePredicate = NSPredicate(format: "label == %@", "時間軸")
        let navBarTitleCount = app.navigationBars.staticTexts.matching(titlePredicate).count
        // 畫面上所有「時間軸」StaticText 扣掉側欄 `Cell` 內那顆與 nav bar 內的，剩下的就是 detail 欄
        // 頁內自畫的 heading——必須恰好一顆，否則代表修法把自畫標題也一起拿掉了。
        let inPageTitleCount = app.staticTexts.matching(titlePredicate).count
            - app.cells.staticTexts.matching(titlePredicate).count - navBarTitleCount
        XCTAssertEqual(
            inPageTitleCount, 1,
            "［\(context)］detail 欄應該恰好有一顆 headerRow 自畫的「時間軸」（稿面 go7f9 Header Row Title D67gr）",
            file: file, line: line
        )
        XCTAssertEqual(
            navBarTitleCount, 0,
            "［\(context)］系統 nav bar 裡不應該有「時間軸」——iPad 時間軸根頁的標題只該是 headerRow 自畫的那一顆" +
            "（稿面 go7f9 Header Row Title D67gr），系統 large／inline title 不得同時可見（LS-369）",
            file: file, line: line
        )
    }
}

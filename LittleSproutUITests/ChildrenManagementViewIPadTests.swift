import XCTest

/// LS-370：iPad Pro 13 寶貝分頁「寶貝」出現三次——`ChildrenManagementView.regularLayout` 原本在
/// `RootView.SectionSplitView` 的 detail 欄（自帶 `NavigationStack`）裡再包一層 `NavigationSplitView`：
/// 外層系統 large title、內層側欄 `.navigationTitle("寶貝")`、`headerSection` 自畫各一顆（iPad Air 11
/// 看似一顆是因為內層側欄收起）。稿面 `JbTfv`（09-iPad）是單一 split：左 Sidebar 自畫 Title「寶貝」＋
/// 寶貝清單＋新增鈕、右 Detail Pane，沒有系統標題。
///
/// 修法：拿掉內層 split，左右兩欄改在外層 detail 欄內用 `HStack` 畫；nav bar 保留（外層「顯示側邊欄」
/// 鈕的容身處，LS-344 R1 M1），`.inline`＋零尺寸 principal 關掉系統標題（同 LS-355／LS-369）。所以這裡
/// 同時鎖三件事：標題只出現一次（nav bar 內 0、頁內自畫 1）、外層側欄收起後仍有開關鈕能走回、左欄點寶貝
/// 後右欄顯示詳情（拿掉內層 split 後左欄改 `Button` 列寫 `selectedChildID`，仍要能驅動右欄）。
///
/// 共用 `TapTargetGateHarness.sectionSplitViewWithChildrenHost`（`.sectionSplitViewWithChildren`：強制
/// regular、走生產路徑 `AuthenticatedRootView` → `SectionSplitView`，seed 兩個寶貝）。
///
/// mutation（`regularLayout` 改回內層 `NavigationSplitView`＋`sidebarContent.navigationTitle("寶貝")`）：
/// 標題測試轉紅，失敗原文見 LS-370 handoff。
///
/// 只在 iPad idiom 執行（`XCTSkipUnless`，理由同 `AlbumsViewIPadTests`）；類別名以 `IPadTests` 結尾讓
/// CI `ci-ipad`（`scripts/gates/list-ipad-tests.sh`）選得到，去掉字尾對得上 `ChildrenManagementView.swift`。
@MainActor
final class ChildrenManagementViewIPadTests: XCTestCase {
    private static let childName = "陳小安"
    private static let placeholderTitle = "選擇一個寶貝"

    /// 四個時點各斷言一次：首次切到寶貝、點選寶貝後（右欄詳情有自己的 `.navigationTitle("")`）、收起
    /// 側邊欄後、切去相簿再切回寶貝——鎖住不是只有首次進場碰巧對。
    func testChildrenRootShowsChildrenTitleExactlyOnceInSplitView() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad 專屬版面測試，非 iPad 裝置（例如 push-gate 常態用的 iPhone 專屬機）略過"
        )
        let app = launchOnChildren()
        assertChildrenTitleAppearsExactlyOnce(in: app, context: "首次切到寶貝")

        app.staticTexts[Self.childName].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts[Self.placeholderTitle].waitForNonExistence(timeout: 5),
            "點選寶貝後右欄不應該還是「選擇一個寶貝」佔位"
        )
        assertChildrenTitleAppearsExactlyOnce(in: app, context: "點選寶貝後")

        collapseSidebar(in: app)
        let showSidebarButton = app.buttons["顯示側邊欄"]
        XCTAssertTrue(showSidebarButton.waitForHittable(timeout: 5), "收起側邊欄後應該有可點的「顯示側邊欄」鈕")
        assertChildrenTitleAppearsExactlyOnce(in: app, context: "收起側邊欄後")
        showSidebarButton.tap()

        app.cells.staticTexts["相簿"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["還沒有相簿"].waitForExistence(timeout: 5), "切去相簿後 detail 欄應該是相簿空狀態")
        app.cells.staticTexts["寶貝"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts[Self.childName].firstMatch.waitForExistence(timeout: 5),
            "切回寶貝後左欄應該回到寶貝清單"
        )
        assertChildrenTitleAppearsExactlyOnce(in: app, context: "切去相簿再切回寶貝")
    }

    func testChildrenKeepsShowSidebarButtonAfterHidingSidebar() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad 專屬版面測試，非 iPad 裝置（例如 push-gate 常態用的 iPhone 專屬機）略過"
        )
        let app = launchOnChildren()
        collapseSidebar(in: app)

        let showSidebarButton = app.buttons["顯示側邊欄"]
        XCTAssertTrue(
            showSidebarButton.waitForHittable(timeout: 5),
            "收起側邊欄後，寶貝分頁應該還有可點的「顯示側邊欄」鈕——這是收起側邊欄後，非手勢" +
            "（entry-conditions.md ⑬）能回到其他分頁的唯一路徑（LS-344 R1 M1，LS-370 不得無條件隱藏 nav bar）"
        )
        showSidebarButton.tap()
        XCTAssertTrue(
            app.cells.staticTexts["相簿"].firstMatch.waitForHittable(timeout: 5),
            "點「顯示側邊欄」後側欄應該回來，其他分頁的導覽列（例如「相簿」）要可點"
        )
    }

    /// 拿掉內層 `NavigationSplitView` 後，左欄改 `Button` 列（`ChildrenManagementView+Regular.swift`）——鎖住點選寶貝列
    /// 仍會驅動右欄顯示該寶貝詳情（`ChildGrowthDetailView` 06 版的「最新紀錄」區塊；preview 成長 API 回空，
    /// 「查看全部紀錄」只在有紀錄時出現，不能拿來當判準），而不是停在佔位。
    func testSelectingChildShowsDetailInRightColumn() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad 專屬版面測試，非 iPad 裝置（例如 push-gate 常態用的 iPhone 專屬機）略過"
        )
        let app = launchOnChildren()
        XCTAssertTrue(
            app.staticTexts[Self.placeholderTitle].waitForExistence(timeout: 5),
            "尚未選取寶貝時右欄應該是「選擇一個寶貝」佔位"
        )
        app.staticTexts[Self.childName].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["最新紀錄"].waitForExistence(timeout: 5),
            "點選左欄寶貝後，右欄應該顯示該寶貝的詳情（ChildGrowthDetailView 06「最新紀錄」）"
        )
        XCTAssertTrue(
            app.staticTexts[Self.childName].firstMatch.isHittable,
            "右欄顯示詳情時左欄寶貝清單應該仍在（稿面 JbTfv 兩欄並列，不是 push 蓋掉）"
        )
    }

    private func launchOnChildren(file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = TapTargetMeasurement.launch(.sectionSplitViewWithChildren)
        TapTargetMeasurement.assertScreenRendered(.sectionSplitViewWithChildren, in: app)
        // 外層 sidebar 的 `List(selection:)` row 是 `Cell`，label 落在裡面的 `StaticText`（同 `AlbumsViewIPadTests`）。
        app.cells.staticTexts["寶貝"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts[Self.childName].firstMatch.waitForExistence(timeout: 5),
            "切到寶貝分頁後左欄應該列出 seed 的寶貝「\(Self.childName)」",
            file: file, line: line
        )
        return app
    }

    /// 側邊欄展開時，`NavigationSplitView` 系統提供的側欄開關鈕在 detail 欄 nav bar 上——label 措辭
    /// 不綁死，用 CONTAINS「側邊欄」找到就點（同 `TimelineViewIPadTests`）。
    private func collapseSidebar(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let sidebarToggle = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "側邊欄")).firstMatch
        XCTAssertTrue(
            sidebarToggle.waitForHittable(timeout: 5),
            "寶貝分頁 detail 欄應該有系統提供的側邊欄開關鈕（不應被無條件的 .toolbar(.hidden, for:" +
            " .navigationBar) 一併藏掉）",
            file: file, line: line
        )
        sidebarToggle.tap()
    }

    /// 判準沿用 `AlbumsViewIPadTests.assertAlbumsTitleAppearsExactlyOnce`：系統標題不論 large 或 inline、
    /// 外層或內層 split 的 nav bar，都長在 `navigationBars` 裡；自畫 header 與外層側欄 `Cell` 裡的「寶貝」
    /// 都不在 nav bar 裡。
    private func assertChildrenTitleAppearsExactlyOnce(
        in app: XCUIApplication, context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let titlePredicate = NSPredicate(format: "label == %@", "寶貝")
        let navBarTitleCount = app.navigationBars.staticTexts.matching(titlePredicate).count
        let inPageTitleCount = app.staticTexts.matching(titlePredicate).count
            - app.cells.staticTexts.matching(titlePredicate).count - navBarTitleCount
        XCTAssertEqual(
            inPageTitleCount, 1,
            "［\(context)］左欄應該恰好有一顆 headerSection 自畫的「寶貝」（稿面 JbTfv Sidebar Top Title o2kCZ）",
            file: file, line: line
        )
        XCTAssertEqual(
            navBarTitleCount, 0,
            "［\(context)］系統 nav bar 裡不應該有「寶貝」——iPad 寶貝根頁的標題只該是左欄自畫的那一顆" +
            "（稿面 JbTfv），外層系統標題與內層 split 側欄標題都不得可見（LS-370）",
            file: file, line: line
        )
    }
}

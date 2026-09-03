import XCTest

/// LS-136：`cmp/Tab Bar` 全字級純 icon 的兩組行為驗證，共用 `.sectionTabView` harness
/// （`TapTargetGateHarness.sectionTabViewHost`，`AuthenticatedRootView` compact，見
/// `TapTargetGateScreenName.swift`）。
///
/// ①VoiceOver：每顆 cell 的 accessibility label／`.isSelected` trait 隨點擊正確切換
/// ——這個專案沒有 ViewInspector／snapshot 工具能在 XCTest（無模擬器）層級檢視 SwiftUI
/// modifier，`XCUIElement.isSelected` 是唯一能量到 `.accessibilityAddTraits(.isSelected)`
/// 真實效果的路徑，比照既有 `TapTargetGateTests` 一樣掛在 UI test target。
///
/// ②entry-conditions.md ⑬：四個 tab-root 目的地畫面首屏，display 標題逐字等於該 tab
/// 的可見名稱（拿掉可見 tab 文字後的非手勢替代路徑，不是建議）。
///
/// merge-review R1 m1/m2 修法：相簿／寶貝／設定三個畫面都有可見的系統 nav bar，斷言改成
/// `app.navigationBars[name]`——只有畫面上「真的存在一顆這個標題的系統導覽列」才會通過，
/// 不會被畫面上任何其他同名 staticText（`ContentUnavailableView` 的 label、
/// `ChildrenManagementView` 自己的 `.navigationTitle`）巧合撐過。時間軸隱藏系統 nav bar
/// （`.toolbar(.hidden, for: .navigationBar)`），headerRow 自畫的 Text 是這個畫面**唯一**
/// 的 heading 訊號來源——XCUITest 沒有能獨立查詢 `.isHeader` accessibility trait 的 API
/// （實測：`.accessibilityAddTraits(.isHeader)` 不會把 `elementType` 從 `.staticText` 提升
/// 成獨立型別，不像 `.isSelected` 有專屬的 `XCUIElement.isSelected` 屬性可查），因此改加一條
/// 「這顆文字位在畫面最上緣 header 區」的位置斷言，跟 sentinel 的純文字存在斷言不是同一件事
/// （sentinel 若因為畫面上其他地方多了一顆同名文字而误判存在，這裡的位置斷言會抓到）。
@MainActor
final class SectionTabBarTests: XCTestCase {
    private let tabNames = ["時間軸", "相簿", "寶貝", "設定"]

    // MARK: - VoiceOver label／selected trait

    func testEveryTabHasAccessibilityLabelMatchingItsName() {
        let app = TapTargetMeasurement.launch(.sectionTabView)
        TapTargetMeasurement.assertScreenRendered(.sectionTabView, in: app)
        for name in tabNames {
            XCTAssertTrue(
                app.buttons[name].waitForExistence(timeout: 5),
                "Tab Bar 應該有一顆 accessibilityLabel 等於「\(name)」的 button（cell 層級，非 icon 葉節點）"
            )
        }
    }

    /// 預設選中分頁＝時間軸——只有它的 cell 帶 `.isSelected` trait，其餘三顆不帶。
    func testDefaultSelectionIsTimelineOnly() {
        let app = TapTargetMeasurement.launch(.sectionTabView)
        TapTargetMeasurement.assertScreenRendered(.sectionTabView, in: app)
        XCTAssertTrue(app.buttons["時間軸"].isSelected, "預設應選中時間軸")
        for name in ["相簿", "寶貝", "設定"] {
            XCTAssertFalse(app.buttons[name].isSelected, "「\(name)」預設不應是選中狀態")
        }
    }

    /// 點擊「相簿」後，selected trait 隨之轉移——不是視覺換色但 a11y 沒跟上的漏網型
    /// （同構於 LS-120 merge-review MN-2 抓到的 demo 對照板 selected 中繼資料落差）。
    func testTappingATabMovesTheSelectedTraitToIt() {
        let app = TapTargetMeasurement.launch(.sectionTabView)
        TapTargetMeasurement.assertScreenRendered(.sectionTabView, in: app)
        app.buttons["相簿"].tap()
        XCTAssertTrue(app.buttons["相簿"].isSelected, "點擊後「相簿」應變成選中狀態")
        XCTAssertFalse(app.buttons["時間軸"].isSelected, "點擊「相簿」後「時間軸」應變回未選中")
    }

    // MARK: - entry-conditions.md ⑬：tab-root 首屏標題

    /// 時間軸是預設分頁，不需要點擊即可驗證。見上方型別文件註解「merge-review R1 m1/m2 修法」
    /// ——位置斷言（畫面最上緣）是跟 sentinel 不同義反覆的額外訊號。
    func testTimelineRootShowsTimelineHeading() {
        let app = TapTargetMeasurement.launch(.sectionTabView)
        TapTargetMeasurement.assertScreenRendered(.sectionTabView, in: app)
        let heading = app.staticTexts["時間軸"].firstMatch
        XCTAssertTrue(heading.exists, "headerRow 的「時間軸」heading 應該存在")
        XCTAssertLessThan(
            heading.frame.minY, 100,
            "「時間軸」heading 應該出現在畫面最上緣的 header 區（不是巧合出現在畫面其他位置的同名文字）"
        )
    }

    func testAlbumsRootShowsAlbumsHeading() {
        assertTabRootShowsNavigationBarHeading(tabLabel: "相簿", expectedHeading: "相簿")
    }

    func testChildrenRootShowsChildrenHeading() {
        assertTabRootShowsNavigationBarHeading(tabLabel: "寶貝", expectedHeading: "寶貝")
    }

    func testSettingsRootShowsSettingsHeading() {
        assertTabRootShowsNavigationBarHeading(tabLabel: "設定", expectedHeading: "設定")
    }

    /// 斷言系統 nav bar 本身（`app.navigationBars[expectedHeading]`）存在、且它底下真的有一顆
    /// 等於 `expectedHeading` 的 staticText——只有「畫面上有一顆系統導覽列標題＝這個字串」才會
    /// 通過，跟 `ContentUnavailableView` 的 label 或畫面自己另外畫的同名文字無關，兩者可以各自
    /// 獨立變動而不影響這條斷言。
    private func assertTabRootShowsNavigationBarHeading(
        tabLabel: String, expectedHeading: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let app = TapTargetMeasurement.launch(.sectionTabView)
        TapTargetMeasurement.assertScreenRendered(.sectionTabView, in: app)
        app.buttons[tabLabel].tap()
        let navBarTitle = app.navigationBars[expectedHeading].staticTexts[expectedHeading]
        XCTAssertTrue(
            navBarTitle.waitForExistence(timeout: 5),
            "點擊「\(tabLabel)」後，系統導覽列標題應該逐字等於「\(expectedHeading)」" +
            "（entry-conditions.md ⑬：拿掉可見 tab 文字後的非手勢替代路徑）",
            file: file, line: line
        )
    }
}

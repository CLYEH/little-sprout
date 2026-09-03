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

    /// 時間軸是預設分頁，不需要點擊即可驗證。
    func testTimelineRootShowsTimelineHeading() {
        let app = TapTargetMeasurement.launch(.sectionTabView)
        TapTargetMeasurement.assertScreenRendered(.sectionTabView, in: app)
        XCTAssertTrue(app.staticTexts["時間軸"].firstMatch.exists)
    }

    func testAlbumsRootShowsAlbumsHeading() {
        assertTabRootShowsHeading(tabLabel: "相簿", expectedHeading: "相簿")
    }

    func testChildrenRootShowsChildrenHeading() {
        assertTabRootShowsHeading(tabLabel: "寶貝", expectedHeading: "寶貝")
    }

    func testSettingsRootShowsSettingsHeading() {
        assertTabRootShowsHeading(tabLabel: "設定", expectedHeading: "設定")
    }

    private func assertTabRootShowsHeading(
        tabLabel: String, expectedHeading: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let app = TapTargetMeasurement.launch(.sectionTabView)
        TapTargetMeasurement.assertScreenRendered(.sectionTabView, in: app)
        app.buttons[tabLabel].tap()
        XCTAssertTrue(
            app.staticTexts[expectedHeading].firstMatch.waitForExistence(timeout: 5),
            "點擊「\(tabLabel)」後，目的地畫面首屏應該存在文字等於「\(expectedHeading)」的標題" +
            "（entry-conditions.md ⑬：拿掉可見 tab 文字後的非手勢替代路徑）",
            file: file, line: line
        )
    }
}

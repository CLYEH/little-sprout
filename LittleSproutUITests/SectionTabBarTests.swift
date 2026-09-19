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
/// LS-344 訂正 merge-review R1 m1/m2 的舊寫法：舊版斷言相簿／寶貝／設定三個畫面「應該有」
/// 可見的系統 nav bar（`app.navigationBars[name]`）——**這個斷言本身就是 bug**：它把「系統
/// large title 與畫面自畫的 header 同時存在」錯當成正確行為，實機 iPhone 12 Pro／iOS 26.5.2
/// 與模擬器 iOS 26.5 都能重現這三頁標題重複顯示（LS-344 票面截圖）。現在四個 tab-root 統一
/// 隱藏系統 nav bar（`.toolbar(.hidden, for: .navigationBar)`，同 `TimelineView` 原本的既有
/// 寫法），各自 headerRow／header／headerSection 自畫的 Text 是畫面**唯一**的 heading 訊號
/// 來源（都補了 `.accessibilityAddTraits(.isHeader)`）。XCUITest 沒有能獨立查詢 `.isHeader`
/// accessibility trait 的 API（實測：`.accessibilityAddTraits(.isHeader)` 不會把
/// `elementType` 從 `.staticText` 提升成獨立型別，不像 `.isSelected` 有專屬的
/// `XCUIElement.isSelected` 屬性可查），所以斷言分兩層：①「這顆文字位在畫面最上緣 header 區」
/// 的位置斷言（沿用既有手法，跟 sentinel 的純文字存在斷言不是同一件事）②「這個字串在畫面上
/// 只出現一次」的計數斷言——①單獨並不會在「系統 nav bar 重新冒出來」時轉紅（自畫 header 那顆
/// 文字位置沒變，只是多了一顆在別處），必須靠②才抓得到「拿掉修法＝系統 nav bar 沒被隱藏」這個
/// mutation（LS-344 票文範圍 3：機械斷言＋mutation 紅→綠）。
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
        let albumsTab = app.buttons["相簿"]
        let timelineTab = app.buttons["時間軸"]
        albumsTab.tap()
        // LS-229（同 LS-230 決定性同步點修法）：`isSelected` 由點擊後的分頁切換狀態更新驅動，
        // tap 後立即查詢是一次性快照，CI runner 負載高時會誤判失敗。改用
        // `XCTNSPredicateExpectation` 正向等它變成 true。
        let albumsSelectedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"), object: albumsTab
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [albumsSelectedExpectation], timeout: 5), .completed,
            "點擊後「相簿」應變成選中狀態"
        )
        XCTAssertFalse(timelineTab.isSelected, "點擊「相簿」後「時間軸」應變回未選中")
    }

    // MARK: - entry-conditions.md ⑬／LS-344：tab-root 首屏標題唯一存在

    /// 時間軸是預設分頁，不需要點擊即可驗證。
    func testTimelineRootShowsTimelineHeadingExactlyOnce() {
        assertTabRootHeadingAppearsExactlyOnce(tabLabel: nil, expectedHeading: "時間軸")
    }

    func testAlbumsRootShowsAlbumsHeadingExactlyOnce() {
        assertTabRootHeadingAppearsExactlyOnce(tabLabel: "相簿", expectedHeading: "相簿")
    }

    func testChildrenRootShowsChildrenHeadingExactlyOnce() {
        assertTabRootHeadingAppearsExactlyOnce(tabLabel: "寶貝", expectedHeading: "寶貝")
    }

    func testSettingsRootShowsSettingsHeadingExactlyOnce() {
        assertTabRootHeadingAppearsExactlyOnce(tabLabel: "設定", expectedHeading: "設定")
    }

    /// LS-344：相簿／寶貝／設定三個 tab 根頁曾經系統 nav bar large title 與自畫 header 同時
    /// 存在（票面實機截圖；模擬器 iOS 26.5 可重現，見 handoff）。斷言分兩層（見上方型別文件
    /// 註解）：①至少存在一顆在畫面最上緣 header 區的同名文字（entry-conditions.md ⑬ 的非手勢
    /// 替代路徑）②「畫面最上緣 header 區」內這個字串只出現一次——`tabLabel` 為 nil 時（時間軸，
    /// 預設分頁）不需要點擊。
    ///
    /// **LS-344 R2（merge-review R1 i1）**：②原本掃整個畫面（`app.staticTexts.matching(label
    /// ==)`.count），日後若畫面內容剛好含跟 tab 名同字串（例如使用者把相簿取名「相簿」）會
    /// 誤紅——跟①一樣把比對範圍限定在 `frame.minY < 100` 的最上緣 header 區，語意也更貼近
    /// 「標題區只有一顆」而非「整個畫面只有一顆」。`XCUIElementQuery` 的 predicate 無法直接
    /// 對 `frame`（需要即時 snapshot，不是 accessibility 靜態屬性）過濾，先用 `label ==`
    /// 縮小候選、再用 `allElementsBoundByIndex` 逐一讀 `frame` 在 Swift 端篩選。
    private func assertTabRootHeadingAppearsExactlyOnce(
        tabLabel: String?, expectedHeading: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let app = TapTargetMeasurement.launch(.sectionTabView)
        TapTargetMeasurement.assertScreenRendered(.sectionTabView, in: app)
        if let tabLabel {
            app.buttons[tabLabel].tap()
        }
        let heading = app.staticTexts[expectedHeading].firstMatch
        XCTAssertTrue(
            heading.waitForExistence(timeout: 5), "「\(expectedHeading)」heading 應該存在", file: file, line: line
        )
        XCTAssertLessThan(
            heading.frame.minY, 100,
            "「\(expectedHeading)」heading 應該出現在畫面最上緣的 header 區（不是巧合出現在畫面其他位置的同名文字）",
            file: file, line: line
        )
        let candidates = app.staticTexts.matching(NSPredicate(format: "label == %@", expectedHeading))
            .allElementsBoundByIndex
        let headerAreaMatches = candidates.filter { $0.frame.minY < 100 }
        XCTAssertEqual(
            headerAreaMatches.count, 1,
            "「\(expectedHeading)」標題在畫面最上緣 header 區（minY < 100）應該只出現一次——系統 nav bar" +
            " large title 與自畫 header 不得同時可見（LS-344：實機 iPhone 12 Pro／iOS 26.5.2 回報相簿／" +
            "寶貝／設定三頁重複顯示）",
            file: file, line: line
        )
    }
}

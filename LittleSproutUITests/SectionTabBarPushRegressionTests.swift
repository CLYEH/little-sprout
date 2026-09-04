import XCTest

/// merge-review R1 M1：`SectionTabBar` 的 `.safeAreaInset(edge: .bottom)` 曾經掛在 `TabView`
/// 那一層（`RootView.swift` 舊版），是所有分頁（含 push 進去的 `DiaryEditorView`／
/// `DiaryDetailView`）共同的祖先，膠囊因此在 push 之後仍留在畫面上，跟這兩個畫面自己的
/// `.toolbar(.hidden, for: .tabBar)`（LS-125／LS-126 QA 對稿 FAIL 修法）疊出兩條底部帶，
/// 也與核可稿 12／13 板（編輯器／詳情，稿面沒有 Tab Bar 節點）不符。
///
/// R2 修法：`.safeAreaInset` 改掛在每個分頁 `NavigationStack` 的根內容（`SectionContentView`）
/// 上，push 之後根內容被覆蓋、膠囊自然消失。這兩條測試鎖住這個行為——拿掉
/// `RootView.swift` 那個 `.safeAreaInset` 改回掛在 `TabView`，兩條都會紅（見 PR body
/// mutation 表）。
///
/// 判準刻意不用 tab 名稱字串（`app.buttons["時間軸"]`）：詳情頁的系統返回鈕會自動沿用
/// 上一頁 `.navigationTitle` 當標籤（實測 `identifier: "BackButton", label: "時間軸"`），
/// 跟 Tab Bar 的「時間軸」cell 撞名——用字串比對會把返回鈕誤判成殘留的 Tab Bar，兩種情況
/// 都回報「時間軸 button 存在」，測不出真正的差異。改用 `SectionTabBar` 每顆 cell 自己的
/// SF Symbol accessibility identifier比對，不會跟任何系統 chrome 撞名。
///
/// LS-160：比對字串原本是硬編碼的四個字面值，跟 `AppSection.systemImage` 各自維護會漂移
/// （LS-150 review R1 I1——當時 `.children` 換成 `stroller.fill`，這裡得手動同步，否則
/// sentinel 永遠找不到 children cell、測試會一路假紅）。改直接引用 `AppSection.allCases`
/// 的 `systemImage`（`AppSection.swift` 已比照 `TapTargetGateScreenName.swift` 的既有慣例
/// 掛進 UITests target sources，見 `project.yml`），源頭改了這裡自動跟著改。
@MainActor
final class SectionTabBarPushRegressionTests: XCTestCase {
    private let tabIconIdentifiers = AppSection.allCases.map(\.systemImage)

    func testTabBarNotPresentAfterPushingIntoDiaryEditor() {
        let app = TapTargetMeasurement.launch(.sectionTabView)
        TapTargetMeasurement.assertScreenRendered(.sectionTabView, in: app)
        assertTabBarPresent(in: app, message: "push 前 Tab Bar 應該存在（sentinel 沒生效就測不出後面的差異）")
        app.buttons["新增回憶"].tap()
        XCTAssertTrue(
            app.staticTexts["寫日記"].waitForExistence(timeout: 5),
            "點「新增回憶」後應該已經 push 進 DiaryEditorView（sentinel「寫日記」標題）"
        )
        assertTabBarAbsent(
            in: app,
            message: "push 進日記編輯器後 Tab Bar 不應該還在——編輯器稿面（12 板）沒有 Tab Bar 節點，" +
            "膠囊留在畫面上會跟編輯器自己的釘底 Action Bar 疊成兩條底部帶"
        )
        // Action Bar（「發佈日記」）本身必須還在、且沒有被膠囊的 safeAreaInset 頂高——用它
        // 存在且可點確認畫面沒有因為這次修法連 Action Bar 自己都壞掉。
        XCTAssertTrue(app.buttons["發佈日記"].exists, "Action Bar 的「發佈日記」鈕應該仍然存在")
    }

    func testTabBarNotPresentAfterPushingIntoDiaryDetail() {
        let app = TapTargetMeasurement.launch(.sectionTabViewWithDiary)
        TapTargetMeasurement.assertScreenRendered(.sectionTabViewWithDiary, in: app)
        assertTabBarPresent(in: app, message: "push 前 Tab Bar 應該存在（sentinel 沒生效就測不出後面的差異）")
        // 卡片被 `.buttonStyle(.plain)` 的 `NavigationLink` 包住，整張卡合併成一顆
        // accessibilityLabel＝日記本文的 button（實測），不是獨立的 staticText。
        app.buttons["LS-136 R2 回歸測試日記"].tap()
        XCTAssertTrue(
            app.staticTexts["LS-136 R2 回歸測試日記"].waitForExistence(timeout: 5),
            "點日記卡後應該已經 push 進 DiaryDetailView（本文仍看得到，只是換到詳情頁的排版）"
        )
        assertTabBarAbsent(
            in: app,
            message: "push 進日記詳情後 Tab Bar 不應該還在——詳情稿面（13 板 `vzYXz`）沒有 Tab Bar 節點"
        )
    }

    private func assertTabBarPresent(
        in app: XCUIApplication, message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        for identifier in tabIconIdentifiers {
            let exists = app.buttons.matching(identifier: identifier).firstMatch.exists
            XCTAssertTrue(exists, message, file: file, line: line)
        }
    }

    private func assertTabBarAbsent(
        in app: XCUIApplication, message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        for identifier in tabIconIdentifiers {
            let exists = app.buttons.matching(identifier: identifier).firstMatch.exists
            XCTAssertFalse(exists, message, file: file, line: line)
        }
    }
}

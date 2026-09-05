import XCTest

/// merge-review R1 B1（blocker）：iPad（regular 寬度）互動回歸——原本的內層
/// `NavigationSplitView` 疊在外層 `NavigationStack` 裡，讓 `SettingsView` 子樹在 iPad 上全部
/// 按不動（含 base 上原本可用的「邀請家人」）。reviewer 實測是靜態截圖看起來全對、互動全壞
/// ——這裡逐區驗證「至少一個入口能 push、能返回」，全部用真的 `tap()` 操作，不是截圖比對。
///
/// 共用 `TapTargetGateHarness.settingsRegularHost`（`.settingsRegular`，強制
/// `horizontalSizeClass = .regular`，見 `TapTargetGateScreenName.swift`）。
@MainActor
final class SettingsViewIPadTests: XCTestCase {
    /// push 後系統返回鈕的 identifier 恆為 `"BackButton"`（label 會沿用上一頁的
    /// `.navigationTitle`，因區塊而異）——同 `SectionTabBarPushRegressionTests` 的既有理由，
    /// 不用 label 字串比對以免跟畫面上其他文字撞名。
    private func assertPushThenBackReturnsToList(
        app: XCUIApplication, entry: XCUIElement, pushedSentinel: XCUIElement,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "入口列應該存在才能開始這個情境", file: file, line: line)
        entry.tap()

        XCTAssertTrue(
            pushedSentinel.waitForExistence(timeout: 5),
            "點入口後應該已經 push 到目的地畫面——iPad 上曾經整個按不動（R1 B1）",
            file: file, line: line
        )
        let backButton = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "push 後應該出現系統返回鈕", file: file, line: line)

        backButton.tap()

        XCTAssertTrue(
            entry.waitForExistence(timeout: 5),
            "返回後應該回到原本的清單、重新看到入口列本身",
            file: file, line: line
        )
        XCTAssertFalse(pushedSentinel.exists, "返回後不該還看得到目的地畫面的內容")
    }

    /// 預設選取＝個人（`SettingsView.regularSelection` 初值），不需要先點 sidebar。對應
    /// reviewer 原始複現「點『個人』列（`qa.settings.profileRow`）→ 畫面完全沒變」。
    func testProfileSectionEntryPushesAndBackReturns() {
        let app = TapTargetMeasurement.launch(.settingsRegular)
        TapTargetMeasurement.assertScreenRendered(.settingsRegular, in: app)

        assertPushThenBackReturnsToList(
            app: app,
            entry: app.buttons[QAAccessibilityID.settingsProfileRow],
            pushedSentinel: app.staticTexts["編輯顯示名稱與頭像尚未推出，敬請期待。"]
        )
    }

    /// base（`6d9e01e`）上原本可用的「邀請家人」在 iPad 上的回歸樣本——reviewer 對照 base 的
    /// repro：「點『邀請家人』→ push 正常」。這裡驗證 R2 修完後 iPad 上依然正常，不是只有
    /// 本 PR 新增的七個入口被顧到、把已經可用的這顆列打壞。
    func testFamilySectionInviteRowRegressionPushesAndBackReturns() {
        let app = TapTargetMeasurement.launch(.settingsRegular)
        TapTargetMeasurement.assertScreenRendered(.settingsRegular, in: app)

        app.buttons["家庭"].tap()
        XCTAssertTrue(
            app.buttons[QAAccessibilityID.settingsInviteRow].waitForExistence(timeout: 5),
            "切到「家庭」後應該看得到「邀請家人」列"
        )

        assertPushThenBackReturnsToList(
            app: app,
            entry: app.buttons[QAAccessibilityID.settingsInviteRow],
            // `InviteFamilyView` 用 `.preview()` FamilyStore（`fetchLatestActiveInvite` 回
            // nil）進場會顯示「產生邀請碼」的空狀態按鈕——這顆按鈕是這個畫面在這個 harness
            // 組合下唯一保證存在、不受競速時序影響的文字。
            pushedSentinel: app.buttons["產生邀請碼"]
        )
    }

    /// reviewer 原始複現三支之一：「切到『內容與安全』→ 點『儲存空間』→ 沒有 push」。
    func testContentSafetySectionStorageRowPushesAndBackReturns() {
        let app = TapTargetMeasurement.launch(.settingsRegular)
        TapTargetMeasurement.assertScreenRendered(.settingsRegular, in: app)

        app.buttons["內容與安全"].tap()
        XCTAssertTrue(
            app.buttons[QAAccessibilityID.settingsStorageRow].waitForExistence(timeout: 5),
            "切到「內容與安全」後應該看得到「儲存空間」列"
        )

        assertPushThenBackReturnsToList(
            app: app,
            entry: app.buttons[QAAccessibilityID.settingsStorageRow],
            pushedSentinel: app.staticTexts["照片與影片會佔用空間，日記文字不會。"]
        )
    }

    /// reviewer 原始複現三支之一：「切到『帳號』→ 點『刪除帳號』→ 沒有 push」。
    func testAccountSectionDeleteRowPushesAndBackReturns() {
        let app = TapTargetMeasurement.launch(.settingsRegular)
        TapTargetMeasurement.assertScreenRendered(.settingsRegular, in: app)

        app.buttons["帳號"].tap()
        XCTAssertTrue(app.buttons["刪除帳號"].waitForExistence(timeout: 5), "切到「帳號」後應該看得到「刪除帳號」列")

        assertPushThenBackReturnsToList(
            app: app,
            entry: app.buttons["刪除帳號"],
            pushedSentinel: app.staticTexts["刪除帳號流程尚未推出，敬請期待。"]
        )
    }

    /// 「法律」兩列是 `Link`（開系統瀏覽器），不是 app 內 push——沒有返回鈕可驗，這裡只驗證
    /// sidebar 切換本身正常運作、兩列都看得到（不誤用「push＋返回」判準套在不會 push 的列上）。
    func testLegalSectionSwitchesWithoutPush() {
        let app = TapTargetMeasurement.launch(.settingsRegular)
        TapTargetMeasurement.assertScreenRendered(.settingsRegular, in: app)

        app.buttons["法律"].tap()

        XCTAssertTrue(app.buttons["使用條款"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["隱私權政策"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists, "Link 開系統瀏覽器，不應該在 app 內產生返回鈕")
    }
}

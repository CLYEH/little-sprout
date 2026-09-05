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
    /// merge-review R4 informational 1：`pushedSentinel` 的等待時間原本跟 `entry`／`backButton`
    /// 共用同一個 5 秒——`testFamilySectionInviteRowRegressionPushesAndBackReturns` 實測 1/6
    /// 會 flake，可疑點是 `InviteFamilyView.onAppear` 觸發的 `refreshLatestInvite()` 這段
    /// async 查詢（即使 `.preview()` stub 立即回傳，仍要走一次 Task 排程＋畫面重新渲染），跟
    /// 其他純同步渲染的目的地畫面（`編輯顯示名稱與頭像尚未推出`／`刪除帳號流程尚未推出`等靜態
    /// 文字）不同調。加一個獨立、預設值不變的 `pushedSentinelTimeout` 參數，只有邀請家人這條
    /// 測試傳長一點的值，其餘呼叫點行為不變。
    private func assertPushThenBackReturnsToList(
        app: XCUIApplication, entry: XCUIElement, pushedSentinel: XCUIElement,
        pushedSentinelTimeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "入口列應該存在才能開始這個情境", file: file, line: line)
        entry.tap()

        XCTAssertTrue(
            pushedSentinel.waitForExistence(timeout: pushedSentinelTimeout),
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
            pushedSentinel: app.buttons["產生邀請碼"],
            // informational 1：這顆按鈕要等 `onAppear` 觸發的 `refreshLatestInvite()` 跑完
            // 才會出現，比其他目的地畫面多一段 async 排程，5 秒在系統忙碌時偶爾不夠。
            pushedSentinelTimeout: 10
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

    /// merge-review R3 M3（major）：R3 版本用 `XCUIElement.isSelected` 當訊號，reviewer 四組
    /// mutation 證明這個讀值跟驅動視覺的 `isSelected` 變數完全無關（拿掉 trait 那行測到的其實
    /// 是 app crash，不是斷言鑑別力；trait 全拿掉／全部套用／視覺修法整個中性化，`isSelected`
    /// 讀值都不受影響，測試依然全綠）——`.isSelected` 在這個 SwiftUI ForEach+Button 組合下不
    /// 忠實反映 `.accessibilityAddTraits(.isSelected)`。
    ///
    /// R4 修法：選中態改用 `.accessibilityValue("已選取")`（`SettingsView+Sidebar.sidebarRow`）
    /// ——這是獨立於 trait 的另一個 accessibility 通道，`XCUIElement.value` 忠實反映它。這裡改
    /// 斷言「五列裡恰好一列的 value 是『已選取』，且切換 sidebar 後這個訊號跟著移動」，不再依賴
    /// `.isSelected`。純視覺樣式（邊框／陰影／背景色／字重）本身另由 `SettingsSidebarRowStyleTests`
    /// 這個純函式單元測試釘住（見該檔文件註解）——這條 UITest 對「視覺修法被中性化但 value 標記
    /// 還在」這種 mutation 不會轉紅是預期行為，責任分工在單元測試層。
    func testSidebarSelectionIsAccessibleAndDistinguishable() {
        let app = TapTargetMeasurement.launch(.settingsRegular)
        TapTargetMeasurement.assertScreenRendered(.settingsRegular, in: app)

        let labels = ["個人", "家庭", "內容與安全", "法律", "帳號"]
        func selectedLabels() -> [String] {
            labels.filter { (app.buttons[$0].value as? String) == "已選取" }
        }

        XCTAssertEqual(selectedLabels(), ["個人"], "預設應該恰好一列帶「已選取」訊號，且是「個人」")

        app.buttons["家庭"].tap()
        XCTAssertEqual(selectedLabels(), ["家庭"], "點擊「家庭」後「已選取」訊號應該恰好移到「家庭」，其餘四列都不再帶")
    }
}

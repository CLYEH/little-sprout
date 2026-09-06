import XCTest

/// LS-188 票文驗收：「UITests（root 五區存在、儲存空間頁可達）」＋使用者 2026-09-05 意見
/// （家庭區塊列文字要在列高內垂直置中，本票直接落地——見 `SettingsRowView` 文件註解）。
///
/// 共用 `TapTargetGateHarness`（`.settings`／`.settingsMemberRole`，見
/// `TapTargetGateScreenName.swift`）：`settingsFamilyStore(withFamily:)`（merge-review R1 M1
/// 訂正後新增，見 `TapTargetGateHarness+Settings.swift`）帶一個測試家庭＋同步 seed
/// `ownerUserID`／`members`（自己 `.member`，另一位 `.owner`），`.settings` 的 `childrenStore`
/// 角色由 `SettingsView` 新增的 `.task` 非同步補查（落到 `PreviewChildAPIClient.fetchMyRole`
/// 固定回傳的 `.owner`），`.settingsMemberRole` 同步 seed 成 `.member`。
@MainActor
final class SettingsViewTests: XCTestCase {
    // MARK: - 五區存在

    func testRootShowsAllFiveSectionHeaders() {
        let app = TapTargetMeasurement.launch(.settings)
        TapTargetMeasurement.assertScreenRendered(.settings, in: app)
        for header in ["個人", "家庭", "內容與安全", "法律", "帳號"] {
            XCTAssertTrue(
                app.staticTexts[header].waitForExistence(timeout: 5),
                "設定頁應該顯示「\(header)」區塊標題"
            )
        }
    }

    // MARK: - 區塊組成依角色（UI 層驗證；純函式判斷見 SettingsContentSafetyCompositionTests）

    func testOwnerSeesReportInboxRow() {
        let app = TapTargetMeasurement.launch(.settings)
        TapTargetMeasurement.assertScreenRendered(.settings, in: app)
        // `.task` 補查角色是非同步的——`waitForExistence` 讓斷言等它跑完，不是立刻判定失敗。
        XCTAssertTrue(app.buttons["檢舉紀錄"].waitForExistence(timeout: 5), "Owner 應該看得到「檢舉紀錄」列")
    }

    func testMemberDoesNotSeeReportInboxRow() {
        let app = TapTargetMeasurement.launch(.settingsMemberRole)
        TapTargetMeasurement.assertScreenRendered(.settingsMemberRole, in: app)
        // 先確定畫面真的渲染完「內容與安全」卡（用一定會出現的「封鎖名單」列當代表），
        // 排除「檢舉紀錄」單純因為畫面還沒畫完而不存在的偽陰性。
        XCTAssertTrue(app.buttons["封鎖名單"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["檢舉紀錄"].exists, "member 不應該看到「檢舉紀錄」列")
    }

    // MARK: - 儲存空間頁可達

    func testTappingStorageRowNavigatesToStorageUsageView() {
        let app = TapTargetMeasurement.launch(.settings)
        TapTargetMeasurement.assertScreenRendered(.settings, in: app)
        app.buttons[QAAccessibilityID.settingsStorageRow].tap()
        XCTAssertTrue(app.navigationBars["儲存空間"].waitForExistence(timeout: 5), "應該導覽到 09 儲存空間頁")
        XCTAssertTrue(
            app.staticTexts["照片與影片會佔用空間，日記文字不會。"].waitForExistence(timeout: 5),
            "儲存空間頁應該顯示底部說明文字"
        )
    }

    /// merge-review R1 m1：root 的「儲存空間」列本身要帶用量摘要（稿面「2.1／5 GB」），
    /// 不是只有點進去的 09 頁才看得到數字。`SettingsView` 的 `.task` 是 async 補查，
    /// `waitForExistence` 讓斷言等它跑完。
    func testStorageRowShowsUsageSummaryOnceQuotaLoads() {
        let app = TapTargetMeasurement.launch(.settings)
        TapTargetMeasurement.assertScreenRendered(.settings, in: app)
        XCTAssertTrue(
            app.staticTexts["2.1／5 GB"].waitForExistence(timeout: 5),
            "「儲存空間」列應該顯示 PreviewFamilyAPIClient 樣本值「2.1／5 GB」的用量摘要"
        )
    }

    // MARK: - 法律區改開 in-app sheet（LS-210；沿革：LS-191 原本只換掉歡迎頁，設定頁殘留 Link）

    /// 沿 `LegalDocumentSheetUITests.testWelcomeViewLegalLink_opensTermsOfServiceSheet_thenCloses`
    /// 既有 accessibility id（Doc Title staticText、Footer「關閉」button），入口換成設定頁「法律」
    /// 區的「使用條款」列（`Button` → `SettingsRowView`，見 `SettingsView.legalSection`）。
    ///
    /// **不能只用 `staticTexts["使用條款"]` 存在／不存在判斷**（實測踩到兩次，見下方 mutation
    /// 記錄）：`SettingsRowView` 的列 label 本身就是一字不差的「使用條款」`Text`，而 SwiftUI
    /// `.sheet()` 呈現時**底下畫面的 accessibility 元件並不會被隱藏**（跟一般直覺相反，這裡
    /// 是實測結果，不是查文件推測）——列表這顆「使用條款」列全程留在 accessibility tree 裡，
    /// 不論 sheet 有沒有開、開的是不是正確文件。歡迎頁那支測試不會踩到，因為該頁連結字面是
    /// 「《使用條款》」（帶書名號），跟 Doc Title「使用條款」本來就不會撞名。
    ///
    /// 兩個真正能用的訊號：
    /// 1. 「關閉」鈕只在 sheet 裡出現，設定頁其餘列沒有同名鈕——用來判斷「有沒有開 sheet」
    ///    （偵測到「拿掉 `.sheet` 綁定」這種 mutation：`closeButton` 全程不存在）。
    /// 2. sheet 顯示正確文件時，畫面上會有**兩個**label 是「使用條款」的 staticText（列本身
    ///    ＋ Doc Title 各一個）；顯示錯誤文件（例如把兩列的 `presentedLegalDocument` 指定值
    ///    對調）時只剩列本身那一個，數量掉到 1——用數量比對取代單純的存在性判斷，才測得出
    ///    「開錯文件」這種 mutation（只判斷存在性，兩種情況下「使用條款」都查得到，測不出來，
    ///    實測驗證過）。
    func testTappingTermsRowOpensLegalDocumentSheet_thenCloses() {
        let app = TapTargetMeasurement.launch(.settings)
        TapTargetMeasurement.assertScreenRendered(.settings, in: app)

        let termsRow = app.buttons["使用條款"]
        XCTAssertTrue(termsRow.waitForExistence(timeout: 5), "設定頁「法律」區應有可點擊的「使用條款」列")
        termsRow.tap()

        let closeButton = app.buttons["關閉"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "點擊「使用條款」列後應開啟 LegalDocumentSheet（Footer「關閉」鈕可見）")
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "使用條款")).count, 2,
            "應同時看到「使用條款」列與 Doc Title 兩個「使用條款」文字元件——只剩 1 個代表開錯文件（sheet 顯示的是隱私權政策）"
        )

        closeButton.tap()
        XCTAssertFalse(closeButton.waitForExistence(timeout: 3), "點擊關閉後 sheet 應消失（Footer「關閉」鈕不應再存在）")
    }

    /// 同上，換「隱私權政策」列，驗證開的是對應文件（不是誤開使用條款）——理由與數量比對手法
    /// 見上一支測試文件註解。
    func testTappingPrivacyRowOpensCorrectLegalDocumentSheet() {
        let app = TapTargetMeasurement.launch(.settings)
        TapTargetMeasurement.assertScreenRendered(.settings, in: app)

        let privacyRow = app.buttons["隱私權政策"]
        XCTAssertTrue(privacyRow.waitForExistence(timeout: 5), "設定頁「法律」區應有可點擊的「隱私權政策」列")
        privacyRow.tap()

        XCTAssertTrue(app.buttons["關閉"].waitForExistence(timeout: 5), "點擊「隱私權政策」列應開啟 LegalDocumentSheet（Footer「關閉」鈕可見）")
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "隱私權政策")).count, 2,
            "應同時看到「隱私權政策」列與 Doc Title 兩個「隱私權政策」文字元件——只剩 1 個代表開錯文件（sheet 顯示的是使用條款）"
        )
    }

    // MARK: - 垂直置中（使用者 2026-09-05 核可 LS-152 稿的唯一意見）

    /// 單行列樣本：「邀請家人」只有 label、沒有副標，`SettingsRowView` 靠 `HStack` 預設
    /// `alignment: .center` 置中（見該檔文件註解）。
    func testInviteRowLabelIsVerticallyCenteredWithinRowHeight() {
        let app = TapTargetMeasurement.launch(.settings)
        TapTargetMeasurement.assertScreenRendered(.settings, in: app)

        let row = app.buttons[QAAccessibilityID.settingsInviteRow]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let label = app.staticTexts["邀請家人"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))

        assertVerticallyCentered(
            groupMinY: label.frame.minY, groupMaxY: label.frame.maxY, rowFrame: row.frame, rowLabel: "邀請家人"
        )
    }

    /// 多行副標樣本：「個人」列的姓名＋「編輯顯示名稱與頭像」副標——使用者原話「含多行副標的
    /// 列要整組垂直置中」，量測姓名＋副標**整組**的邊界框中線，不是逐行各自置中（逐行各自
    /// 置中在兩行文字的情境下不可能同時成立）。
    func testProfileRowNameAndSubtitleGroupIsVerticallyCenteredWithinRowHeight() {
        let app = TapTargetMeasurement.launch(.settings)
        TapTargetMeasurement.assertScreenRendered(.settings, in: app)

        let row = app.buttons[QAAccessibilityID.settingsProfileRow]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let subtitle = app.staticTexts["編輯顯示名稱與頭像"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5))
        // merge-review R1 M1 訂正後：`.settings` harness（`settingsFamilyStore(withFamily:)`）
        // 同步 seed 了 `ownerUserID`，`SettingsView` 的 `.task(id: familyStore.ownerUserID)`
        // 因此會補查 `myProfile`（`PreviewFamilyAPIClient.fetchMyProfile()` 固定回傳
        // `displayName: "陳美玲"`）——`displayName` 優先用 `myProfile?.displayName`，不再落到
        // `"我"` 這個 fallback（見該屬性文件註解）。
        let name = app.staticTexts["陳美玲"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))

        let groupMinY = min(name.frame.minY, subtitle.frame.minY)
        let groupMaxY = max(name.frame.maxY, subtitle.frame.maxY)
        assertVerticallyCentered(groupMinY: groupMinY, groupMaxY: groupMaxY, rowFrame: row.frame, rowLabel: "個人")
    }

    /// merge-review R1 m2：容差原本是 1.0pt——單行列（「邀請家人」）icon 22pt 與文字 ~20.3pt
    /// 的最大天然偏移量本來就 <1pt，這條斷言在「拿掉置中」的 mutation（`HStack` 改
    /// `alignment: .top`）下量到 −0.83pt 仍然吃得下、測不出退化。收到 0.5pt 後 R2 重新跑
    /// mutation 兩條都紅（邀請家人 −0.667pt、個人 −7.33pt），但 reviewer R2 informational 3
    /// 指出偵測邊際仍薄：0.5pt 門檻對 0.667pt 的 mutation 只留 0.167pt 餘裕，icon token／
    /// 字級稍微一動可能又測不出來。
    ///
    /// R3 改良：斷言改成「文字群組上緣到列頂的距離＝文字群組下緣到列底的距離」（`topGap` ＝
    /// `bottomGap`），數學上等於 `groupMidY`／`rowMidY` 差的兩倍（`topGap − bottomGap
    /// = 2 × (groupMidY − rowMidY)`）——量測的是同一份像素資料，門檻不變（仍是
    /// `centeringToleranceInPoints`），但訊號放大一倍：baseline 仍 ~0pt，mutation 訊號從
    /// 0.667pt 放大到 1.33pt，對 0.5pt 門檻的餘裕從 0.167pt 拉開到 0.83pt，不必真的調鬆門檻
    /// 就解決「邊際太薄」的問題。
    private static let centeringToleranceInPoints: CGFloat = 0.5

    private func assertVerticallyCentered(
        groupMinY: CGFloat, groupMaxY: CGFloat, rowFrame: CGRect, rowLabel: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let topGap = groupMinY - rowFrame.minY
        let bottomGap = rowFrame.maxY - groupMaxY
        XCTAssertEqual(
            topGap, bottomGap, accuracy: Self.centeringToleranceInPoints,
            "「\(rowLabel)」列文字（群組）上緣留白 \(topGap) 與下緣留白 \(bottomGap) 差超過"
                + " \(Self.centeringToleranceInPoints)pt——不是置中在列高正中央",
            file: file, line: line
        )
    }
}

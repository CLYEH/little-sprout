import XCTest

/// LS-188 票文驗收：「UITests（root 五區存在、儲存空間頁可達）」＋使用者 2026-09-05 意見
/// （家庭區塊列文字要在列高內垂直置中，本票直接落地——見 `SettingsRowView` 文件註解）。
///
/// 共用 `TapTargetGateHarness`（`.settings`／`.settingsMemberRole`，見
/// `TapTargetGateScreenName.swift`）：`familyStore.preview(withFamily:)` 帶一個測試家庭，
/// `.settings` 的 `childrenStore` 角色由 `SettingsView` 新增的 `.task` 非同步補查（落到
/// `PreviewChildAPIClient.fetchMyRole` 固定回傳的 `.owner`），`.settingsMemberRole` 同步
/// seed 成 `.member`。
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
        app.buttons["儲存空間"].tap()
        XCTAssertTrue(app.navigationBars["儲存空間"].waitForExistence(timeout: 5), "應該導覽到 09 儲存空間頁")
        XCTAssertTrue(
            app.staticTexts["照片與影片會佔用空間，日記文字不會。"].waitForExistence(timeout: 5),
            "儲存空間頁應該顯示底部說明文字"
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
        // `authStore.session` 在 harness 裡是 nil（`PreviewAuthService.currentSession` 預設
        // 值），`SettingsView.displayName` 因此落到 `"我"` 這個 fallback（見該屬性文件註解）
        // ——不是猜測，是目前這個 harness 組合下唯一會發生的字面值。
        let name = app.staticTexts["我"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))

        let groupMinY = min(name.frame.minY, subtitle.frame.minY)
        let groupMaxY = max(name.frame.maxY, subtitle.frame.maxY)
        assertVerticallyCentered(groupMinY: groupMinY, groupMaxY: groupMaxY, rowFrame: row.frame, rowLabel: "個人")
    }

    private func assertVerticallyCentered(
        groupMinY: CGFloat, groupMaxY: CGFloat, rowFrame: CGRect, rowLabel: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let groupMidY = (groupMinY + groupMaxY) / 2
        XCTAssertEqual(
            groupMidY, rowFrame.midY, accuracy: 1.0,
            "「\(rowLabel)」列文字（群組）中線 \(groupMidY) 與列高中線 \(rowFrame.midY) 差超過 1pt",
            file: file, line: line
        )
    }
}

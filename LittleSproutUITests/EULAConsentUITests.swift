import XCTest

/// LS-190 票文驗收：「UITests（首次登入 → EULA 出現 → 同意 → 進時間軸）」。
@MainActor
final class EULAConsentUITests: XCTestCase {
    /// 用 `.eulaConsentToTimelineFlow` harness（`TapTargetGateHarness.eulaConsentToTimelineHost`
    /// ——直接建構 `AuthenticatedGate`，同 `.sectionTabViewWithDiary` 借用「launch environment
    /// 指定畫面」通道走完整反應式流程的既有作法）：一開畫面 `eulaStore.shouldPresent` 已種為
    /// `true`，EULA 標題必定先渲染；按下「我已閱讀並同意」後 `EULAStore.accept(userID:)` 成功
    /// 把 `shouldPresent` 收回 `false`，`AuthenticatedGate` 立刻換到已經種好家庭資料的主畫面
    /// （不需要真的登入或建立家庭）。
    func testEULAConsent_agreeing_advancesToTimeline() {
        let app = TapTargetMeasurement.launch(.eulaConsentToTimelineFlow)
        TapTargetMeasurement.assertScreenRendered(.eulaConsentToTimelineFlow, in: app)

        let agreeButton = app.buttons["我已閱讀並同意"]
        XCTAssertTrue(agreeButton.waitForExistence(timeout: 5), "EULA 同意頁應顯示「我已閱讀並同意」實心主鈕")
        agreeButton.tap()

        let timelineHeader = app.staticTexts["時間軸"]
        XCTAssertTrue(
            timelineHeader.waitForExistence(timeout: 5),
            "同意後應換到主畫面，時間軸分頁的自訂 Header 文字「時間軸」應出現"
        )
        XCTAssertFalse(
            app.staticTexts["使用條款更新"].exists,
            "同意並換到主畫面後，EULA 同意頁本身（含標題）不應該還留在畫面樹上"
        )
    }

    /// `.eulaConsent`（不接時間軸切換，純顯示）：零容忍卡的兩個法務連結應可點，開啟對應
    /// `LegalDocumentSheet`——同 `LegalDocumentSheetUITests` 對 `WelcomeView` 連結的既有測法。
    func testEULAConsent_legalLink_opensTermsOfServiceSheet() {
        let app = TapTargetMeasurement.launch(.eulaConsent)
        TapTargetMeasurement.assertScreenRendered(.eulaConsent, in: app)

        let termsLink = app.links["《使用條款》"]
        XCTAssertTrue(termsLink.waitForExistence(timeout: 5), "EULA 同意頁應含可點擊的《使用條款》連結")
        termsLink.tap()

        XCTAssertTrue(
            app.staticTexts["使用條款"].waitForExistence(timeout: 5),
            "點擊連結後應開啟 LegalDocumentSheet，顯示 Doc Title「使用條款」"
        )
    }

    /// 版面完整性：零容忍卡四點摘要與「同意並繼續」動作列都要在畫面上，任何一項不見都代表
    /// AX3／版面破版或釘底動作帶壓住法務文字（同 LS-152 R1-R4 review 反覆抓到的那個 class）。
    func testEULAConsent_zeroToleranceCardAndActionBarBothVisible() {
        let app = TapTargetMeasurement.launch(.eulaConsent)
        TapTargetMeasurement.assertScreenRendered(.eulaConsent, in: app)

        XCTAssertTrue(app.staticTexts["對冒犯性內容零容忍"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["我已閱讀並同意"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["不同意，登出"].waitForExistence(timeout: 5))
    }
}

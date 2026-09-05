import UIKit
import XCTest

/// LS-191 票文驗收：「UITests（歡迎頁點《使用條款》→ sheet 出現 → 關閉；Footer 可見）」。
/// 共用 `TapTargetGateHarness`（`.welcome`）直接啟動到歡迎頁，同
/// `PasswordSignInUITests`（LS-164）既有作法，不需要真的登入或建立家庭。
@MainActor
final class LegalDocumentSheetUITests: XCTestCase {
    func testWelcomeViewLegalLink_opensTermsOfServiceSheet_thenCloses() {
        let app = TapTargetMeasurement.launch(.welcome)
        TapTargetMeasurement.assertScreenRendered(.welcome, in: app)

        // `Text(AttributedString)` 的 `.link` range 曝露成獨立的 `XCUIElementTypeLink`
        // accessibility 元件（不是 staticText 的一部分），可直接查詢／點擊。
        let termsLink = app.links["《使用條款》"]
        XCTAssertTrue(termsLink.waitForExistence(timeout: 5), "歡迎頁法務行應含可點擊的《使用條款》連結")
        termsLink.tap()

        let docTitle = app.staticTexts["使用條款"]
        XCTAssertTrue(docTitle.waitForExistence(timeout: 5), "點擊連結後應開啟 LegalDocumentSheet，顯示 Doc Title「使用條款」")

        let closeButton = app.buttons["關閉"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Footer 關閉鈕應可見（safeAreaInset 釘底，不需捲動就看得到）")
        XCTAssertGreaterThanOrEqual(
            closeButton.frame.height, TapTargetMeasurement.minSide, "關閉鈕熱區必須 ≥44pt，長輩硬約束"
        )

        closeButton.tap()
        XCTAssertFalse(docTitle.waitForExistence(timeout: 3), "點擊關閉後 sheet 應消失")
    }

    func testWelcomeViewLegalLink_privacyPolicy_opensCorrectDocument() {
        let app = TapTargetMeasurement.launch(.welcome)
        TapTargetMeasurement.assertScreenRendered(.welcome, in: app)

        let privacyLink = app.links["《隱私權政策》"]
        XCTAssertTrue(privacyLink.waitForExistence(timeout: 5), "歡迎頁法務行應含可點擊的《隱私權政策》連結")
        privacyLink.tap()

        XCTAssertTrue(
            app.staticTexts["隱私權政策"].waitForExistence(timeout: 5),
            "點擊《隱私權政策》連結應開啟對應文件，不是誤開使用條款"
        )
    }

    /// merge-review R1 F1（`807855dc`）迴歸測試：iPad 上 `LegalDocumentSheet` 必須真的走
    /// 置中卡片版面（520 卡－87.5×2 內距＝345 內容欄），不是 R1 那個「`horizontalSizeClass`
    /// 在 sheet 內恆為 `.compact`，regular 分支從未執行」的死碼狀態（系統預設 form sheet
    /// ≈580 寬套 iPhone 版 24pt 內距＝內容欄 ≈532）。用 Footer「關閉」鈕的 frame width 當
    /// 代理指標——`SecondaryButton` 內部 `.frame(maxWidth: .infinity)` 撐滿外層扣掉
    /// `horizontalPadding` 後的可用寬度，量到的就是內容欄本身，不需要額外插測量碼；
    /// iPad 分支使用 87.5 內距、iPhone／fallback 分支使用 24（`AppSpacing.screenPad`），兩者
    /// 換算出的欄寬差距（345 vs ≈532）遠大於量測誤差，足以區分兩種狀態。
    ///
    /// 只在 iPad idiom 執行（`XCTSkipUnless`）——`UIDevice.current.userInterfaceIdiom` 量的
    /// 是執行這支測試的模擬器本身（跟 app 內部同一顆裝置），跟 sheet presentation 容器的
    /// size class 無關，這正是 R2 修法選它的理由。push-gate／CI 常態用的 iPhone 專屬機會
    /// 略過這支測試（不佔用一般跑測時間）；要驗證這支測試本身，需在 iPad 模擬器上跑
    /// `-only-testing:LittleSproutUITests/LegalDocumentSheetUITests/` 加這個方法名。
    func testLegalDocumentSheet_onIPad_contentColumnWidthMatchesDesign() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad 專屬版面測試，非 iPad 裝置（例如 push-gate 常態用的 iPhone 專屬機）略過"
        )
        let app = TapTargetMeasurement.launch(.legalDocumentSheet)
        TapTargetMeasurement.assertScreenRendered(.legalDocumentSheet, in: app)

        let closeButton = app.buttons["關閉"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        // 520（Notes `W0Umr` R3 定案卡寬）－ 87.5×2 內距 ＝ 345；±4pt 容許量測誤差
        // （merge-review R1 `807855dc` 建議值）。
        XCTAssertEqual(closeButton.frame.width, 345, accuracy: 4)
    }

    /// merge-review R3 F1（`889164c6`）迴歸測試：320pt 窄容器 proxy（`debugForcedPadCardWidth:
    /// 320`，見 `LegalDocumentSheet` 文件註解）下，內距必須降到下限 24、內容欄變寬到
    /// ≈272pt——不是 R3 那個「`LegalDocumentSheetWidthKey` 的 `defaultValue`＋`reduce` 讓
    /// 量到的真寬被 520 蓋掉」的死碼狀態（那個狀態下不論容器多窄，內距永遠算成 87.5、內容欄
    /// 卡在 320−175＝145）。**不需要 iPad 裝置，在任何模擬器（含 push-gate／CI 常態用的
    /// iPhone 專屬機）都會實跑，不是 skip**——這正是 R3 review 指出「既有 iPad 專屬測試在
    /// 全螢幕下量到的真寬剛好等於預設值，測不出這個缺陷」的補完：這支測試用
    /// `debugForcedPadCardWidth` 強制走 iPad 分支＋鎖住一個「預設值不等於真值」的容器寬度，
    /// wiring 一旦壞掉就一定測得出來。
    func testLegalDocumentSheet_narrowContainerProxy320_widensContentAndShrinksPadding() {
        let app = TapTargetMeasurement.launch(.legalDocumentNarrowContainer)
        TapTargetMeasurement.assertScreenRendered(.legalDocumentNarrowContainer, in: app)

        let closeButton = app.buttons["關閉"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        // 320（容器寬）－ 24×2（內距下限）＝ 272；±4pt 容許量測誤差（R4 實測精準命中
        // 272.0pt，無需容許誤差也會過，見 handoff）。R3 的死碼狀態會量到 320−87.5×2＝145，
        // 遠低於 272−4＝268 的下界，兩種狀態的數字差距遠大於量測誤差，足以區分「wiring
        // 生效」與「wiring 死碼」。
        XCTAssertEqual(closeButton.frame.width, 272, accuracy: 4, "內距應降到下限 24、內容欄應是 ≈272，不是死碼狀態的 145")
    }
}

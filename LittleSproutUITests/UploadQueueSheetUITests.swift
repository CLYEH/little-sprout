import XCTest

/// LS-167：上傳佇列 sheet 的行為性 UITest——票文驗收條件「UITests（佇列出現、重試鈕存在）」。
/// 幾何（≥44pt）由 `TapTargetGateTests.testUploadQueueSheetView` 的標準掃描涵蓋，這裡只驗證
/// 「畫面出現」與「該有的元件存在」。用同一套 `TapTargetGateHarness` launch environment 機制
/// （`UploadQueueStore.previewSample()` 提供代表性樣本：三群、LS002 置頂、兩張可重試的失敗
/// 列），不需要相簿詳情的真正入口（LS-166 尚未落地）。
@MainActor
final class UploadQueueSheetUITests: XCTestCase {
    func test_uploadQueueSheet_appearsWithThreeGroupTitles() {
        let app = TapTargetMeasurement.launch(.uploadQueueSheet)
        TapTargetMeasurement.assertScreenRendered(.uploadQueueSheet, in: app)

        XCTAssertTrue(app.staticTexts["沒有成功"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["正在進行"].exists)
        XCTAssertTrue(app.staticTexts["已完成"].exists)
    }

    /// `design/littlesprout.pen` Handoff Notes `pUvzU`／INFO-N3：LS002（容量已滿）固定排在
    /// Failed 群最前——不提供「重試」，只給「查看儲存空間」；其餘可重試的失敗列（`network`／
    /// `server`）才顯示「重試」鈕。
    func test_uploadQueueSheet_showsRetryButtons_andQuotaRowShowsStorageLinkInstead() {
        let app = TapTargetMeasurement.launch(.uploadQueueSheet)
        TapTargetMeasurement.assertScreenRendered(.uploadQueueSheet, in: app)

        XCTAssertTrue(app.staticTexts["相簿容量已滿，這張沒有上傳。"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["查看儲存空間"].exists, "LS002 列不提供重試，只給查看儲存空間出路")
        XCTAssertTrue(app.buttons["重試"].exists, "network／server 兩筆失敗都有各自的單列重試鈕")
        XCTAssertTrue(app.buttons["重試這 2 張"].exists, "兩筆可重試的失敗（不含 LS002）才計進批次重試文案")
    }

    func test_uploadQueueSheet_showsBackgroundContinueFooterButton() {
        let app = TapTargetMeasurement.launch(.uploadQueueSheet)
        TapTargetMeasurement.assertScreenRendered(.uploadQueueSheet, in: app)

        XCTAssertTrue(app.buttons["在背景繼續，關閉視窗"].waitForExistence(timeout: 10))
    }

    /// merge-review R2 F2：`previewSample()` 現在固定把 `resumedFromInterruption` 設
    /// `true`（見該檔文件註解），續傳橫幅才有機會在 preview／UITest／QA 截圖裡被看到。
    func test_uploadQueueSheet_showsResumeBanner() {
        let app = TapTargetMeasurement.launch(.uploadQueueSheet)
        TapTargetMeasurement.assertScreenRendered(.uploadQueueSheet, in: app)

        XCTAssertTrue(app.staticTexts["已接續先前中斷的上傳。"].waitForExistence(timeout: 10))
    }

    /// merge-review R3 M1（major）：生產常態（無失敗、無續傳橫幅）下 `summarySection`／
    /// `rowsSection` 沒有任何撐寬子元件時曾被外層預設 `.center` 的 `body` VStack 水平置中——
    /// reviewer 實測群標題 x=119.3，應為 24（`AppSpacing.screenPad`）。用
    /// `.uploadQueueSheetNormal`（見 `UploadQueueStore.previewNormalSample()`）釘住兩處都
    /// 貼齊左緣。
    func test_uploadQueueSheetNormal_leftAlignsSummaryAndRows() {
        let app = TapTargetMeasurement.launch(.uploadQueueSheetNormal)
        TapTargetMeasurement.assertScreenRendered(.uploadQueueSheetNormal, in: app)

        let title = app.staticTexts["正在新增照片"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.frame.minX, 24, accuracy: 1, "標題應該貼齊 screenPad(24)，不是被置中")

        let groupTitle = app.staticTexts["正在進行"]
        XCTAssertTrue(groupTitle.waitForExistence(timeout: 10))
        XCTAssertEqual(groupTitle.frame.minX, 24, accuracy: 1, "群標題應該貼齊 screenPad(24)，不是被置中")
    }
}

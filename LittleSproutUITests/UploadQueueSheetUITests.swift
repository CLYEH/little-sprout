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
    /// `.uploadQueueSheetNormal`（見 `UploadQueueStore.previewNormalSample()`）釘住這個位置。
    ///
    /// merge-review R5（coordinator 裁定）：原本斷言 `minX == 24`（絕對常數）在 CI 的
    /// iOS 26.2+ 模擬器上會誤判——那個環境對 `.sheet` 內容整體套用 ≈0.9602 縮放（見
    /// `UploadQueueRowView.swift` 檔頭「merge-review R5（真正的根因）」段），連 x 座標都被
    /// 等比例縮放，24 這個未縮放常數在 CI 上永遠量不到（本票期間實測落地 31.04，不是原本
    /// 猜測的簡單等比例縮小——縮放是繞著 sheet 水平中心進行，越靠左緣的點反而被「推」得
    /// 離常數期望值更遠），跟程式碼本身有沒有這個 bug 完全無關，是量測方法本身的假陽性。
    ///
    /// 改用同一個 sheet 內已知滿版、因此左緣必然貼齊 `screenPad` 的參照元件（footer 按鈕——
    /// 它的 `Text` 本身就是 `.frame(maxWidth: .infinity, minHeight: 48)`，寬度由容器決定，
    /// 不像 grabber 是視覺置中的固定寬度膠囊）取代絕對常數：兩個「理論上未縮放時 x 相等」的
    /// 元件，不管縮放中心與係數是多少，縮放後仍然相等（`C + (x - C) * s`，`x` 相等則結果相等，
    /// 與 `s` 無關）——這樣的比較天生對這個環境縮放免疫，同時 R3 那個 bug（群標題被置中到
    /// x=119.3）一樣會讓 `groupTitle.frame.minX` 遠遠偏離 `referenceX`，抓得到。
    func test_uploadQueueSheetNormal_leftAlignsSummaryAndRows() {
        let app = TapTargetMeasurement.launch(.uploadQueueSheetNormal)
        TapTargetMeasurement.assertScreenRendered(.uploadQueueSheetNormal, in: app)

        let footer = app.buttons["在背景繼續，關閉視窗"]
        XCTAssertTrue(footer.waitForExistence(timeout: 10))
        let referenceX = footer.frame.minX

        let title = app.staticTexts["正在新增照片"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(
            title.frame.minX, referenceX, accuracy: 1,
            "標題應該貼齊 footer 左緣（screenPad），不是被置中"
        )

        let groupTitle = app.staticTexts["正在進行"]
        XCTAssertTrue(groupTitle.waitForExistence(timeout: 10))
        XCTAssertEqual(
            groupTitle.frame.minX, referenceX, accuracy: 1,
            "群標題應該貼齊 footer 左緣（screenPad），不是被置中"
        )

        // 列內容：縮圖（`UploadQueueRowView.thumbnailSize` 64pt）＋`AppSpacing.label`（8pt）
        // 之後才是時間戳文字起點——同一個 HStack 裡兩個 x 有真正的物理距離（72pt），不像上面
        // 兩個「理論上該相等」的比較天生免疫縮放：距離本身也會被同一個環境縮放係數等比例
        // 縮小（例如 iOS 26.2+ CI 的 ≈0.9602：72 × 0.9602 ≈ 69.1）。
        //
        // merge-review R6（reviewer `e36410f7` I-2）：R5 版本用固定 `+ 72` 搭配 4pt 容差吸收
        // 這個縮放誤差，餘裕只剩 1.13pt——係數只要偏離 0.9602 一點就會假紅，跟這輪修掉的
        // 絕對常數 24 是同一類病，只是換了個位置。改成直接從已知幾何反推「當下這次執行」的
        // 實際縮放係數，不假設任何特定數字：footer 的 `Text` 是 `.frame(minHeight: 48)`，
        // 單行文字下 SwiftUI 會精確算出這個高度（R4／R5 已實測驗證過是精確值，不是留有餘裕的
        // 下限近似），所以 `footer.frame.height / 48` 就是當下環境的縮放係數。算出係數後
        // 容差可以收緊回 1pt（只剩子像素捨入誤差）。
        let scale = footer.frame.height / 48

        // merge-review R6（reviewer `e36410f7` I-3）：原本用 `BEGINSWITH "今天 "` 精確比對，
        // 若 UITest 剛好在本地時間 00:00:00–00:01:00 之間啟動，`previewNormalSample()` 播種
        // 的「幾十秒前」時間戳會跨過午夜被格式化成「昨天 HH:mm」，導致這個 predicate 找不到
        // 元素而假紅（機率極低但會長得像版面迴歸、很難查）。改用不依賴日期字首的 regex——
        // 只認「結尾是 HH:mm」這個所有三種格式（今天／昨天／M/d）共有的形狀，不假設是哪一種。
        let timestamp = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", ".*\\d{2}:\\d{2}$")
        ).firstMatch
        XCTAssertTrue(timestamp.waitForExistence(timeout: 10))
        XCTAssertEqual(
            timestamp.frame.minX, referenceX + 72 * scale, accuracy: 1,
            "時間戳應該接在縮圖（64pt）＋間距（8pt）之後，不是被置中或間距跑掉"
        )
    }
}

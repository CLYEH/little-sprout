import XCTest

/// LS-391：批次匯入整理頁（01）／04 進度頁／05 完成摘要頁的頂列按鈕必須落在狀態列之下、可點。
///
/// **為什麼走真的 PHPicker**：bug 只在「picker dismiss 轉場途中 present `.fullScreenCover`」時
/// 出現——整個 cover 的 safe area insets 變成 0，頂列（8pt 上內距）直接畫在 y≈8，壓在時鐘上。
/// 把這幾個畫面直接當根 view 掛（`.importOrganizeDefault` 等 tap-target host）或單純包一層
/// `.fullScreenCover` 都量不到（LS-391 r1 截圖），所以這支測試照使用者路徑走：
/// 入口鈕 → 相片庫授權（有跳就允許）→ picker 選第一張 → 完成 → 01 → 開始匯入 → 04 → 05。
/// 違背 `TimelineImportEntryUITests` 檔頭「PHPicker 不自動化」慣例是刻意的：沒有其他通道
/// 重現得出這個時序。
///
/// **safe area 參照**：harness 入口鈕貼齊 safe area 頂端（`ImportBatchFlowEntryHost`），
/// 啟動時先記下它的 `minY`，cover 裡的頂列按鈕 `minY` 不得小於它——座標取相對參照、不寫死
/// 常數（iOS 26.2+ 縮放教訓，LS-167）。另外斷言 `isHittable`。
///
/// 淺深 × 預設／AX3 四組，驗收條件「截圖淺深 × 預設／AX3」的截圖以 attachment 保留。
@MainActor
final class ImportFlowTopBarSafeAreaUITests: XCTestCase {
    private static let large = "UICTContentSizeCategoryL"
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    func testLightDefault_topBarButtonsBelowStatusBar() {
        runFlow(.importBatchFlowEntry, size: Self.large, tag: "light-default")
    }

    func testLightAX3_topBarButtonsBelowStatusBar() {
        runFlow(.importBatchFlowEntry, size: Self.ax3, tag: "light-AX3")
    }

    func testDarkDefault_topBarButtonsBelowStatusBar() {
        runFlow(.importBatchFlowEntryDark, size: Self.large, tag: "dark-default")
    }

    func testDarkAX3_topBarButtonsBelowStatusBar() {
        runFlow(.importBatchFlowEntryDark, size: Self.ax3, tag: "dark-AX3")
    }

    // MARK: - 流程

    private func runFlow(_ screen: TapTargetGateScreenName, size: String, tag: String) {
        let app = TapTargetMeasurement.launch(screen, contentSizeCategory: size)
        TapTargetMeasurement.assertScreenRendered(screen, in: app)
        let entry = app.buttons["開始批次匯入"]
        XCTAssertTrue(entry.waitForHittable(timeout: 10), "[\(tag)] 入口鈕應可點")
        let safeTop = entry.frame.minY
        XCTAssertGreaterThan(safeTop, 0, "[\(tag)] 入口鈕貼齊 safe area 頂端，minY 應 >0（有狀態列）")
        entry.tap()

        guard pickFirstPhoto(in: app, tag: tag) else { return }

        // 01 整理頁
        assertTopBarButton(app.buttons["取消"], safeTop: safeTop, name: "01 整理頁「取消」", tag: tag)
        attachScreenshot(app, "\(tag)-01-organize")

        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "開始匯入")).firstMatch
        XCTAssertTrue(start.waitForHittable(timeout: 10), "[\(tag)] 01 主鈕「開始匯入」應可點")
        start.tap()

        // 04 進度頁（harness coordinator 延後 3 秒才標群已解決，04 停得住）
        let cancelImport = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "取消匯入")).firstMatch
        assertTopBarButton(cancelImport, safeTop: safeTop, name: "04 進度頁「取消匯入」", tag: tag)
        attachScreenshot(app, "\(tag)-04-progress")

        // 05 完成摘要頁
        assertTopBarButton(app.buttons["完成"], safeTop: safeTop, name: "05 摘要頁「完成」", tag: tag, timeout: 15)
        attachScreenshot(app, "\(tag)-05-summary")
    }

    /// 相片庫授權對話框（首次才跳）與 picker 本身都是系統 UI——等其中一個出現：授權框就允許，
    /// 再在 picker 裡點第一張、按完成。找不到照片直接紅（模擬器預設相片庫應有範例照片），
    /// 不靜默略過。
    private func pickFirstPhoto(in app: XCUIApplication, tag: String) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowFull = springboard.buttons["Allow Full Access"]
        let firstPhoto = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo")).firstMatch
        let deadline = Date().addingTimeInterval(20)
        while !firstPhoto.exists && Date() < deadline {
            if allowFull.exists { allowFull.tap() }
            _ = firstPhoto.waitForExistence(timeout: 1)
        }
        guard firstPhoto.exists else {
            XCTFail("[\(tag)] 20 秒內沒看到 picker 裡的照片（授權框沒處理到，或模擬器相片庫是空的）")
            attachScreenshot(app, "\(tag)-picker-missing")
            return false
        }
        // picker 內容是遠端 view，XCUITest 判定元素「not hittable」、`tap()` 直接失敗——改點座標。
        firstPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Add"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "[\(tag)] picker「Done」鈕應存在")
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    /// 頂列按鈕：`minY` 不得高於 safe area 頂端（畫進狀態列＝bug 本體），且可點。
    private func assertTopBarButton(
        _ button: XCUIElement, safeTop: CGFloat, name: String, tag: String, timeout: TimeInterval = 10
    ) {
        guard button.waitForExistence(timeout: timeout) else {
            XCTFail("[\(tag)] \(name) 沒出現")
            return
        }
        let minY = button.frame.minY
        XCTAssertGreaterThanOrEqual(
            minY, safeTop - 0.5,
            "[\(tag)] \(name) minY=\(minY) 高於 safe area 頂端 \(safeTop)——頂列畫進狀態列（LS-391）"
        )
        XCTAssertTrue(button.waitForHittable(timeout: 5), "[\(tag)] \(name) 應可點（isHittable）")
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "LS-391-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

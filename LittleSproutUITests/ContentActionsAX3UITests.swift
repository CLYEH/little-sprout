import XCTest

/// LS-189：內容操作表流程在 AX3（`accessibility-extra-large`）下不破版——硬規則「iOS 26.2+
/// sheet 內 UITest 座標斷言用相對參照、可點元件 minHeight ≥48」。跟 `DeleteConfirmationAX3
/// UITests` 那支「找截斷」測試不同類：這裡的動作列／原因列都是短句（最長「侵害隱私或未經同意的
/// 內容」12 字），本來就會自然換行而不是被固定高度容器攔腰截斷（`ContentActionsSheet`／
/// `ReportReasonSheet` 從第一版就是 `.medium`／`.large` 兩級 detent＋`ScrollView`，不是
/// `DeleteConfirmationSheet` R1 版那種會自我量測循環相依的結構）——這裡驗證的是「AX3 下所有列
/// 仍然存在、可捲動可觸達、彼此不重疊」，用 `launchArguments`（不用 `launchEnvironment`，同
/// `TapTargetMeasurement.launch(_:contentSizeCategory:)` 既有理由）。
@MainActor
final class ContentActionsAX3UITests: XCTestCase {
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    func testContentActionsSheet_ax3_allRowsReachableAndDoNotOverlap() {
        let app = TapTargetMeasurement.launch(.diaryDetail, contentSizeCategory: Self.ax3)
        TapTargetMeasurement.assertScreenRendered(.diaryDetail, in: app)

        let moreButton = app.buttons["更多操作"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 10))
        moreButton.tap()

        let reportRow = app.buttons["檢舉這則內容"]
        let blockRow = app.buttons["封鎖這位成員"]
        let removeRow = app.buttons["移除這則內容"]
        let cancelButton = app.buttons["取消"]
        for element in [reportRow, blockRow, removeRow, cancelButton] {
            XCTAssertTrue(element.waitForExistence(timeout: 10), "AX3 下所有列都應該存在於畫面樹")
        }
        scrollUntilAllHittable([reportRow, blockRow, removeRow, cancelButton], in: app)

        assertNoOverlap([reportRow, blockRow, removeRow, cancelButton])
    }

    func testReportReasonSheet_ax3_allReasonsReachableAndSubmitWorks() {
        let app = TapTargetMeasurement.launch(.diaryDetail, contentSizeCategory: Self.ax3)
        TapTargetMeasurement.assertScreenRendered(.diaryDetail, in: app)

        app.buttons["更多操作"].tap()
        let reportRow = app.buttons["檢舉這則內容"]
        XCTAssertTrue(reportRow.waitForExistence(timeout: 10))
        reportRow.tap()

        let reasons = ["色情或猥褻內容", "騷擾、霸凌或恐嚇", "歧視或仇恨言論", "侵害隱私或未經同意的內容", "詐騙或垃圾訊息", "其他"]
        let reasonButtons = reasons.map { app.buttons[$0] }
        for button in reasonButtons {
            XCTAssertTrue(button.waitForExistence(timeout: 10), "六個原因列在 AX3 下都應該存在")
        }
        scrollUntilAllHittable(reasonButtons, in: app)

        let lastReason = reasonButtons[reasons.count - 1]
        XCTAssertTrue(lastReason.isHittable, "捲到底之後最後一個原因（「其他」）應該可以點到")
        lastReason.tap()

        let submitButton = app.buttons["送出"]
        scrollUntilAllHittable([submitButton], in: app)
        XCTAssertTrue(submitButton.isHittable && submitButton.isEnabled, "選完原因後送出鈕在 AX3 下仍要可觸達")
        submitButton.tap()

        XCTAssertTrue(
            app.staticTexts["已送出，家庭管理者會處理"].waitForExistence(timeout: 10),
            "AX3 下送出後一樣要能看到 05c"
        )
    }

    // MARK: - Helpers

    /// 同 `DeleteConfirmationAX3UITests.scrollUntilHittable`（同檔案樹不同 target 無法共用
    /// private 方法，這裡另寫一份最小版）：對整個 app 做 `swipeUp`，直到所有給定元素都
    /// `isHittable` 或連續兩次捲動位置沒有變化（判定捲到底，避免無限迴圈）。
    private func scrollUntilAllHittable(_ elements: [XCUIElement], in app: XCUIApplication, maxAttempts: Int = 6) {
        var previousYs: [CGFloat] = []
        for _ in 0..<maxAttempts {
            if elements.allSatisfy(\.isHittable) { return }
            let currentYs = elements.map { $0.frame.minY }
            if currentYs == previousYs { return }
            previousYs = currentYs
            app.swipeUp()
        }
    }

    /// 用 frame 交集判斷任兩個元素是否重疊——同 `DeleteConfirmationAX3UITests
    /// .assertButtonsReachableAndDoNotOverlap` 的既有手法，比單純比較 y 座標更不受版面假設
    /// 影響。只比對真的 hittable（在畫面上）的元素，捲動裁掉、不在畫面上的元素本來就不該納入
    /// 重疊判斷。
    private func assertNoOverlap(_ elements: [XCUIElement], file: StaticString = #filePath, line: UInt = #line) {
        let visible = elements.filter(\.isHittable)
        for firstIndex in 0..<visible.count {
            for secondIndex in (firstIndex + 1)..<visible.count {
                let first = visible[firstIndex]
                let second = visible[secondIndex]
                XCTAssertFalse(
                    first.frame.intersects(second.frame),
                    "AX3 下「\(first.label)」與「\(second.label)」不應該重疊：\(first.frame) vs \(second.frame)",
                    file: file, line: line
                )
            }
        }
    }
}

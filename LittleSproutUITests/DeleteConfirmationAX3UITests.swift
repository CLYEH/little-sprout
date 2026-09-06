import XCTest

/// LS-190 R2（merge-review R1 B1 blocker 的釘樁測試）：AX3（`accessibility-extra-large`）下
/// `DeleteConfirmationSheet` 的 IN-1 文案（「這個動作目前無法在 App 內復原。」）必須可達
/// （捲動後 `exists && isHittable`），兩顆按鈕不得重疊——`tap-target-check.sh`／
/// `TapTargetMeasurement.launch` 一律用一般字級（`UICTContentSizeCategoryL`），這個缺陷本來
/// 對它是隱形的，靠這支測試補一個放大字級的機械釘樁。
@MainActor
final class DeleteConfirmationAX3UITests: XCTestCase {
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    func testDeleteDiaryConfirmation_ax3_bodyTextReachableAndButtonsDoNotOverlap() {
        let app = TapTargetMeasurement.launch(.deleteDiaryConfirmation, contentSizeCategory: Self.ax3)
        TapTargetMeasurement.assertScreenRendered(.deleteDiaryConfirmation, in: app)

        let bodyText = app.staticTexts[
            "這篇日記會從時間軸移除，家人也看不到；裡面附的照片不會被刪除，之後還能在相簿看到。這個動作目前無法在 App 內復原。"
        ]
        XCTAssertTrue(
            bodyText.waitForExistence(timeout: 10),
            "IN-1 那句「這個動作目前無法在 App 內復原」必須存在於畫面樹，不能被截斷消失（merge-review R1 B1）"
        )
        if !bodyText.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(bodyText.isHittable, "捲動後應該能看到／點到完整內文（含 IN-1 那句），不是被 sheet 高度裁掉")

        assertButtonsReachableAndDoNotOverlap(in: app, confirmLabel: "刪除這篇日記")
    }

    func testDeleteCommentConfirmation_ax3_bodyTextReachableAndButtonsDoNotOverlap() {
        let app = TapTargetMeasurement.launch(.deleteCommentConfirmation, contentSizeCategory: Self.ax3)
        TapTargetMeasurement.assertScreenRendered(.deleteCommentConfirmation, in: app)

        let bodyText = app.staticTexts["這則留言刪除後，家人就看不到了。這個動作目前無法在 App 內復原。"]
        XCTAssertTrue(
            bodyText.waitForExistence(timeout: 10),
            "IN-1 那句「這個動作目前無法在 App 內復原」必須存在於畫面樹，不能被截斷消失（merge-review R1 B1）"
        )
        if !bodyText.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(bodyText.isHittable, "捲動後應該能看到／點到完整內文（含 IN-1 那句），不是被 sheet 高度裁掉")

        assertButtonsReachableAndDoNotOverlap(in: app, confirmLabel: "刪除這則留言")
    }

    /// 「兩顆鈕不重疊」（merge-review R1 B1 驗收要求）——按鈕釘在 `ScrollView` 之外（見
    /// `DeleteConfirmationSheet.body`），任何字級下都要各自維持 `minHeight`，不會因為內文被
    /// 夾擠而擠在一起。用 frame 交集（不是單純比較 y 座標）判斷，比較不受版面座標系假設影響。
    private func assertButtonsReachableAndDoNotOverlap(in app: XCUIApplication, confirmLabel: String) {
        let confirmButton = app.buttons[confirmLabel]
        let cancelButton = app.buttons["取消"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmButton.isHittable, "確認鈕釘在 ScrollView 之外，任何字級下都應該可達")
        XCTAssertTrue(cancelButton.isHittable, "取消鈕釘在 ScrollView 之外，任何字級下都應該可達")
        XCTAssertGreaterThanOrEqual(confirmButton.frame.height, TapTargetMeasurement.minSide)
        XCTAssertGreaterThanOrEqual(cancelButton.frame.height, TapTargetMeasurement.minSide)
        XCTAssertFalse(
            confirmButton.frame.intersects(cancelButton.frame),
            "AX3 下兩顆鈕不應該重疊：\(confirmButton.frame) vs \(cancelButton.frame)"
        )
    }
}

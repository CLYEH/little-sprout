import XCTest

/// LS-190 R2（merge-review R1 B1 blocker 的釘樁測試）：AX3（`accessibility-extra-large`）下
/// `DeleteConfirmationSheet` 的 IN-1 文案（「這個動作目前無法在 App 內復原。」）必須可達
/// （捲動後 `exists && isHittable`），兩顆按鈕不得重疊——`tap-target-check.sh`／
/// `TapTargetMeasurement.launch` 一律用一般字級（`UICTContentSizeCategoryL`），這個缺陷本來
/// 對它是隱形的，靠這支測試補一個放大字級的機械釘樁。
@MainActor
final class DeleteConfirmationAX3UITests: XCTestCase {
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"
    private static let large = "UICTContentSizeCategoryL"
    private static let diaryBodyText =
        "這篇日記會從時間軸移除，家人也看不到；裡面附的照片不會被刪除，之後還能在相簿看到。這個動作目前無法在 App 內復原。"
    private static let commentBodyText = "這則留言刪除後，家人就看不到了。這個動作目前無法在 App 內復原。"

    func testDeleteDiaryConfirmation_ax3_bodyTextReachableAndButtonsDoNotOverlap() {
        let baselineHeight = measureBodyTextHeight(
            .deleteDiaryConfirmation, contentSizeCategory: Self.large, bodyText: Self.diaryBodyText
        )

        let app = TapTargetMeasurement.launch(.deleteDiaryConfirmation, contentSizeCategory: Self.ax3)
        TapTargetMeasurement.assertScreenRendered(.deleteDiaryConfirmation, in: app)

        let bodyText = app.staticTexts[Self.diaryBodyText]
        XCTAssertTrue(
            bodyText.waitForExistence(timeout: 10),
            "IN-1 那句「這個動作目前無法在 App 內復原」必須存在於畫面樹，不能被截斷消失（merge-review R1 B1）"
        )
        assertContentSizeActuallyScaled(bodyText.frame.height, baselineHeight: baselineHeight)
        if !bodyText.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(bodyText.isHittable, "捲動後應該能看到／點到完整內文（含 IN-1 那句），不是被 sheet 高度裁掉")

        assertButtonsReachableAndDoNotOverlap(in: app, confirmLabel: "刪除這篇日記")
    }

    func testDeleteCommentConfirmation_ax3_bodyTextReachableAndButtonsDoNotOverlap() {
        let baselineHeight = measureBodyTextHeight(
            .deleteCommentConfirmation, contentSizeCategory: Self.large, bodyText: Self.commentBodyText
        )

        let app = TapTargetMeasurement.launch(.deleteCommentConfirmation, contentSizeCategory: Self.ax3)
        TapTargetMeasurement.assertScreenRendered(.deleteCommentConfirmation, in: app)

        let bodyText = app.staticTexts[Self.commentBodyText]
        XCTAssertTrue(
            bodyText.waitForExistence(timeout: 10),
            "IN-1 那句「這個動作目前無法在 App 內復原」必須存在於畫面樹，不能被截斷消失（merge-review R1 B1）"
        )
        assertContentSizeActuallyScaled(bodyText.frame.height, baselineHeight: baselineHeight)
        if !bodyText.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(bodyText.isHittable, "捲動後應該能看到／點到完整內文（含 IN-1 那句），不是被 sheet 高度裁掉")

        assertButtonsReachableAndDoNotOverlap(in: app, confirmLabel: "刪除這則留言")
    }

    /// merge-review R1 comment `24fc12db` i3：`launchArguments`／`launchEnvironment` 哪個真的
    /// 生效不是靠讀程式碼能確定的事（UIKit 內部行為），這支測試本身必須先證明「這次真的是在放大
    /// 字級下跑」，不能只靠沒有斷言失敗就當作字級有生效——起獨立一次 app 啟動量同一段文字在一般
    /// 字級（`UICTContentSizeCategoryL`）下的高度當基準，AX3 應該明顯更高（`.appFont(.note)`
    /// 這種本文字級在 AX3 下的縮放係數遠大於 1.3，這裡用 1.3 當保守下限，容許量測誤差但仍能
    /// 抓到「其實完全沒放大」的情況）。
    private func measureBodyTextHeight(
        _ screen: TapTargetGateScreenName, contentSizeCategory: String, bodyText: String
    ) -> CGFloat {
        let app = TapTargetMeasurement.launch(screen, contentSizeCategory: contentSizeCategory)
        TapTargetMeasurement.assertScreenRendered(screen, in: app)
        let element = app.staticTexts[bodyText]
        XCTAssertTrue(element.waitForExistence(timeout: 10), "量測基準高度時找不到內文「\(bodyText)」")
        let height = element.frame.height
        app.terminate()
        return height
    }

    private func assertContentSizeActuallyScaled(_ ax3Height: CGFloat, baselineHeight: CGFloat) {
        XCTAssertGreaterThan(
            ax3Height, baselineHeight * 1.3,
            "AX3 內文高度（\(ax3Height)pt）應該明顯大於一般字級基準（\(baselineHeight)pt）的 1.3 倍——" +
            "沒放大代表 launchArguments 設定字級沒有生效（merge-review R1 comment 24fc12db i3），" +
            "這支測試本身就是假綠，不是本票驗收條件真的通過"
        )
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

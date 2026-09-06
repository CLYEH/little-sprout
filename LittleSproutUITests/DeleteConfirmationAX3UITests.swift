import XCTest

/// LS-190 R2（merge-review R1 B1 blocker 的釘樁測試）：AX3（`accessibility-extra-large`）下
/// `DeleteConfirmationSheet` 的 IN-1 文案（「這個動作目前無法在 App 內復原。」）必須可達
/// （捲動後 `exists && isHittable`），兩顆按鈕不得重疊——`tap-target-check.sh`／
/// `TapTargetMeasurement.launch` 一律用一般字級（`UICTContentSizeCategoryL`），這個缺陷本來
/// 對它是隱形的，靠這支測試補一個放大字級的機械釘樁。
///
/// **LS-190 R3（merge-review R2 M2 major）**：R2 版的三道斷言全部抓不到 R1 那個缺陷——
/// reviewer 把 sheet 改回 R1 的缺陷結構（`ScrollView` 換回 `Group`、`.presentationDetents(
/// [.medium, .large])` 換回 `.presentationDetents([.height(420)])`）重跑，兩案仍然全綠：
/// (1) `staticTexts[完整字串].exists`——SwiftUI `Text` 就算視覺上被截斷，a11y label 仍是完整
/// 字串，永遠 `true`；(2) `isHittable`——元素只要有一部分在螢幕上就是 `true`，截斷版也是
/// `true`；(3) `> baseline × 1.3`——截斷版的比值是 1.448，正確版是 4.34，`1.3` 這個門檻同時
/// 放行兩者，只證明「字級有放大」，不證明「內文行數沒被吃掉」。這裡改成兩件事都做：門檻拉高到
/// `3.0`（見 `assertBodyTextNotTruncated` 文件註解）＋額外斷言「畫面上真的有一個可捲動的
/// `ScrollView`」（截斷版把 `ScrollView` 換成 `Group`，這個元素直接消失，是比高度倍數更直接
/// 的結構性訊號，不受量測誤差影響）。`swipeUp()` 也從「只做一次」改成迴圈捲到底（AX5 需要多次
/// 才能捲到 IN-1 整句，見 `scrollUntilHittable` 文件註解）。
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
        assertScrollViewExists(in: app)
        assertBodyTextNotTruncated(bodyText.frame.height, baselineHeight: baselineHeight)
        scrollUntilHittable(bodyText, in: app)
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
        assertScrollViewExists(in: app)
        assertBodyTextNotTruncated(bodyText.frame.height, baselineHeight: baselineHeight)
        scrollUntilHittable(bodyText, in: app)
        XCTAssertTrue(bodyText.isHittable, "捲動後應該能看到／點到完整內文（含 IN-1 那句），不是被 sheet 高度裁掉")

        assertButtonsReachableAndDoNotOverlap(in: app, confirmLabel: "刪除這則留言")
    }

    /// LS-210 merge-review R1 comment `24fc12db` i3：`launchArguments`／`launchEnvironment`
    /// 哪個真的生效不是靠讀程式碼能確定的事（UIKit 內部行為），這支測試本身必須先證明「這次真的
    /// 是在放大字級下跑」——起獨立一次 app 啟動量同一段文字在一般字級（`UICTContentSizeCategoryL`）
    /// 下的高度當基準。
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

    /// merge-review R2 M2：畫面上必須真的有一個可捲動的 `ScrollView`（`DeleteConfirmationSheet
    /// .body` 的內文放在 `ScrollView` 裡，見該檔文件註解）——R1 的缺陷結構把它換成 `Group`，
    /// 這個元素會直接從畫面樹消失。這是比下面的高度倍數更直接的結構性訊號：`Group` 版即使內文
    /// 因為被固定高度的容器裁切、量出比一般字級「高一點」的 frame（reviewer 實測比值 1.448），
    /// 依然沒有一個真正的 `ScrollView`。
    private func assertScrollViewExists(in app: XCUIApplication) {
        XCTAssertTrue(
            app.scrollViews.firstMatch.waitForExistence(timeout: 5),
            "畫面上找不到可捲動的 ScrollView——內文可能被裝在固定高度的容器（例如 Group＋" +
            "`.presentationDetents([.height(_)])`）裡，超出高度的內容會被裁掉而不是可以捲動看到"
        )
    }

    /// merge-review R2 M2：R2 版門檻（`baseline × 1.3`）測的是「字級有沒有放大」，不是這支測試
    /// 真正要保證的「內文行數有沒有被吃掉」——reviewer 把 sheet 改回 R1 的缺陷結構（`Group`＋
    /// 固定 `.height(420)`，內文因此被裁成 1～2 行）重跑，量到的比值是 1.448，仍然通過
    /// `> 1.3`；同一次改動下，正確版（`ScrollView`，內文完整 4～5 行）量到的比值是 4.34。兩者
    /// 中間有一段清楚的空檔，這裡把門檻拉到 `3.0`——量到 `≤ 3.0` 代表内文很可能被裁成只剩一兩
    /// 行，不是「字級不夠大」的問題。
    private func assertBodyTextNotTruncated(_ ax3Height: CGFloat, baselineHeight: CGFloat) {
        XCTAssertGreaterThan(
            ax3Height, baselineHeight * 3.0,
            "AX3 內文高度（\(ax3Height)pt）應該大於一般字級基準（\(baselineHeight)pt）的 3 倍——" +
            "這個倍數驗證的是「內文行數沒有被吃掉」（完整內文在 AX3 下應該是 4～5 行），不是" +
            "「字級有沒有放大」（截斷成 1～2 行的版本也會比基準高，但量到的倍數落在 3.0 以下，" +
            "merge-review R2 M2 major）"
        )
    }

    /// merge-review R2 M2 附帶事項：`swipeUp()` 只做一次在 AX5 下不夠——reviewer 實測「捲到
    /// IN-1 整句可見」在 AX5 需要三次才夠。改成迴圈捲到 `isHittable` 或連續捲動兩次高度都沒有
    /// 變化（判定捲到底，避免卡在螢幕上其實沒有更多內容可捲時無限迴圈）。上限 6 次純粹是安全
    /// 帽，正常情況下 AX5 三次、AX3 通常不需要捲動就會用到。
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        var previousMinY: CGFloat?
        for _ in 0..<6 {
            if element.isHittable { return }
            let minY = element.frame.minY
            if let previousMinY, previousMinY == minY {
                return
            }
            previousMinY = minY
            app.swipeUp()
        }
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

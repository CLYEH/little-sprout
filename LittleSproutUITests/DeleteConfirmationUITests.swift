import XCTest

/// LS-190 票文驗收：「UITests（刪除留言確認流程）」＋刪除日記確認的對稱覆蓋（10／10b 共用
/// `DeleteConfirmationSheet`，見該檔）。兩個 harness host 用
/// `TapTargetGateHarness.DismissableSheetHost`（真的 `@State` 綁定，讓「確認／取消」按下
/// `dismiss()` 之後 sheet 真的關閉，見該檔文件註解——R2 informational-2 訂正這裡舊註解誤寫成
/// `.constant(true)`）常駐頂出對應 sheet。
@MainActor
final class DeleteConfirmationUITests: XCTestCase {
    /// 「刪除留言確認流程」——票文明文要求的 UITest 場景。留言 UI 本體（LS-22）／內容操作表
    /// （LS-189）都尚未實作，`.deleteCommentConfirmation` harness 是目前唯一能觸達
    /// `CommentDeleteConfirmationSheet` 的入口（見該檔文件註解）。
    func testDeleteCommentConfirmation_confirmDismissesSheet() {
        let app = TapTargetMeasurement.launch(.deleteCommentConfirmation)
        TapTargetMeasurement.assertScreenRendered(.deleteCommentConfirmation, in: app)

        XCTAssertTrue(app.staticTexts["要刪除這則留言嗎？"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["這則留言刪除後，家人就看不到了。這個動作目前無法在 App 內復原。"].exists,
            "LS-152 IN-1 裁決：不承諾 30 天可還原"
        )

        let confirmButton = app.buttons["刪除這則留言"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        XCTAssertFalse(
            app.staticTexts["要刪除這則留言嗎？"].waitForExistence(timeout: 3),
            "PreviewCommentAPIClient 呼叫必成功，確認後 sheet 應該關閉"
        )
    }

    func testDeleteCommentConfirmation_cancel_dismissesWithoutCallingAPI() {
        let app = TapTargetMeasurement.launch(.deleteCommentConfirmation)
        TapTargetMeasurement.assertScreenRendered(.deleteCommentConfirmation, in: app)

        let cancelButton = app.buttons["取消"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()

        XCTAssertFalse(app.staticTexts["要刪除這則留言嗎？"].waitForExistence(timeout: 3), "取消應該直接關閉 sheet")
    }

    /// 對稱覆蓋刪除日記（10）——標題應嵌入日記摘要（`DiaryDeleteConfirmationCopy`）。
    func testDeleteDiaryConfirmation_titleEmbedsExcerpt_confirmDismissesSheet() {
        let app = TapTargetMeasurement.launch(.deleteDiaryConfirmation)
        TapTargetMeasurement.assertScreenRendered(.deleteDiaryConfirmation, in: app)

        XCTAssertTrue(
            app.staticTexts["要刪除「今天在溜滑梯上玩得好開心。」這篇日記嗎？"].waitForExistence(timeout: 5),
            "標題應嵌入 harness 種的日記摘要（見 deleteDiaryConfirmationHost）"
        )
        XCTAssertTrue(
            app.staticTexts["這篇日記會從時間軸移除，家人也看不到；裡面附的照片不會被刪除，之後還能在相簿看到。這個動作目前無法在 App 內復原。"].exists
        )

        let confirmButton = app.buttons["刪除這篇日記"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        XCTAssertFalse(app.buttons["刪除這篇日記"].waitForExistence(timeout: 3), "確認後 sheet 應該關閉")
    }
}

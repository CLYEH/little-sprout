import XCTest

/// LS-241 票文驗收：詳情頁點留言鈕開 sheet——日記詳情頁的互動列（LS-216 `InteractionRow`，
/// 換掉 LS-126 的「留言功能即將推出」占位）`onOpenComments` 要真的開出 LS-218 的
/// `CommentsSheetView`（同 `TimelineView` 的三種卡片共用一套 `.sheet` 呈現）。用既有
/// `TapTargetGateHarness.diaryDetailHost`（`.diaryDetail`，`ContentActionsUITests` 既有 host，
/// 已種好 `familyStore.myFamily`，`InteractionRow.onOpenComments` 才不會因為
/// `familyStore.myFamily?.id == nil` 開出空白 sheet），不必另開新 harness screen。
@MainActor
final class DiaryDetailCommentsUITests: XCTestCase {
    func testCommentButton_opensCommentsSheet() {
        let app = TapTargetMeasurement.launch(.diaryDetail)
        TapTargetMeasurement.assertScreenRendered(.diaryDetail, in: app)

        let commentButton = app.buttons[
            QAAccessibilityID.interactionRowElement(kind: "diary", element: "commentButton")
        ]
        XCTAssertTrue(commentButton.waitForExistence(timeout: 10), "詳情頁應該有互動列的留言鈕")
        commentButton.tap()

        // `PreviewCommentAPIClient.listComments` 固定回傳空陣列（見該檔文件註解），開出的
        // `CommentsSheetView` 會落在空狀態——同 `CommentsSheetUITests
        // .testEmptyState_showsPlaceholderCopy_inputStillUsable` 斷言的同一句文案，用來確認
        // 真的是 `CommentsSheetView` 開出來，不是別的 sheet。
        XCTAssertTrue(
            app.staticTexts["還沒有人留言"].waitForExistence(timeout: 10),
            "點擊詳情頁留言鈕應該開出留言 sheet"
        )
    }
}

import XCTest

/// LS-241 票文驗收：詳情頁點留言鈕開 sheet——日記詳情頁的互動列（LS-216 `InteractionRow`，
/// 換掉 LS-126 的留言區占位文案，見 `DiaryDetailView` 文件註解）`onOpenComments` 要真的開出
/// LS-218 的 `CommentsSheetView`（同 `TimelineView` 的三種卡片共用一套 `.sheet` 呈現）。用既有
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

    /// LS-245（票文範圍 2，池 `7f77856c`）：留言 sheet 與「⋯」內容操作表原本各自用獨立的
    /// `@State` 呈現——收斂成單一 `DiaryDetailView.activeSheet` 之後，這裡驗證「連續觸發兩來源
    /// 仍能各自呈現」：先觸發留言 sheet、關閉，再觸發「⋯」，內容操作表要能正確呈現（不會因為
    /// 共用同一個 `@State` 而卡住或呈現錯的內容）。反過來的順序見
    /// `ContentActionsUITests.testDiaryDetail_moreButton_thenCommentButton_bothPresentCorrectly`
    /// （同一組情境，兩個檔案各自從「自己熟悉的來源先觸發」出發，互相補完兩個方向）。
    func testCommentButton_thenMoreButton_bothPresentCorrectly() {
        let app = TapTargetMeasurement.launch(.diaryDetail)
        TapTargetMeasurement.assertScreenRendered(.diaryDetail, in: app)

        let commentButton = app.buttons[
            QAAccessibilityID.interactionRowElement(kind: "diary", element: "commentButton")
        ]
        XCTAssertTrue(commentButton.waitForExistence(timeout: 10), "詳情頁應該有互動列的留言鈕")
        commentButton.tap()
        let emptyStateText = app.staticTexts["還沒有人留言"]
        XCTAssertTrue(emptyStateText.waitForExistence(timeout: 10), "應該先呈現留言 sheet")

        // `CommentsSheetView` 自畫 grabber（系統 `.presentationDragIndicator` 隱藏，同
        // `DeleteConfirmationSheet` 既有理由），沒有另外的「關閉」鈕——用系統 drag-to-dismiss
        // 手勢。從 Head 標題「留言」（`.isHeader`，非可捲動清單區域，不會被清單的捲動手勢吃掉）
        // 相對座標往下拖曳（同 LS-167 規約：sheet 內元件座標一律相對參照元件本身，不用絕對
        // 螢幕常數）。
        let sheetTitle = app.staticTexts["留言"].firstMatch
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "留言 sheet 應該有標題可以當拖曳起點")
        let dragStart = sheetTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(forDuration: 0.05, thenDragTo: dragStart.withOffset(CGVector(dx: 0, dy: 500)))
        XCTAssertTrue(emptyStateText.waitUntilGone(timeout: 5), "留言 sheet 應該已經關閉")

        let moreButton = app.buttons["更多操作"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5), "留言 sheet 關閉後應該回到詳情頁、看得到「更多操作」")
        moreButton.tap()

        XCTAssertTrue(
            app.staticTexts["「今天在溜滑梯上玩得好開心。」"].waitForExistence(timeout: 5),
            "接著觸發「⋯」應該正確呈現內容操作表——不應該因為剛才留言 sheet 用過同一個 activeSheet 而卡住"
        )
    }
}

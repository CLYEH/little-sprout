import XCTest

/// LS-218：留言 sheet 功能性 UITests（票文範圍 7）——空狀態、送出後列表更新、AX3。
@MainActor
final class CommentsSheetUITests: XCTestCase {
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    /// `TnxXE`——空白沖印品＋「還沒有人留言」／「第一個跟家人說說話吧」，輸入列仍可用。
    func testEmptyState_showsPlaceholderCopy_inputStillUsable() {
        let app = TapTargetMeasurement.launch(.commentsSheetEmpty)
        TapTargetMeasurement.assertScreenRendered(.commentsSheetEmpty, in: app)

        XCTAssertTrue(app.staticTexts["還沒有人留言"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["第一個跟家人說說話吧"].exists)
        XCTAssertTrue(app.staticTexts["0 則留言"].exists, "空狀態的 Head Count 應該顯示「0 則留言」")

        let field = app.textFields[QAAccessibilityID.commentInputField]
        XCTAssertTrue(field.exists, "空狀態下輸入列仍應可用（票文範圍 4：只有 LS026 才整張換掉含輸入列）")
        let sendButton = app.buttons[QAAccessibilityID.commentSendButton]
        XCTAssertTrue(sendButton.exists)
        XCTAssertFalse(sendButton.isEnabled, "空白內容時送出鈕應該 disabled")
    }

    /// 票文範圍 3：送出成功後清空輸入框並捲到底，新留言出現在清單裡。
    func testSend_appendsNewCommentToList_andClearsInput() {
        let app = TapTargetMeasurement.launch(.commentsSheet)
        TapTargetMeasurement.assertScreenRendered(.commentsSheet, in: app)

        let field = app.textFields[QAAccessibilityID.commentInputField]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let newCommentBody = "LS-218 UITest 送出的留言"
        field.typeText(newCommentBody)

        let sendButton = app.buttons[QAAccessibilityID.commentSendButton]
        let sendEnabledExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: sendButton
        )
        XCTAssertEqual(XCTWaiter().wait(for: [sendEnabledExpectation], timeout: 5), .completed)
        sendButton.tap()

        XCTAssertTrue(
            app.staticTexts[newCommentBody].waitForExistence(timeout: 10),
            "送出成功後新留言應該出現在清單裡"
        )
        // 送出成功後應清空輸入框——`TextField` 的 `value` 在空白時回報 placeholder 文字
        // 「留言...」，同 `LabeledTextField` 系列既有的空值判斷慣例。
        XCTAssertEqual(field.value as? String, "留言...", "送出成功後輸入框應該清空")
    }

    /// AX3 下清單、輸入列、送出鈕仍可觸達，彼此不重疊（硬規則：iOS 26.2+ sheet 內座標斷言用
    /// 相對參照，這裡改用「元素存在＋可觸達」而不是絕對座標）。
    func testAX3_inputRowAndCommentsRemainReachable() {
        let app = TapTargetMeasurement.launch(.commentsSheet, contentSizeCategory: Self.ax3)
        TapTargetMeasurement.assertScreenRendered(.commentsSheet, in: app)

        let field = app.textFields[QAAccessibilityID.commentInputField]
        let sendButton = app.buttons[QAAccessibilityID.commentSendButton]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(sendButton.exists)
        XCTAssertTrue(field.isHittable)
        XCTAssertTrue(sendButton.isHittable)
        XCTAssertFalse(
            field.frame.intersects(sendButton.frame.offsetBy(dx: 0, dy: -sendButton.frame.height)),
            "AX3 下輸入欄與送出鈕不應該重疊"
        )

        // 至少一則留言（`PopulatedCommentAPIClient` 種 3 則）在 AX3 下仍存在於畫面樹。
        XCTAssertTrue(
            app.staticTexts["已經在收拾了，明天見！"].waitForExistence(timeout: 10),
            "AX3 下留言內容仍應存在於畫面樹（可捲動觸達）"
        )
    }

    /// merge-review R1 m3：送出留言撞到 LS026（目標已刪）時，先前實作會同時彈「留言送出失敗」
    /// alert 又把整張 sheet 換成終態畫面——票文範圍 4 明確只要單一「關閉」鈕。這裡釘住修正後
    /// 只呈現終態、不疊 alert。
    func testSendTargetGone_showsOnlyTerminalState_noAlert() {
        let app = TapTargetMeasurement.launch(.commentsSheetSendTargetGone)
        TapTargetMeasurement.assertScreenRendered(.commentsSheetSendTargetGone, in: app)

        let field = app.textFields[QAAccessibilityID.commentInputField]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("這則留言送不出去")

        let sendButton = app.buttons[QAAccessibilityID.commentSendButton]
        let sendEnabledExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: sendButton
        )
        XCTAssertEqual(XCTWaiter().wait(for: [sendEnabledExpectation], timeout: 5), .completed)
        sendButton.tap()

        XCTAssertTrue(
            app.staticTexts["找不到這則內容"].waitForExistence(timeout: 10),
            "送出撞到 LS026 應該整張 sheet 換成終態"
        )
        XCTAssertTrue(app.buttons["關閉"].exists)
        XCTAssertFalse(
            app.alerts["留言送出失敗"].exists,
            "終態畫面已經說明「找不到這則內容」，不該再疊一層 alert"
        )
    }

    /// `DUyg3`——Owner 對別人的留言點下去只看到單一「移除這則留言」danger 列（不含檢舉／封鎖）
    /// ，選它導向的是既有 `CommentDeleteConfirmationSheet`（「要刪除這則留言嗎？」）而不是另開
    /// 一張 `OwnerRemoveContentConfirmSheet`（「要移除這則內容嗎？」）——見
    /// `ContentAction.removeCommentAsOwner` 文件註解「重要發現」。`commentsSheetHost` seed 的
    /// 3 則留言 authorID 皆與 owner 的 `viewerUserID` 不同，任一則都適用。
    func testOwnerTapsOthersComment_showsSingleRemoveRow_routesToCommentDeleteConfirmation() {
        let app = TapTargetMeasurement.launch(.commentsSheet)
        TapTargetMeasurement.assertScreenRendered(.commentsSheet, in: app)

        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'qa.comments.row.'")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        firstRow.tap()

        let removeRow = app.buttons["移除這則留言"]
        XCTAssertTrue(removeRow.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["檢舉這則內容"].exists, "DUyg3 稿面不含檢舉列")
        XCTAssertFalse(app.staticTexts["封鎖"].exists, "DUyg3 稿面不含封鎖列")
        removeRow.tap()

        XCTAssertTrue(
            app.staticTexts["要刪除這則留言嗎？"].waitForExistence(timeout: 10),
            "應該導向既有 CommentDeleteConfirmationSheet（LS-152 Qs7iE），不是另一張「要移除這則" +
            "內容嗎？」確認卡"
        )
        XCTAssertTrue(app.buttons["刪除這則留言"].exists)
    }
}

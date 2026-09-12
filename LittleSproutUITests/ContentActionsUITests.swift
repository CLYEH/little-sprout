import XCTest

/// LS-189 票文驗收：「UITests（長按開操作表 → 檢舉 → 已送出；自己的內容 → 刪除確認 sheet
/// 出現）」。`.diaryDetail`／`.diaryDetailOwnContent` harness 用 `TapTargetGateHarness
/// .diaryDetailHost`／`.diaryDetailOwnContentHost` 走完整鏈路（「⋯」→ 05 → 05b/05c 或 05e 或
/// 既有刪除確認），不是只測各張 sheet 各自獨立存在——同 `DeleteConfirmationUITests` 的既有慣例，
/// 每支測試都先 `assertScreenRendered` 確認 harness 真的生效。
@MainActor
final class ContentActionsUITests: XCTestCase {
    // MARK: - 05：內容操作表本身（別人的內容，viewer 是家庭管理者）

    func testDiaryDetail_moreButton_opensActionsSheetWithReportBlockRemove() {
        let app = TapTargetMeasurement.launch(.diaryDetail)
        TapTargetMeasurement.assertScreenRendered(.diaryDetail, in: app)

        let moreButton = app.buttons["更多操作"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5))
        moreButton.tap()

        XCTAssertTrue(
            app.staticTexts["「今天在溜滑梯上玩得好開心。」"].waitForExistence(timeout: 5),
            "Head Title 應顯示日記本文摘要（見 DiaryDeleteConfirmationCopy.excerpt）"
        )
        XCTAssertTrue(app.buttons["檢舉這則內容"].exists)
        // harness 沒有 seed familyStore.members，作者顯示名稱兜底成「這位成員」。
        XCTAssertTrue(app.buttons["封鎖這位成員"].exists)
        XCTAssertTrue(app.buttons["移除這則內容"].exists, "viewer 是家庭管理者，應該看得到「移除這則內容」")
    }

    func testDiaryDetail_actionsSheet_cancelDismissesWithoutOpeningAnySubSheet() {
        let app = TapTargetMeasurement.launch(.diaryDetail)
        TapTargetMeasurement.assertScreenRendered(.diaryDetail, in: app)

        app.buttons["更多操作"].tap()
        let cancelButton = app.buttons["取消"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()

        XCTAssertFalse(app.staticTexts["「今天在溜滑梯上玩得好開心。」"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["檢舉這則內容"].exists)
    }

    // MARK: - 05 → 05b → 05c：檢舉全鏈路

    func testDiaryDetail_reportFlow_endToEnd_showsReportSent() {
        let app = TapTargetMeasurement.launch(.diaryDetail)
        TapTargetMeasurement.assertScreenRendered(.diaryDetail, in: app)

        app.buttons["更多操作"].tap()
        let reportRow = app.buttons["檢舉這則內容"]
        XCTAssertTrue(reportRow.waitForExistence(timeout: 5))
        reportRow.tap()

        // 05b：檢舉原因單選——送出前應該是 disabled（尚未選任何原因）。
        XCTAssertTrue(app.staticTexts["檢舉這則內容"].waitForExistence(timeout: 5), "05b 也用同一句 Head Title")
        let reasonRow = app.buttons["騷擾、霸凌或恐嚇"]
        XCTAssertTrue(reasonRow.waitForExistence(timeout: 5))
        let submitButton = app.buttons["送出"]
        XCTAssertFalse(submitButton.isEnabled, "尚未選原因前，送出鈕應該是 disabled")
        reasonRow.tap()
        // LS-229（同 LS-230 決定性同步點修法）：`isEnabled` 由選原因後的狀態更新驅動，tap 後
        // 立即查詢是一次性快照，CI runner 負載高時會誤判失敗。改用 `XCTNSPredicateExpectation`
        // 正向等它變成 true。
        let submitEnabledExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: submitButton
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [submitEnabledExpectation], timeout: 5), .completed,
            "選了原因之後，送出鈕應該變成 enabled"
        )
        submitButton.tap()

        // 05c：已送出。
        XCTAssertTrue(
            app.staticTexts["已送出，家庭管理者會處理"].waitForExistence(timeout: 5),
            "PreviewSafetyAPIClient 呼叫必成功，應該接著顯示 05c"
        )
        XCTAssertTrue(app.staticTexts["我們與「陳家」的家庭管理者都收到這則檢舉了，會盡快處理。"].exists)

        let doneButton = app.buttons["完成"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()

        XCTAssertFalse(
            app.staticTexts["已送出，家庭管理者會處理"].waitForExistence(timeout: 3),
            "按下完成後 05c 應該關閉"
        )
    }

    func testDiaryDetail_reportFlow_cancelReasonSheet_doesNotSubmit() {
        let app = TapTargetMeasurement.launch(.diaryDetail)
        TapTargetMeasurement.assertScreenRendered(.diaryDetail, in: app)

        app.buttons["更多操作"].tap()
        app.buttons["檢舉這則內容"].waitForExistence(timeout: 5)
        app.buttons["檢舉這則內容"].tap()

        let cancelButton = app.buttons["取消"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()

        XCTAssertFalse(app.staticTexts["已送出，家庭管理者會處理"].waitForExistence(timeout: 3), "取消不應該送出檢舉")
    }

    // MARK: - 「更多操作」在 store 未就緒時應該是 disabled，不是靜默 no-op（LS-189 R2，
    // merge-review R1 m2）

    /// Mutation guard：若把 `isContentActionsReady` 改回只看 `diaryContent == nil`，這支測試
    /// 會紅（按鈕會是 enabled）。
    func testDiaryDetail_moreButton_disabledWhenRoleNotReady() {
        let app = TapTargetMeasurement.launch(.diaryDetailRoleNotReady)
        TapTargetMeasurement.assertScreenRendered(.diaryDetailRoleNotReady, in: app)

        let moreButton = app.buttons["更多操作"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5))
        XCTAssertFalse(
            moreButton.isEnabled, "childrenStore.myRole 還沒到齊時「更多操作」應該是 disabled，不是可點但沒反應"
        )
    }

    // MARK: - 05b：送出後拿到 LS026（跨家庭）——改顯示專屬文案＋單一「關閉」（LS-189 R2，
    // merge-review R1 B4）

    func testReportReasonSheet_targetGone_showsDedicatedMessageAndSingleCloseButton() {
        let app = TapTargetMeasurement.launch(.reportReasonSheetTargetGone)
        TapTargetMeasurement.assertScreenRendered(.reportReasonSheetTargetGone, in: app)

        let reasonRow = app.buttons["騷擾、霸凌或恐嚇"]
        XCTAssertTrue(reasonRow.waitForExistence(timeout: 5))
        reasonRow.tap()
        let submitButton = app.buttons["送出"]
        // LS-229（同上一處、同 LS-230 決定性同步點修法）：改用 `XCTNSPredicateExpectation` 正向
        // 等 `isEnabled` 變成 true，不再是 tap 後立即查詢的一次性快照。
        let submitEnabledExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: submitButton
        )
        XCTAssertEqual(XCTWaiter().wait(for: [submitEnabledExpectation], timeout: 5), .completed)
        submitButton.tap()

        XCTAssertTrue(
            app.staticTexts["這則內容已經不存在了，無法檢舉。"].waitForExistence(timeout: 5),
            "LS026 應該顯示專屬文案，不是通用的「無法完成這個操作。」"
        )
        XCTAssertFalse(app.buttons["送出"].exists, "目標已經不存在，重試不會成功，不該再讓使用者看到「送出」鈕")
        XCTAssertFalse(app.buttons["取消"].exists, "應該換成單一「關閉」，不是「送出」＋「取消」兩顆")
        let closeButton = app.buttons["關閉"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        closeButton.tap()

        XCTAssertFalse(
            app.staticTexts["這則內容已經不存在了，無法檢舉。"].waitForExistence(timeout: 3),
            "按下關閉後 sheet 應該收起"
        )
    }

    // MARK: - 05 → 05d：封鎖

    func testDiaryDetail_blockFlow_confirmDismissesSheet() {
        let app = TapTargetMeasurement.launch(.diaryDetail)
        TapTargetMeasurement.assertScreenRendered(.diaryDetail, in: app)

        app.buttons["更多操作"].tap()
        let blockRow = app.buttons["封鎖這位成員"]
        XCTAssertTrue(blockRow.waitForExistence(timeout: 5))
        blockRow.tap()

        XCTAssertTrue(
            app.staticTexts["要封鎖「這位成員」嗎？"].waitForExistence(timeout: 5),
            "05d 標題應該帶入 05 動作列解析出的成員名稱"
        )
        let confirmButton = app.buttons["封鎖這位成員"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        XCTAssertFalse(app.staticTexts["要封鎖「這位成員」嗎？"].waitForExistence(timeout: 3), "確認後 05d 應該關閉")
    }

    // MARK: - 05 → 05e：Owner 移除內容——成功後本地移除＋日記詳情變成「找不到這篇日記」

    func testDiaryDetail_removeAsOwnerFlow_removesEntryLocally() {
        let app = TapTargetMeasurement.launch(.diaryDetail)
        TapTargetMeasurement.assertScreenRendered(.diaryDetail, in: app)

        app.buttons["更多操作"].tap()
        let removeRow = app.buttons["移除這則內容"]
        XCTAssertTrue(removeRow.waitForExistence(timeout: 5))
        removeRow.tap()

        XCTAssertTrue(app.staticTexts["要移除這則內容嗎？"].waitForExistence(timeout: 5))
        let confirmButton = app.buttons["移除這則內容"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        // `contentRemoved()`：`timelineStore.removeDiaryEntryLocally` 把這篇日記從
        // `timelineStore.entries` 移除，`DiaryDetailView.entry` 變 nil，畫面切到
        // `missingOrLoadingState` 的 `ContentUnavailableView`。
        XCTAssertTrue(
            app.staticTexts["找不到這篇日記"].waitForExistence(timeout: 5),
            "移除成功後應該本地立即反映——這篇日記不再存在於 timelineStore"
        )
    }

    // MARK: - 05 → 刪除（自己的內容）：既有 DiaryDeleteConfirmationSheet 接手

    func testDiaryDetailOwnContent_moreButton_onlyShowsDelete() {
        let app = TapTargetMeasurement.launch(.diaryDetailOwnContent)
        TapTargetMeasurement.assertScreenRendered(.diaryDetailOwnContent, in: app)

        app.buttons["更多操作"].tap()

        XCTAssertTrue(app.buttons["刪除"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["檢舉這則內容"].exists, "自己的內容不該看到檢舉")
        XCTAssertFalse(app.buttons["移除這則內容"].exists, "自己的內容不該看到 Owner 移除")
    }

    func testDiaryDetailOwnContent_deleteRow_opensExistingDeleteConfirmationSheet() {
        let app = TapTargetMeasurement.launch(.diaryDetailOwnContent)
        TapTargetMeasurement.assertScreenRendered(.diaryDetailOwnContent, in: app)

        app.buttons["更多操作"].tap()
        let deleteRow = app.buttons["刪除"]
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 5))
        deleteRow.tap()

        // LS-190 既有 `DiaryDeleteConfirmationSheet`——標題嵌日記摘要。
        XCTAssertTrue(
            app.staticTexts["要刪除「今天在溜滑梯上玩得好開心。」這篇日記嗎？"].waitForExistence(timeout: 5),
            "操作表『刪除』應該接回既有的 DiaryDeleteConfirmationSheet（LS-190），不是另造一張"
        )

        let confirmButton = app.buttons["刪除這篇日記"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        XCTAssertTrue(
            app.staticTexts["找不到這篇日記"].waitForExistence(timeout: 5),
            "刪除成功後同樣本地立即移除（onDeleted 呼叫同一支 contentRemoved()）"
        )
    }

    // MARK: - 07b 空狀態（不經過 tap-target gate，見該檔 TapTargetGateTests 移除理由）

    func testReportInboxView_emptyState_showsPlaceholderMessage() {
        let app = TapTargetMeasurement.launch(.reportInboxEmpty)
        TapTargetMeasurement.assertScreenRendered(.reportInboxEmpty, in: app)

        XCTAssertTrue(app.staticTexts["「陳家」目前沒有待處理的檢舉。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["目前沒有需要處理的檢舉。有人送出檢舉時，會出現在這裡。"].exists)
    }

    // MARK: - 07 檢舉收件匣——「這則沒問題」把卡片從清單移除

    func testReportInboxView_noIssue_removesCardFromList() {
        let app = TapTargetMeasurement.launch(.reportInbox)
        TapTargetMeasurement.assertScreenRendered(.reportInbox, in: app)

        XCTAssertTrue(app.staticTexts["「這張照片真的很醜」"].waitForExistence(timeout: 5))
        let noIssueButton = app.buttons["這則沒問題"]
        XCTAssertTrue(noIssueButton.waitForExistence(timeout: 5))
        noIssueButton.tap()

        XCTAssertFalse(
            app.staticTexts["「這張照片真的很醜」"].waitForExistence(timeout: 3),
            "標成沒問題後，這張卡片應該從清單移除"
        )
        XCTAssertTrue(
            app.staticTexts["目前沒有需要處理的檢舉。有人送出檢舉時，會出現在這裡。"].waitForExistence(timeout: 5),
            "唯一一則處理完之後應該落回空狀態"
        )
    }

    // MARK: - 07 檢舉收件匣——「這則沒問題」失敗時錯誤訊息要顯示（LS-189 R2，merge-review R1 B1）

    /// Mutation guard：若把 `ReportInboxView.markNoIssue` 改回舊寫法（`actionError: AppError?`
    /// 跟 `resolvingReportID` 綁在一起、`defer { resolvingReportID = nil }` 蓋掉判斷條件），
    /// 卡片仍會留著（這個斷言不受影響），但錯誤文字永遠不會出現——這支測試會紅。
    func testReportInboxView_noIssue_failure_showsErrorMessage_cardStaysInList() {
        let app = TapTargetMeasurement.launch(.reportInboxResolveError)
        TapTargetMeasurement.assertScreenRendered(.reportInboxResolveError, in: app)

        XCTAssertTrue(app.staticTexts["「這張照片真的很醜」"].waitForExistence(timeout: 5))
        let noIssueButton = app.buttons["這則沒問題"]
        XCTAssertTrue(noIssueButton.waitForExistence(timeout: 5))
        noIssueButton.tap()

        // `ReportInboxView` 這裡沿用 `AppError.userFacingMessage` 的全域兜底文案（`.rejected`
        // 一律「無法完成這個操作。」，不看 `code`／`message` 關聯值，同 `AppError.swift` 既有
        // 設計）——本測試釘住的是「有沒有顯示」，不是「顯示哪一句」。
        XCTAssertTrue(
            app.staticTexts["無法完成這個操作。"].waitForExistence(timeout: 5),
            "失敗時應該顯示錯誤訊息，不是靜默恢復成沒事發生過"
        )
        XCTAssertTrue(
            app.staticTexts["「這張照片真的很醜」"].exists,
            "失敗不應該把卡片從清單移除——內容其實還在 pending"
        )
    }
}

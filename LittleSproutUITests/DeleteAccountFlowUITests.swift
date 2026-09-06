import XCTest

/// LS-193（票文驗收「UITests：一般成員走到 04e 取消不刪」）：用 `TapTargetGateHarness`
/// （`.deleteAccountGeneralMember`，`PreviewAccountAPIClient` 不打真網路）驅動 04a→04e 這整段
/// 互動路徑，不需要本機 Supabase 容器——真的呼叫 `delete_my_account()`／Edge Function 的兩帳號
/// 完整刪除留給手動模擬器驗證（見 handoff「已驗證」段，DoD 第 3 條）。
///
/// **一律從 `.deleteAccountGeneralMember` 進場，不直接用 `.deleteAccountFinalConfirm`
/// 量測 04e→04f→04g 的轉場**：`TapTargetGateHarness.deleteAccountFinalConfirmHost` 直接掛
/// `FinalDeleteConfirmView` 這個子畫面（純粹為了 tap-target 量測，見該檔文件註解），不經過
/// `DeleteAccountFlowView` 的 `content` 路由開關——`model.step` 變成 `.inProgress`／
/// `.completed` 時沒有任何容器會把畫面換成 `DeletionInProgressView`／`DeletionCompletedView`，
/// 這裡量到的會是「已成功呼叫 `confirmDeletion()`，但畫面沒有路由器可以切換」的假陰性，不是
/// 真正的產品行為（實測踩過一次，見 PR body mutation 記錄）。從 `.deleteAccountGeneralMember`
/// 進場走完整條 `DeleteAccountFlowView` 才是使用者實際會走的路徑。
@MainActor
final class DeleteAccountFlowUITests: XCTestCase {
    private func launchAtGeneralMemberAndProceedToFinalConfirm() -> XCUIApplication {
        let app = TapTargetMeasurement.launch(.deleteAccountGeneralMember)
        TapTargetMeasurement.assertScreenRendered(.deleteAccountGeneralMember, in: app)
        app.buttons["繼續刪除帳號"].tap()
        XCTAssertTrue(app.staticTexts["最後確認"].waitForExistence(timeout: 5), "應該經由 DeleteAccountFlowView 路由進到 04e")
        return app
    }

    func testGeneralMember_proceedsToFinalConfirm_cancelReturnsWithoutDeleting() {
        let app = TapTargetMeasurement.launch(.deleteAccountGeneralMember)
        TapTargetMeasurement.assertScreenRendered(.deleteAccountGeneralMember, in: app)
        XCTAssertTrue(app.staticTexts["在你刪除帳號之前，請先看看接下來會發生什麼事。"].exists, "04a 應該顯示說明副標")

        app.buttons["繼續刪除帳號"].tap()

        XCTAssertTrue(app.staticTexts["最後確認"].waitForExistence(timeout: 5), "應該進到 04e 最終確認")
        XCTAssertTrue(
            app.staticTexts["這是刪除帳號前的最後一步。請在下面輸入「刪除帳號」四個字，確認你真的要這麼做。"].exists
        )

        app.buttons["取消"].tap()

        XCTAssertTrue(
            app.staticTexts["刪除帳號"].waitForExistence(timeout: 5),
            "取消應該退回 04a，不應該呼叫 delete_my_account()（PreviewAccountAPIClient 若被呼叫也只會假成功，" +
            "這裡驗證的是使用者從未被導去 04f/04g）"
        )
        XCTAssertFalse(app.staticTexts["正在刪除你的帳號…"].exists)
        XCTAssertFalse(app.staticTexts["帳號已刪除"].exists)
    }

    /// LS-152 Notes「十條-8」：輸入不符時顯示 hint 列，按鈕本身不變成不可點（不是驗證型
    /// disable）——這裡驗證「按下去但輸入不符」不會被靜默吞掉，也不會誤觸發刪除。
    func testFinalConfirm_mismatchedInput_showsHintAndDoesNotProceed() {
        let app = launchAtGeneralMemberAndProceedToFinalConfirm()
        let field = app.textFields[QAAccessibilityID.deleteAccountConfirmField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("我不確定")

        app.buttons["永久刪除帳號"].tap()

        XCTAssertTrue(
            app.staticTexts["請先在上面輸入「刪除帳號」四個字，才能繼續。"].waitForExistence(timeout: 5),
            "輸入不符時應該顯示提示列，不是靜默沒反應"
        )
        XCTAssertFalse(app.staticTexts["正在刪除你的帳號…"].exists, "輸入不符不該進到 04f")
    }

    /// 輸入正確才真的往下走（`PreviewAccountAPIClient` 固定成功，會一路到 04g）。鍵盤還開著時
    /// 直接點底下的按鈕在這台模擬器上實測會被鍵盤收合吃掉第一下，因此先點標題收鍵盤再點按鈕
    /// （同 `QADriver` 系列既有的「先確保鍵盤收起再操作下一步」處理方式）。
    func testFinalConfirm_matchingInput_proceedsThroughInProgressToCompleted() {
        let app = launchAtGeneralMemberAndProceedToFinalConfirm()
        let field = app.textFields[QAAccessibilityID.deleteAccountConfirmField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("刪除帳號")
        app.staticTexts["最後確認"].tap()

        app.buttons["永久刪除帳號"].tap()

        XCTAssertTrue(app.staticTexts["帳號已刪除"].waitForExistence(timeout: 10), "PreviewAccountAPIClient 固定成功，應該落在 04g")
    }
}

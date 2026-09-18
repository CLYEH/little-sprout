import XCTest

/// LS-166 票文驗收：「UITests（進入詳情、加入照片 → 佇列 sheet 出現、刪除確認流程）」。
///
/// PhotosPicker 本身刻意不真的 `tap()` 觸發（系統相簿選圖是另一個行程的 UI，同
/// `CreateChildAvatarFieldUITests` 文件註解點名的既有理由）——「加入照片 → 佇列 sheet 出現」
/// 這條真實端到端流程（多選 3 張 → 佇列到已完成）改在模擬器對本機容器的互動驗證階段用
/// mobile-mcp 手動走過，這裡驗證的是「按鈕存在、可點」與「更多／刪除確認」這類不依賴系統
/// 相簿 UI 的互動路徑。
@MainActor
final class AlbumDetailViewTests: XCTestCase {
    func testOwnerSeesBackButtonMoreMenuAndAddPhotosButton() {
        let app = TapTargetMeasurement.launch(.albumDetailOwner)
        TapTargetMeasurement.assertScreenRendered(.albumDetailOwner, in: app)

        XCTAssertTrue(app.buttons["相簿"].firstMatch.exists, "自畫返回鍵標籤應該是「相簿」")
        XCTAssertTrue(app.buttons["更多操作"].exists, "owner 視角應該看得到「更多」選單")
        XCTAssertTrue(app.buttons["加入照片"].exists, "Action Bar 應該有「加入照片」主鈕")
    }

    func testMemberDoesNotSeeMoreMenu() {
        let app = TapTargetMeasurement.launch(.albumDetailMember)
        TapTargetMeasurement.assertScreenRendered(.albumDetailMember, in: app)

        XCTAssertFalse(app.buttons["更多操作"].exists, "member 視角不該看到「更多」選單（Notes OHMPk）")
        XCTAssertTrue(app.buttons["相簿"].firstMatch.exists, "返回鍵不受角色影響，仍然存在")
    }

    func testBackButtonPopsToAlbumsList() {
        let app = TapTargetMeasurement.launch(.albumDetailOwner)
        TapTargetMeasurement.assertScreenRendered(.albumDetailOwner, in: app)

        app.buttons["相簿"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["上禮拜的動物園一日遊"].waitForExistence(timeout: 5), "返回後應該看到相簿列表卡片")
    }

    func testMoreMenuEditOpensEditAlbumSheet() {
        let app = TapTargetMeasurement.launch(.albumDetailOwner)
        TapTargetMeasurement.assertScreenRendered(.albumDetailOwner, in: app)

        app.buttons["更多操作"].tap()
        XCTAssertTrue(app.buttons["編輯相簿名稱"].waitForExistence(timeout: 5))
        app.buttons["編輯相簿名稱"].tap()

        XCTAssertTrue(app.staticTexts["編輯相簿名稱"].waitForExistence(timeout: 5), "應該開啟「編輯相簿名稱」sheet")
        XCTAssertTrue(app.buttons["儲存變更"].waitForExistence(timeout: 5))
    }

    func testMoreMenuDeleteOpensConfirmationSheet_cancelDismissesWithoutDeleting() {
        let app = TapTargetMeasurement.launch(.albumDetailOwner)
        TapTargetMeasurement.assertScreenRendered(.albumDetailOwner, in: app)

        app.buttons["更多操作"].tap()
        XCTAssertTrue(app.buttons["刪除相簿"].waitForExistence(timeout: 5))
        app.buttons["刪除相簿"].tap()

        XCTAssertTrue(
            app.staticTexts["要刪除「上禮拜的動物園一日遊」相簿嗎？"].waitForExistence(timeout: 5),
            "應該開啟刪除相簿確認 sheet"
        )
        app.buttons["取消"].tap()

        // 取消後應該回到詳情頁——「更多」選單仍在（沒有被 pop 回列表）。
        XCTAssertTrue(app.buttons["更多操作"].waitForExistence(timeout: 5))
    }

    /// merge-review R2 M1：Action Bar 版稿面（`ve8YN`／`xcGEY`／`iXdTJ`／`EZqDj`）instance
    /// 都是 `width:"fill_container"`——改 ref `ImportEntryButton`（hug-content pill）時把這個
    /// 滿版幾何弄丟了，動作帶從整條主鈕縮成置中小 pill。量 `XCUIElement.frame` 確認撐滿。
    func testAddPhotosBarButtonFillsActionBarWidth() {
        let app = TapTargetMeasurement.launch(.albumDetailOwner)
        TapTargetMeasurement.assertScreenRendered(.albumDetailOwner, in: app)

        let button = app.buttons["加入照片"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let windowWidth = app.windows.firstMatch.frame.width
        // `AppSpacing.screenPad`（24pt）字面值同步寫在這裡——UI test 跟 app target 分離
        // 行程，不能 `import LittleSprout` 引用（同 `DiaryCardVideoBadgeGeometryTests`
        // 既有理由）。
        let screenPad: CGFloat = 24
        XCTAssertGreaterThan(
            button.frame.width, windowWidth - screenPad * 2 - 1,
            "「加入照片」Action Bar 版應撐滿動作帶寬度（fill_container，merge-review R2 M1），"
                + "不是縮成 hug-content pill"
        )
    }
}

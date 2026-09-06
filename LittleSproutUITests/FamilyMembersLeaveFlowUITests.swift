import XCTest

/// LS-192 R3（merge-review R2 M-A／M2）：`FamilyMembersView.startLeaveFlow()` 依
/// `FamilyStore.leaveFlowCase` 分流到 `MustTransferOwnershipFirstView` 的哪個 `Content`
/// 只有單元測試覆蓋純函式輸入輸出（`FamilyStoreMembersTests`／`FamilyMemberActionVisibility
/// Tests`），沒有任何測試驗證 `FamilyMembersView` 真的把「退出家庭」按鈕接到
/// `.navigationDestination(item:)` 上、push 出正確的畫面——這支測試補這段真實導覽的機械覆蓋。
///
/// `TapTargetGateHarness.familyMembersHost` 固定 seed「自己（owner）＋一位一般成員、沒有其他
/// owner」，對應 `leaveFlowCase == .mustTransferFirst`，因此這裡驗證的是 03e 的
/// `.mustTransferFirst` 內容（標題／副標帶人數／Families Card／Footer 沉底，見 N2 修法）；
/// `.soleMember` 內容的正確性由 `resolveLeaveFlowCase` 的純函式單元測試＋mutation 覆蓋（見
/// `FamilyMemberActionVisibilityTests.test_resolveLeaveFlowCase_ownerSoleMember_soleMember`），
/// harness 目前的固定樣本無法在不影響 M8（tap-target 覆蓋兩位成員列）的前提下改成單人樣本，
/// 記入 handoff 風險欄。
@MainActor
final class FamilyMembersLeaveFlowUITests: XCTestCase {
    func testTappingLeaveButton_navigatesToMustTransferFirstPage_notSheet() {
        let app = TapTargetMeasurement.launch(.familyMembers)
        TapTargetMeasurement.assertScreenRendered(.familyMembers, in: app)

        app.buttons["退出家庭"].tap()

        XCTAssertTrue(
            app.staticTexts["需要先轉移家庭管理者身分"].waitForExistence(timeout: 5),
            "點「退出家庭」應該 push 進 MustTransferOwnershipFirstView 的 .mustTransferFirst 內容" +
            "（merge-review R1 M2：稿 sF5oA 是整頁 Nav Back，不是 sheet）"
        )
        let subtitlePredicate = NSPredicate(format: "label CONTAINS '家裡還有 1 位家人'")
        XCTAssertTrue(
            app.staticTexts.matching(subtitlePredicate).firstMatch.exists,
            "副標應該帶真實的其他成員數（harness 樣本是 1 位），不是稿面示意的固定數字"
        )
        XCTAssertTrue(app.buttons["返回設定"].exists, "Footer 只有「返回設定」一顆鈕")
        // 系統返回鈕存在＝真的是 push（NavigationStack 目的地），不是 sheet（sheet 沒有系統
        // 返回鈕，而是自己的取消/關閉鈕）——這是 M2 blocker 的核心區別，之前用 `.sheet` 誤判過。
        XCTAssertTrue(
            app.navigationBars.buttons.firstMatch.exists,
            "push 目的地應該有系統導覽列返回鈕"
        )
        // R3：merge-review R2 N1／N2 視覺對稿受阻於本輪 simctl 直接啟動無法前景化（同 R2 已
        // 記錄的環境限制）——附一張真實 XCUITest（不是靜態 simctl launch）拍的截圖，至少證明
        // Footer 確實沉到頁底（N2）、標題與副標渲染正確，供 handoff／PR body 佐證。
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        attachment.name = "LS-192-R3-mustTransferFirst"
        add(attachment)
    }

    /// R3（merge-review R2 N1）：`profileEditHost` 原本沒有 seed `ownerUserID`，
    /// `refreshProfile()` 的 m7 世代守門直接 return、渲染出空白 placeholder（頭像圈內無縮寫、
    /// 姓名欄空白）。`testProfileEditView`（`TapTargetGateTests`）只斷言三顆按鈕 ≥44pt，不會
    /// 抓到「內容是空的」——這裡直接斷言頭像的 accessibility label 帶著真實姓名，證明
    /// `.task` 真的查回了 `PreviewFamilyAPIClient.fetchMyProfile()` 的樣本值，不是空字串。
    func testProfileEditView_seedsOwnerUserID_avatarShowsRealName() {
        let app = TapTargetMeasurement.launch(.profileEdit)
        TapTargetMeasurement.assertScreenRendered(.profileEdit, in: app)

        let avatarPredicate = NSPredicate(format: "label == '陳美玲的大頭貼，點一下可以換照片'")
        let avatarElement = app.descendants(matching: .any).matching(avatarPredicate).firstMatch
        XCTAssertTrue(
            avatarElement.waitForExistence(timeout: 5),
            "N1：refreshProfile() 應該用 seed 的 ownerUserID 查回樣本 profile（displayName" +
            " 「陳美玲」），不是留在空白 placeholder（accessibility label 會變成「的大頭貼…」）"
        )
    }
}

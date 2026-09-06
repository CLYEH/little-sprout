import Foundation
@testable import LittleSprout
import XCTest

/// LS-193：04a／04b／04d 三分流純函式（重用 LS-192 `resolveLeaveFlowCase` 判斷本體，見
/// `classifyDeleteAccountFlow(membersState:ownerUserID:members:myFamily:)` 文件註解）＋04e
/// 確認詞比對。三分流測試風格對照 `FamilyMemberActionVisibilityTests.test_resolveLeaveFlowCase_*`。
///
/// **merge-review R1 M1 訂正**：舊版簽名 `classifyDeleteAccountFlow(for: LeaveFlowCase, myFamily:
/// Family?)` 已移除——`LeaveFlowCase`／`FamilyStore.leaveFlowCase` 對「members 為空」的處置是
/// 回 `.leave`，把這個當輸入等於把「還沒載完」跟「確定是一般成員」焊死成同一個結果，這正是
/// M1 抓到的缺陷（04d 唯一成員警告可能永遠不會出現）。新簽名直接吃 `membersState`／
/// `ownerUserID`／`members` 三個原始輸入，讓「載入中」「載入失敗」變成顯式分支。
final class DeleteAccountStepTests: XCTestCase {
    private var family: Family {
        Family(id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true)
    }

    private let myID = UUID()
    private let otherID = UUID()

    private func member(id: UUID, role: FamilyRole) -> FamilyMember {
        FamilyMember(userID: id, role: role, displayName: "測試成員", avatarURL: nil)
    }

    // MARK: - classifyDeleteAccountFlow（loading／failure／三個已載入分案）

    /// M1 核心釘樁：`ownerUserID` 是 nil（`syncOwner` 還沒跑，或 `FamilyStore.reset()` 之後）
    /// 時必須回 `.pending`，不能代打 `.generalMember`——這正是 R1 版被抓到的缺陷（PROBE-RESULT
    /// `before=generalMember … after=soleMember`）唯一的成因：R1 版 `leaveFlowCase` 對這個輸入
    /// 回 `.leave`。
    func test_classifyDeleteAccountFlow_ownerUserIDNil_pending() {
        let classification = classifyDeleteAccountFlow(
            membersState: .idle, ownerUserID: nil, members: [], myFamily: family
        )
        XCTAssertEqual(classification, .pending)
    }

    /// M1 核心釘樁之二：`ownerUserID` 有值，但 `members` 還沒載回（找不到自己）——同樣必須
    /// `.pending`，這是「`SettingsView` 補查 `listMembers` 還在飛」的真實時序窗口。
    func test_classifyDeleteAccountFlow_membersEmptyButOwnerIDKnown_pending() {
        let classification = classifyDeleteAccountFlow(
            membersState: .idle, ownerUserID: myID, members: [], myFamily: family
        )
        XCTAssertEqual(classification, .pending)
    }

    /// `membersState == .failure` 優先於其他輸入判定——即使 `members`／`ownerUserID` 剛好殘留
    /// 著上一次成功查詢的完整資料，只要最近一次查詢失敗就必須顯示可重試錯誤，不能沿用舊資料
    /// 靜默分流。
    func test_classifyDeleteAccountFlow_membersStateFailure_membersLoadFailed_takesPriorityOverStaleData() {
        let error = AppError.network(message: "offline")
        let classification = classifyDeleteAccountFlow(
            membersState: .failure(error),
            ownerUserID: myID,
            members: [member(id: myID, role: .owner)],
            myFamily: family
        )
        XCTAssertEqual(classification, .membersLoadFailed(error))
    }

    func test_classifyDeleteAccountFlow_leave_generalMember() {
        let classification = classifyDeleteAccountFlow(
            membersState: .success, ownerUserID: myID,
            members: [member(id: myID, role: .member), member(id: otherID, role: .owner)],
            myFamily: family
        )
        XCTAssertEqual(classification, .generalMember)
    }

    func test_classifyDeleteAccountFlow_mustTransferFirst_mustTransferOwnership() {
        let family = self.family

        let classification = classifyDeleteAccountFlow(
            membersState: .success, ownerUserID: myID,
            members: [member(id: myID, role: .owner), member(id: otherID, role: .member)],
            myFamily: family
        )

        XCTAssertEqual(classification, .mustTransferOwnership(
            families: [FamilyPendingTransfer(familyID: family.id, familyName: family.name)]
        ))
    }

    func test_classifyDeleteAccountFlow_soleMember_soleMember() {
        let classification = classifyDeleteAccountFlow(
            membersState: .success, ownerUserID: myID,
            members: [member(id: myID, role: .owner)],
            myFamily: family
        )
        XCTAssertEqual(classification, .soleMember)
    }

    /// 防禦性 fallback：理論上不會發生（分流都算完了 `myFamily` 沒理由還是 nil，見函式文件
    /// 註解）——mutation 測試需要一個可觀察的行為差異，這裡釘住「沒有家庭資料時
    /// `.mustTransferFirst` 退回 `.pending`（不是代打 `.generalMember`，那樣 04d 警告一樣會
    /// 消失）」這個明確選擇。
    func test_classifyDeleteAccountFlow_mustTransferFirst_noFamily_fallsBackToPending() {
        let classification = classifyDeleteAccountFlow(
            membersState: .success, ownerUserID: myID,
            members: [member(id: myID, role: .owner), member(id: otherID, role: .member)],
            myFamily: nil
        )
        XCTAssertEqual(classification, .pending)
    }

    // MARK: - DeleteAccountStep.showsNavigationBar

    func test_showsNavigationBar_trueForFinalConfirm() {
        XCTAssertTrue(DeleteAccountStep.finalConfirm(origin: .generalMember).showsNavigationBar)
    }

    func test_showsNavigationBar_falseForProgressCompletedFailed() {
        XCTAssertFalse(DeleteAccountStep.inProgress.showsNavigationBar)
        XCTAssertFalse(DeleteAccountStep.completed.showsNavigationBar)
        XCTAssertFalse(DeleteAccountStep.failed(.network(message: "offline")).showsNavigationBar)
    }

    // MARK: - DeleteAccountConfirmationPhrase（04e「輸入『刪除帳號』」比對）

    func test_confirmationPhrase_exactMatch_true() {
        XCTAssertTrue(DeleteAccountConfirmationPhrase.matches("刪除帳號"))
    }

    func test_confirmationPhrase_trimsWhitespaceOnly() {
        XCTAssertTrue(DeleteAccountConfirmationPhrase.matches("  刪除帳號  "))
    }

    func test_confirmationPhrase_mismatch_false() {
        XCTAssertFalse(DeleteAccountConfirmationPhrase.matches("刪除帳户"))
        XCTAssertFalse(DeleteAccountConfirmationPhrase.matches("刪除"))
        XCTAssertFalse(DeleteAccountConfirmationPhrase.matches(""))
    }
}

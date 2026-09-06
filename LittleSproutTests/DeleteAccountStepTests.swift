import Foundation
@testable import LittleSprout
import XCTest

/// LS-193：04a／04b／04d 三分流純函式（重用 LS-192 `LeaveFlowCase`，見
/// `classifyDeleteAccountFlow(for:myFamily:)` 文件註解）＋04e 確認詞比對。三分流測試風格對照
/// `FamilyMemberActionVisibilityTests.test_resolveLeaveFlowCase_*`。
final class DeleteAccountStepTests: XCTestCase {
    private var family: Family {
        Family(id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true)
    }

    // MARK: - classifyDeleteAccountFlow（三案）

    func test_classifyDeleteAccountFlow_leave_generalMember() {
        XCTAssertEqual(classifyDeleteAccountFlow(for: .leave, myFamily: family), .generalMember)
    }

    func test_classifyDeleteAccountFlow_mustTransferFirst_mustTransferOwnership() {
        let family = self.family

        let classification = classifyDeleteAccountFlow(for: .mustTransferFirst, myFamily: family)

        XCTAssertEqual(classification, .mustTransferOwnership(
            families: [FamilyPendingTransfer(familyID: family.id, familyName: family.name)]
        ))
    }

    func test_classifyDeleteAccountFlow_soleMember_soleMember() {
        XCTAssertEqual(classifyDeleteAccountFlow(for: .soleMember, myFamily: family), .soleMember)
    }

    /// 防禦性 fallback：理論上不會發生（見函式文件註解），mutation 測試需要一個可觀察的行為
    /// 差異，這裡釘住「沒有家庭資料時 `.mustTransferFirst` 退回 04a」這個明確選擇。
    func test_classifyDeleteAccountFlow_mustTransferFirst_noFamily_fallsBackToGeneralMember() {
        XCTAssertEqual(classifyDeleteAccountFlow(for: .mustTransferFirst, myFamily: nil), .generalMember)
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

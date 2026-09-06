import Foundation
@testable import LittleSprout
import XCTest

/// LS-193 merge-review R1 M3：`PendingAccountDeletion` 本機續傳旗標——每支測試用自己的隨機
/// `UUID`（`UserDefaults.standard` 是全域單例，用固定 UUID 會跟其他測試或前一次跑殘留的值
/// 互相干擾），並在結束時 `clear`，維持測試之間互不影響。
final class PendingAccountDeletionTests: XCTestCase {
    func test_isPending_neverMarked_false() {
        let userID = UUID()
        XCTAssertFalse(PendingAccountDeletion.isPending(userID: userID))
    }

    func test_markPending_thenIsPending_true() {
        let userID = UUID()
        defer { PendingAccountDeletion.clear(userID: userID) }

        PendingAccountDeletion.markPending(userID: userID)

        XCTAssertTrue(PendingAccountDeletion.isPending(userID: userID))
    }

    func test_clear_afterMarkPending_isPendingFalseAgain() {
        let userID = UUID()
        PendingAccountDeletion.markPending(userID: userID)
        XCTAssertTrue(PendingAccountDeletion.isPending(userID: userID), "前置：先確認真的標記成功")

        PendingAccountDeletion.clear(userID: userID)

        XCTAssertFalse(PendingAccountDeletion.isPending(userID: userID))
    }

    /// 用 `userID` 分 key——不同使用者的旗標互不影響（同一台裝置換帳號登入的既有場景）。
    func test_differentUserIDs_areIndependent() {
        let userA = UUID()
        let userB = UUID()
        defer { PendingAccountDeletion.clear(userID: userA) }

        PendingAccountDeletion.markPending(userID: userA)

        XCTAssertTrue(PendingAccountDeletion.isPending(userID: userA))
        XCTAssertFalse(PendingAccountDeletion.isPending(userID: userB))
    }
}

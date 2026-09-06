import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-193（LS-24 刪除帳號流程）：`DeleteAccountFlowModel` 狀態機——三分流（`classification`）
/// 即時讀 `FamilyStore` 現況（見 `DeleteAccountStepTests` 的純函式測試與
/// `DeleteAccountClassification` 文件註解），這裡測的是 04e→04f→04g/04h 的呼叫順序。
/// in-flight 防重複送出／`finishAndReturnToWelcome` 拆到
/// `DeleteAccountFlowModelRaceTests.swift`（同 `OTPVerificationModelLockoutTests.swift`
/// 從 `OTPVerificationModelTests.swift` 拆分的既有理由：SwiftLint `type_body_length`）。
@MainActor
final class DeleteAccountFlowModelTests: XCTestCase {
    let myID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    let otherID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

    /// 不是 `private`：`DeleteAccountFlowModelRaceTests.swift`（另一個檔案的 extension）需要
    /// 共用同一組工廠方法，同 `OTPVerificationModelTests.makeModel` 的既有理由。
    func makeMember(id: UUID, role: FamilyRole) -> FamilyMember {
        FamilyMember(userID: id, role: role, displayName: "測試成員", avatarURL: nil)
    }

    var family: Family {
        Family(id: UUID(), name: "陳家", createdBy: myID, createdAt: Date(), requireApproval: true)
    }

    /// SwiftLint `large_tuple` 擋裸 tuple（同 `StubFamilyAPIClient.CreateInviteCall` 的既有
    /// 理由）——`makeModel(...)` 需要回傳 model 與它牽動的五個 store 供各測試斷言。
    struct Fixture {
        let model: DeleteAccountFlowModel
        let familyStore: FamilyStore
        let authStore: AuthStore
        let childrenStore: ChildrenStore
        let timelineStore: TimelineStore
        let albumsStore: AlbumsStore
    }

    /// 預設佈置成「一般成員」（`.leave`）——大多數狀態機測試不在乎進場分流，只在乎
    /// `confirmDeletion()`／`recheckAfterTransfer()` 之後的行為，這裡給一個確定性的起點。
    func makeModel(
        accountAPIClient: AccountAPIClient = StubAccountAPIClient(),
        family: Family? = nil,
        members: [FamilyMember] = [],
        authStub: StubAuthService = StubAuthService()
    ) -> Fixture {
        let resolvedFamily = family ?? self.family
        let familyStore = FamilyStore.preview(withFamily: resolvedFamily)
        familyStore.seedOwnerUserIDForPreview(myID)
        if !members.isEmpty {
            familyStore.seedMembersForPreview(members)
        }
        let authStore = AuthStore(authService: authStub)
        let childrenStore = ChildrenStore.preview()
        let timelineStore = TimelineStore.preview()
        let albumsStore = AlbumsStore.preview()
        let model = DeleteAccountFlowModel(
            accountAPIClient: accountAPIClient, familyStore: familyStore, authStore: authStore,
            childrenStore: childrenStore, timelineStore: timelineStore, albumsStore: albumsStore
        )
        return Fixture(
            model: model, familyStore: familyStore, authStore: authStore,
            childrenStore: childrenStore, timelineStore: timelineStore, albumsStore: albumsStore
        )
    }

    // MARK: - classification 三分流（同 `DeleteAccountStepTests` 的純函式，這裡驗證有正確接到 model）

    func test_classification_generalMember() {
        let fixture = makeModel(members: [makeMember(id: myID, role: .member), makeMember(id: otherID, role: .owner)])
        XCTAssertNil(fixture.model.step, "還在三分流，尚未往下走")
        XCTAssertEqual(fixture.model.classification, .generalMember)
    }

    func test_classification_soleOwnerWithOtherMembers_mustTransferOwnership() {
        let family = self.family
        let fixture = makeModel(
            family: family, members: [makeMember(id: myID, role: .owner), makeMember(id: otherID, role: .member)]
        )
        XCTAssertEqual(
            fixture.model.classification,
            .mustTransferOwnership(families: [FamilyPendingTransfer(familyID: family.id, familyName: family.name)])
        )
    }

    func test_classification_soleMember() {
        let fixture = makeModel(members: [makeMember(id: myID, role: .owner)])
        XCTAssertEqual(fixture.model.classification, .soleMember)
    }

    // MARK: - proceedToFinalConfirm／cancelFinalConfirm

    func test_proceedToFinalConfirm_generalMemberOrigin_movesToFinalConfirm() {
        let fixture = makeModel(members: [makeMember(id: myID, role: .member)])
        fixture.model.proceedToFinalConfirm(origin: .generalMember)
        XCTAssertEqual(fixture.model.step, .finalConfirm(origin: .generalMember))
    }

    func test_proceedToFinalConfirm_soleMemberOrigin_movesToFinalConfirm() {
        let fixture = makeModel(members: [makeMember(id: myID, role: .owner)])
        fixture.model.proceedToFinalConfirm(origin: .soleMember)
        XCTAssertEqual(fixture.model.step, .finalConfirm(origin: .soleMember))
    }

    func test_cancelFinalConfirm_returnsToClassificationScreen() {
        let fixture = makeModel(members: [makeMember(id: myID, role: .member)])
        fixture.model.proceedToFinalConfirm(origin: .generalMember)

        fixture.model.cancelFinalConfirm()

        XCTAssertNil(fixture.model.step, "取消退回三分流——沒有東西改變過，classification 自然還是同一張")
        XCTAssertEqual(fixture.model.classification, .generalMember)
    }

    func test_cancelFinalConfirm_notAtFinalConfirm_isNoOp() {
        let fixture = makeModel(members: [makeMember(id: myID, role: .member)])
        fixture.model.cancelFinalConfirm()
        XCTAssertNil(fixture.model.step)
    }

    // MARK: - confirmDeletion（04e→04f→04g／04h）

    func test_confirmDeletion_rpcSuccessAndFinalizeSuccess_movesToCompleted() async {
        let stub = StubAccountAPIClient()
        stub.setDeleteMyAccountHandler { .success }
        stub.setFinalizeHandler {}
        let fixture = makeModel(accountAPIClient: stub, members: [makeMember(id: myID, role: .member)])

        fixture.model.confirmDeletion()
        let met = await waitUntil { fixture.model.step == .completed }
        XCTAssertTrue(met, "等待流程完成逾時（1 秒）")

        XCTAssertEqual(stub.deleteMyAccountCallCount, 1)
        XCTAssertEqual(stub.finalizeCallCount, 1)
        XCTAssertTrue(fixture.model.deletionRequested)
        XCTAssertFalse(fixture.model.isProcessing)
    }

    func test_confirmDeletion_rpcMustTransferOwnership_returnsToClassification_doesNotCallFinalize() async {
        let family = self.family
        let stub = StubAccountAPIClient()
        let pending = [FamilyPendingTransfer(familyID: family.id, familyName: family.name)]
        stub.setDeleteMyAccountHandler { .mustTransferOwnership(families: pending) }
        let fixture = makeModel(accountAPIClient: stub, family: family, members: [makeMember(id: myID, role: .member)])

        fixture.model.confirmDeletion()
        let met = await waitUntil { fixture.model.classification == .mustTransferOwnership(families: pending) }
        XCTAssertTrue(met, "等待轉入 04b 逾時（1 秒）")

        XCTAssertNil(fixture.model.step, "情況 1（LS050）退回三分流，不是往下走的 step")
        XCTAssertEqual(stub.finalizeCallCount, 0, "情況 1（LS050）沒有寫入，不該呼叫 Edge Function")
        XCTAssertFalse(fixture.model.deletionRequested)
    }

    func test_confirmDeletion_rpcThrows_movesToFailed_doesNotCallFinalize() async {
        let stub = StubAccountAPIClient()
        stub.setDeleteMyAccountHandler { throw AppError.server(message: "boom", code: nil) }
        let fixture = makeModel(accountAPIClient: stub, members: [makeMember(id: myID, role: .member)])

        fixture.model.confirmDeletion()
        let met = await waitUntil {
            if case .failed = fixture.model.step { return true }
            return false
        }
        XCTAssertTrue(met, "等待轉入 04h 逾時（1 秒）")

        guard case .failed(let error) = fixture.model.step else {
            return XCTFail("預期 .failed，實際 \(String(describing: fixture.model.step))")
        }
        XCTAssertEqual(error, .server(message: "boom", code: nil))
        XCTAssertEqual(stub.finalizeCallCount, 0)
        XCTAssertFalse(fixture.model.deletionRequested)
    }

    func test_confirmDeletion_rpcSuccessFinalizeThrows_movesToFailed_deletionRequestedStaysTrue() async {
        let stub = StubAccountAPIClient()
        stub.setDeleteMyAccountHandler { .success }
        stub.setFinalizeHandler { throw AppError.server(message: "ef down", code: nil) }
        let fixture = makeModel(accountAPIClient: stub, members: [makeMember(id: myID, role: .member)])

        fixture.model.confirmDeletion()
        let met = await waitUntil {
            if case .failed = fixture.model.step { return true }
            return false
        }
        XCTAssertTrue(met, "等待轉入 04h 逾時（1 秒）")

        XCTAssertTrue(fixture.model.deletionRequested, "RPC 已成功，重試不該再呼叫一次 delete_my_account()")
    }

    /// 「重試」語意（04h）：EF 失敗後再呼叫 `confirmDeletion()`（同 `DeletionFailedView` 的
    /// 「重試」按鈕），不該重打已經成功的 `delete_my_account()`，只重打 Edge Function。
    func test_confirmDeletion_retryAfterFinalizeFailure_doesNotCallDeleteMyAccountAgain() async {
        let stub = StubAccountAPIClient()
        stub.setDeleteMyAccountHandler { .success }
        let finalizeShouldFail = OSAllocatedUnfairLock(initialState: true)
        stub.setFinalizeHandler {
            if finalizeShouldFail.withLock({ $0 }) {
                throw AppError.server(message: "ef down", code: nil)
            }
        }
        let fixture = makeModel(accountAPIClient: stub, members: [makeMember(id: myID, role: .member)])

        fixture.model.confirmDeletion()
        let firstAttemptFailed = await waitUntil {
            if case .failed = fixture.model.step { return true }
            return false
        }
        XCTAssertTrue(firstAttemptFailed, "等待第一次失敗逾時（1 秒）")
        XCTAssertEqual(stub.deleteMyAccountCallCount, 1)
        XCTAssertEqual(stub.finalizeCallCount, 1)

        finalizeShouldFail.withLock { $0 = false }
        fixture.model.confirmDeletion()
        let met = await waitUntil { fixture.model.step == .completed }
        XCTAssertTrue(met, "等待重試完成逾時（1 秒）")

        XCTAssertEqual(stub.deleteMyAccountCallCount, 1, "重試不該重打已經成功的 RPC")
        XCTAssertEqual(stub.finalizeCallCount, 2)
    }

    func test_recheckAfterTransfer_callsDeleteMyAccount() async {
        let stub = StubAccountAPIClient()
        stub.setDeleteMyAccountHandler { .success }
        stub.setFinalizeHandler {}
        let family = self.family
        let fixture = makeModel(
            accountAPIClient: stub, family: family,
            members: [makeMember(id: myID, role: .owner), makeMember(id: otherID, role: .member)]
        )
        XCTAssertEqual(
            fixture.model.classification,
            .mustTransferOwnership(families: [FamilyPendingTransfer(familyID: family.id, familyName: family.name)])
        )

        fixture.model.recheckAfterTransfer()
        let met = await waitUntil { fixture.model.step == .completed }
        XCTAssertTrue(met, "等待重新檢查完成逾時（1 秒）")

        XCTAssertEqual(stub.deleteMyAccountCallCount, 1)
    }

    // MARK: - 輪詢等待（同 FamilyStoreTests.test_createFamily_whileSubmitting_ignoresDuplicateCall
    // 的既有寫法：不用 Task.sleep 卡固定秒數，用確定性訊號＋輪詢上限，逾時 XCTFail 而不是掛到
    // XCTest timeout）。不是 `private`：`DeleteAccountFlowModelRaceTests.swift` 共用。

    @discardableResult
    func waitUntil(_ condition: @escaping () -> Bool) async -> Bool {
        var iterations = 0
        while !condition() {
            iterations += 1
            guard iterations < 200 else { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}

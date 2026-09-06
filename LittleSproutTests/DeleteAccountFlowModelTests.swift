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
        let eulaStore: EULAStore
        /// merge-review R2 B2：`DeleteAccountFlowModel.init` 不再自己觸發續傳（見該檔文件
        /// 註解），測試需要另外呼叫 `model.resumeIfNeeded()`（模擬 `DeleteAccountFlowView
        /// .task` 的角色）才能真的跑到 `resumer` 的 `Task`——見
        /// `DeleteAccountFlowModelResumeTests.swift`。
        let resumer: PendingAccountDeletionResumer
    }

    /// 預設佈置成「一般成員」（`.leave`）——大多數狀態機測試不在乎進場分流，只在乎
    /// `confirmDeletion()`／`recheckAfterTransfer()` 之後的行為，這裡給一個確定性的起點。
    ///
    /// `seedOwnerUserID`（merge-review R1 M1 新增，預設 `true` 維持既有呼叫端不變）：`false`
    /// 時不呼叫 `seedOwnerUserIDForPreview`，模擬 `syncOwner(to:)` 還沒跑完／`FamilyStore
    /// .reset()` 之後的「還不知道自己是誰」時序窗口，見 `test_classification_ownerUserIDNotYetSynced_pending`。
    func makeModel(
        accountAPIClient: AccountAPIClient = StubAccountAPIClient(),
        family: Family? = nil,
        members: [FamilyMember] = [],
        seedOwnerUserID: Bool = true,
        authStub: StubAuthService = StubAuthService()
    ) -> Fixture {
        let resolvedFamily = family ?? self.family
        let familyStore = FamilyStore.preview(withFamily: resolvedFamily)
        if seedOwnerUserID {
            familyStore.seedOwnerUserIDForPreview(myID)
        }
        if !members.isEmpty {
            familyStore.seedMembersForPreview(members)
        }
        let authStore = AuthStore(authService: authStub)
        let childrenStore = ChildrenStore.preview()
        let timelineStore = TimelineStore.preview()
        let albumsStore = AlbumsStore.preview()
        let eulaStore = EULAStore.preview(shouldPresent: false, judgedUserID: myID)
        let resumer = PendingAccountDeletionResumer(accountAPIClient: accountAPIClient)
        let model = DeleteAccountFlowModel(
            accountAPIClient: accountAPIClient, familyStore: familyStore, authStore: authStore,
            childrenStore: childrenStore, timelineStore: timelineStore, albumsStore: albumsStore,
            eulaStore: eulaStore, resumer: resumer
        )
        return Fixture(
            model: model, familyStore: familyStore, authStore: authStore,
            childrenStore: childrenStore, timelineStore: timelineStore, albumsStore: albumsStore,
            eulaStore: eulaStore, resumer: resumer
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

    /// **merge-review R1 M1 迴歸測試——複現 reviewer 的 PROBE 情境**：`myFamily` 有值、
    /// `ownerUserID` 有值、`members` 還沒載回（`SettingsView` 的 `.task` 補查還在飛，或使用者
    /// 在回應到達前就點了「刪除帳號」）。R1 版這裡會回 `.generalMember`（PROBE-RESULT
    /// `before=generalMember`），使用者按「繼續刪除帳號」後 `step` 換成 `.finalConfirm`，
    /// `content` 從此只看 `step` 不再看 `classification`——即使 `members` 稍後真的載回來變成
    /// `soleMember`，畫面也回不去 04d 了。訂正後必須是 `.pending`，讓 UI 停在載入態、不能往下
    /// 走到 04e（`GeneralMemberDeleteAccountView`／`SoleMemberDeleteWarningView` 才有
    /// 「繼續刪除帳號」鈕，`.pending` 畫面的鈕是 `.disabled(true)`，見
    /// `DeleteAccountMembersPendingView`）。
    func test_classification_membersNotYetLoaded_pending_notGeneralMember() {
        let fixture = makeModel(members: [])
        XCTAssertEqual(
            fixture.model.classification, .pending,
            "members 還沒載回時絕對不能是 .generalMember——04d 唯一成員警告沒有伺服器兜底"
        )
    }

    /// `ownerUserID` 也還沒同步（`syncOwner(to:)` 尚未跑完）的更早時序窗口，同樣必須 `.pending`。
    func test_classification_ownerUserIDNotYetSynced_pending() {
        let fixture = makeModel(members: [], seedOwnerUserID: false)
        XCTAssertEqual(fixture.model.classification, .pending)
    }

    /// `membersState == .failure`（`SettingsView` 補查一次失敗）——顯示可重試錯誤，不是三分流
    /// 之一，也不是 `.pending`（沒有理由讓使用者一直等一個不會自己好的狀態）。`FamilyStore
    /// .preview(withFamily:)` 底層固定用 `PreviewFamilyAPIClient`（`listMembers` 永遠成功），
    /// 這裡改用 `StubFamilyAPIClient` 直接建構 `FamilyStore`（同 `FamilyStoreTests` 既有慣例）
    /// 才能真的模擬一次失敗的查詢。
    func test_classification_membersLoadFailed_showsRetryableError() async {
        let family = self.family
        let stub = StubFamilyAPIClient()
        stub.setFetchMyFamilyHandler { family }
        stub.setListMembersHandler { _ in throw AppError.network(message: "offline") }
        let familyStore = FamilyStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())
        _ = await familyStore.syncOwner(to: myID)
        _ = await familyStore.refreshMembers()

        let model = DeleteAccountFlowModel(
            accountAPIClient: StubAccountAPIClient(), familyStore: familyStore,
            authStore: AuthStore(authService: StubAuthService()),
            childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview(),
            eulaStore: .preview(shouldPresent: false), resumer: .preview()
        )

        guard case .membersLoadFailed(let error) = model.classification else {
            return XCTFail("預期 .membersLoadFailed，實際 \(model.classification)")
        }
        XCTAssertEqual(error, .network(message: "offline"))
    }

    /// M2／merge-review R2 m2：`myFamily == nil`（`ForkView`「刪除帳號」入口——多半是停權
    /// 使用者，RLS 把家庭收斂成 0 列）必須是確定的分流，不能卡在 `.pending`——`refreshMembers()`
    /// 需要 `myFamily?.id` 才會真的打 API，沒有家庭就永遠沒有機會「載完」，卡在 `.pending`
    /// 等於使用者永遠到不了 04e。**R2 訂正**：不是 `.generalMember`（那樣 04a 會講一句 client
    /// 端無法確認的話「其他家人不受影響」）——改成 `.soleMember`，沿用 04d 既有的「往最壞情況
    /// 說」警示文案，不新增設計板，見 `DeleteAccountFlowModel.classification` 文件註解。
    func test_classification_noFamily_soleMember() {
        let familyStore = FamilyStore.preview()
        let authStore = AuthStore(authService: StubAuthService())
        let model = DeleteAccountFlowModel(
            accountAPIClient: StubAccountAPIClient(), familyStore: familyStore, authStore: authStore,
            childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview(),
            eulaStore: .preview(shouldPresent: false), resumer: .preview()
        )
        XCTAssertNil(familyStore.myFamily, "前置：這個 fixture 刻意不建家庭")
        XCTAssertEqual(model.classification, .soleMember)
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

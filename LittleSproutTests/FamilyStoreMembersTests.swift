import Foundation
@testable import LittleSprout
import XCTest

/// LS-192：03 家庭成員管理（清單／移除／轉移 Owner／退出）——查詢家庭／建立家庭／邀請碼的既有
/// 狀態機測試在 `FamilyStoreTests`／`FamilyStoreInviteTests`，拆檔理由同兩者的既有說明。
@MainActor
final class FamilyStoreMembersTests: XCTestCase {
    private let familyID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private let myID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private let otherID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    private func makeMember(id: UUID, role: FamilyRole, name: String) -> FamilyMember {
        FamilyMember(userID: id, role: role, displayName: name, avatarURL: nil)
    }

    private func makeStore(family: Family? = nil) -> (FamilyStore, StubFamilyAPIClient) {
        let stub = StubFamilyAPIClient()
        let store = FamilyStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())
        if let family {
            store.seedMyFamilyForPreview(family)
        }
        return (store, stub)
    }

    private var family: Family {
        Family(id: familyID, name: "陳家", createdBy: myID, createdAt: Date(), requireApproval: true)
    }

    // MARK: - refreshMembers

    func test_refreshMembers_success_populatesMembers() async {
        let (store, stub) = makeStore(family: family)
        let members = [
            makeMember(id: myID, role: .owner, name: "陳美玲"), makeMember(id: otherID, role: .member, name: "陳阿公")
        ]
        stub.setListMembersHandler { _ in members }

        let result = await store.refreshMembers()

        XCTAssertEqual(result, members)
        XCTAssertEqual(store.members, members)
        XCTAssertEqual(store.membersState, .success)
    }

    func test_refreshMembers_failure_setsFailureState_doesNotClearExistingList() async {
        let (store, stub) = makeStore(family: family)
        store.seedMembersForPreview([makeMember(id: myID, role: .owner, name: "陳美玲")])
        stub.setListMembersHandler { _ in throw AppError.server(message: "boom", code: nil) }

        _ = await store.refreshMembers()

        guard case .failure = store.membersState else {
            return XCTFail("查詢失敗應該落 .failure，讓 FamilyMembersView 顯示重試")
        }
        XCTAssertEqual(store.members.count, 1, "查詢失敗不該清掉畫面上原本已顯示的清單")
    }

    // MARK: - removeMember（03b／自行退出共用同一支）

    func test_removeMember_success_removesFromLocalList() async {
        let (store, stub) = makeStore(family: family)
        store.seedMembersForPreview([
            makeMember(id: myID, role: .owner, name: "陳美玲"), makeMember(id: otherID, role: .member, name: "陳阿公")
        ])
        stub.setRemoveMemberHandler { _, _ in }

        let success = await store.removeMember(userID: otherID)

        XCTAssertTrue(success)
        XCTAssertEqual(store.members.map(\.userID), [myID])
        XCTAssertEqual(store.memberActionState, .success)
        XCTAssertEqual(
            stub.removeMemberCalls, [StubFamilyAPIClient.RemoveMemberCall(familyID: familyID, userID: otherID)]
        )
    }

    /// 唯一 owner 且家庭還有其他成員時，DB trigger 回 `LS057`（LS-206）——`removeMember` 不特判
    /// 這個碼，直接落進既有的 `AppError.map` 映射鏈，`memberActionState` 落 `.failure`。
    func test_removeMember_ownerMustTransferFirst_setsFailureState_keepsMemberInList() async {
        let (store, stub) = makeStore(family: family)
        store.seedMembersForPreview([
            makeMember(id: myID, role: .owner, name: "陳美玲"), makeMember(id: otherID, role: .member, name: "陳阿公")
        ])
        stub.setRemoveMemberHandler { _, _ in
            throw AppError.rejected(message: "須先轉移 owner 身份", code: LSErrorCode.ownerMustTransferBeforeLeaving.rawValue)
        }

        let success = await store.removeMember(userID: myID)

        XCTAssertFalse(success)
        XCTAssertEqual(store.members.count, 2, "移除失敗不該把人從畫面上的清單拿掉")
        guard case .failure(let error) = store.memberActionState,
              case .rejected(_, let code) = error else {
            return XCTFail("失敗狀態應帶回 LS057，供 03e 文案分流")
        }
        XCTAssertEqual(code, LSErrorCode.ownerMustTransferBeforeLeaving.rawValue)
    }

    // MARK: - transferOwnership（03c）

    func test_transferOwnership_success_updatesRolesAndResorts() async {
        let (store, stub) = makeStore(family: family)
        store.seedMembersForPreview([
            makeMember(id: myID, role: .owner, name: "陳美玲"), makeMember(id: otherID, role: .member, name: "陳阿公")
        ])
        let myID = self.myID
        stub.setTransferOwnershipHandler { _, toUserID in
            TransferOwnershipResult(fromUserID: myID, fromRole: .member, toUserID: toUserID, toRole: .owner)
        }

        let success = await store.transferOwnership(toUserID: otherID)

        XCTAssertTrue(success)
        XCTAssertEqual(store.members.first?.userID, otherID, "新 owner 應排到最前面（FamilyRole.sortRank）")
        XCTAssertEqual(store.members.first?.role, .owner)
        XCTAssertEqual(store.members.last?.role, .member)
        XCTAssertEqual(store.memberActionState, .success)
    }

    func test_transferOwnership_notOwner_setsFailureState() async {
        let (store, stub) = makeStore(family: family)
        store.seedMembersForPreview([
            makeMember(id: myID, role: .owner, name: "陳美玲"), makeMember(id: otherID, role: .member, name: "陳阿公")
        ])
        stub.setTransferOwnershipHandler { _, _ in
            throw AppError.rejected(message: "你不是這個家庭目前的 owner", code: LSErrorCode.notFamilyOwner.rawValue)
        }

        let success = await store.transferOwnership(toUserID: otherID)

        XCTAssertFalse(success)
        guard case .failure = store.memberActionState else {
            return XCTFail("轉移失敗應該落 .failure")
        }
    }

    // MARK: - leaveFamily（03d／03e）

    func test_leaveFamily_success_clearsMyFamilyAndMembers() async {
        let (store, stub) = makeStore()
        // `ownerUserID` 只能透過 `syncOwner(to:)` 設定（`private(set)`，見 `FamilyStore.swift`
        // 屬性文件註解），沒有對應的 `#if DEBUG` seed 入口——這裡改用會實際呼叫 `syncOwner` 的
        // 路徑，讓 `leaveFamily()` 讀到的 `ownerUserID` 是真的。
        let family = self.family
        stub.setFetchMyFamilyHandler { family }
        await store.syncOwner(to: myID)
        store.seedMembersForPreview([makeMember(id: myID, role: .member, name: "陳美玲")])
        stub.setRemoveMemberHandler { _, _ in }

        let success = await store.leaveFamily()

        XCTAssertTrue(success)
        XCTAssertNil(store.myFamily, "退出成功後 myFamily 歸零，root routing 才會自動切回三岔路")
        XCTAssertTrue(store.members.isEmpty)
    }

    func test_leaveFamily_serverRejectsLS057_keepsMyFamily() async {
        let (store, stub) = makeStore()
        let family = self.family
        stub.setFetchMyFamilyHandler { family }
        await store.syncOwner(to: myID)
        store.seedMembersForPreview([
            makeMember(id: myID, role: .owner, name: "陳美玲"), makeMember(id: otherID, role: .member, name: "陳阿公")
        ])
        stub.setRemoveMemberHandler { _, _ in
            throw AppError.rejected(message: "須先轉移 owner 身份", code: LSErrorCode.ownerMustTransferBeforeLeaving.rawValue)
        }

        let success = await store.leaveFamily()

        XCTAssertFalse(success)
        XCTAssertNotNil(store.myFamily, "伺服器拒絕時不該提前把 myFamily 歸零，維持在 03e 畫面上")
    }

    // MARK: - leaveFlowCase（03d／03e／03e 單人變體 client 端預判，R3 merge-review R2 M-A）

    func test_leaveFlowCase_soleOwnerWithOtherMembers_mustTransferFirst() async {
        let (store, stub) = makeStore()
        let family = self.family
        stub.setFetchMyFamilyHandler { family }
        await store.syncOwner(to: myID)
        store.seedMembersForPreview([
            makeMember(id: myID, role: .owner, name: "陳美玲"), makeMember(id: otherID, role: .member, name: "陳阿公")
        ])

        XCTAssertEqual(store.leaveFlowCase, .mustTransferFirst)
    }

    func test_leaveFlowCase_coOwnerExists_leave() async {
        let (store, stub) = makeStore()
        let family = self.family
        stub.setFetchMyFamilyHandler { family }
        await store.syncOwner(to: myID)
        store.seedMembersForPreview([
            makeMember(id: myID, role: .owner, name: "陳美玲"), makeMember(id: otherID, role: .owner, name: "陳爸爸")
        ])

        XCTAssertEqual(store.leaveFlowCase, .leave, "還有另一位 owner，退出不會讓家庭懸空")
    }

    func test_leaveFlowCase_soleOwnerSoleMember_soleMember() async {
        let (store, stub) = makeStore()
        let family = self.family
        stub.setFetchMyFamilyHandler { family }
        await store.syncOwner(to: myID)
        store.seedMembersForPreview([makeMember(id: myID, role: .owner, name: "陳美玲")])

        // R3（merge-review R2 M-A）：R2 之前這裡斷言 `false`（誤落到 03d，實際送出必撞
        // LS001）——現在獨立成 `.soleMember`，`FamilyMembersView.startLeaveFlow()` 對這個
        // 狀態改顯示「無法退出家庭」提示，不會再送出任何 DELETE 請求。
        XCTAssertEqual(store.leaveFlowCase, .soleMember, "唯一 owner 兼唯一成員——退出無意義，改導向刪除帳號")
    }

    func test_leaveFlowCase_notOwner_leave() async {
        let (store, stub) = makeStore()
        let family = self.family
        stub.setFetchMyFamilyHandler { family }
        await store.syncOwner(to: myID)
        store.seedMembersForPreview([
            makeMember(id: myID, role: .member, name: "陳美玲"), makeMember(id: otherID, role: .owner, name: "陳爸爸")
        ])

        XCTAssertEqual(store.leaveFlowCase, .leave, "不是 owner 的成員退出不受這個不變量限制")
    }

    // MARK: - B1（merge-review R1 blocker）：獨自建立家庭者退出——UI 端已經在 R3 用
    // `leaveFlowCase == .soleMember` 擋下、不再送出 DELETE（見上）；這裡保留 `leaveFamily()`
    // 直接呼叫的防禦性回歸測試——萬一日後有呼叫路徑繞過 `startLeaveFlow()` 的分流（例如深連結
    // 或未來的批次操作）直接呼叫這支 store 方法，伺服器 LS001 仍必須映射成 03e 同一句文案，
    // 不能落回泛用「無法完成這個操作」。

    /// 重現 B1 實測情境逐字：使用者自己建了家庭、還沒邀請任何人——`members` 只有自己一列
    /// （owner），`leaveFlowCase` 判斷是 `.soleMember`（R3 之後 UI 不會再送出這個請求），但
    /// 直接呼叫 `store.leaveFamily()`（繞過 UI 分流）仍會撞既有的
    /// `private.enforce_family_has_owner()`（LS001，家庭剩 0 owner）。
    func test_leaveFamily_soleOwnerSoleMember_serverRejectsLS001_messageReusesOwnerTransferText() async {
        let (store, stub) = makeStore()
        let family = self.family
        stub.setFetchMyFamilyHandler { family }
        await store.syncOwner(to: myID)
        store.seedMembersForPreview([makeMember(id: myID, role: .owner, name: "陳美玲")])
        stub.setRemoveMemberHandler { _, _ in
            throw AppError.rejected(
                message: "家庭必須至少保留一位 owner（請先指派新 owner，再移除或降級原 owner）",
                code: LSErrorCode.familyMustHaveOwner.rawValue
            )
        }

        // R3：client 端預判是 `.soleMember`——`startLeaveFlow()` 不會再走到這裡，這支測試繞過
        // UI 直接呼叫 store 方法，驗證伺服器端防線本身仍然正確（防禦性回歸，不是死路起點）。
        XCTAssertEqual(store.leaveFlowCase, .soleMember)

        let success = await store.leaveFamily()

        XCTAssertFalse(success)
        XCTAssertNotNil(store.myFamily, "伺服器拒絕時不該提前把 myFamily 歸零")
        guard case .failure(let error) = store.memberActionState else {
            return XCTFail("退出失敗應該落 .failure")
        }
        // B1 核心斷言：不是泛用的「無法完成這個操作」，而是 LS-152 Notes 錯誤文案表指定、
        // 跟 03e 相同的那一句。
        XCTAssertEqual(
            error.familyMemberActionMessage, "需要先轉移家庭管理者身分",
            "LeaveFamilyConfirmSheet／MustTransferOwnershipFirstView 都用這句話接住 LS001，" +
            "不落回 error.userFacingMessage 的泛用訊息"
        )
    }
}

import Foundation
@testable import LittleSprout
import XCTest

/// LS-192：03 成員清單「移除」「轉移 Owner」動作可見性——見 `FamilyMemberActionVisibility.swift`
/// 文件註解。
final class FamilyMemberActionVisibilityTests: XCTestCase {
    private let myUserID = UUID()
    private let otherUserID = UUID()

    private func makeMember(userID: UUID, role: FamilyRole) -> FamilyMember {
        FamilyMember(userID: userID, role: role, displayName: "測試成員", avatarURL: nil)
    }

    func test_isRemovable_ownerActingOnOther_true() {
        let target = makeMember(userID: otherUserID, role: .member)
        XCTAssertTrue(target.isRemovable(byRole: .owner, myUserID: myUserID))
    }

    func test_isRemovable_ownerActingOnSelf_false() {
        // 自己離開走「退出家庭」入口（03d／03e），不是成員列的「移除」動作。
        let target = makeMember(userID: myUserID, role: .owner)
        XCTAssertFalse(target.isRemovable(byRole: .owner, myUserID: myUserID))
    }

    func test_isRemovable_memberActingOnOther_false() {
        let target = makeMember(userID: otherUserID, role: .member)
        XCTAssertFalse(target.isRemovable(byRole: .member, myUserID: myUserID))
    }

    func test_isRemovable_viewerActingOnOther_false() {
        let target = makeMember(userID: otherUserID, role: .member)
        XCTAssertFalse(target.isRemovable(byRole: .viewer, myUserID: myUserID))
    }

    func test_isTransferable_ownerActingOnOtherMember_true() {
        let target = makeMember(userID: otherUserID, role: .member)
        XCTAssertTrue(target.isTransferable(byRole: .owner, myUserID: myUserID))
    }

    func test_isTransferable_ownerActingOnOtherViewer_true() {
        // transfer_ownership RPC 不限制對方角色（owner／member／viewer 皆可，docs/API.md §4）。
        let target = makeMember(userID: otherUserID, role: .viewer)
        XCTAssertTrue(target.isTransferable(byRole: .owner, myUserID: myUserID))
    }

    func test_isTransferable_ownerActingOnSelf_false() {
        let target = makeMember(userID: myUserID, role: .owner)
        XCTAssertFalse(target.isTransferable(byRole: .owner, myUserID: myUserID))
    }

    func test_isTransferable_memberActingOnOther_false() {
        let target = makeMember(userID: otherUserID, role: .member)
        XCTAssertFalse(target.isTransferable(byRole: .member, myUserID: myUserID))
    }

    // MARK: - membersListDisplayLabel／membersListIconName（R2 merge-review M3／M4）

    func test_membersListDisplayLabel_owner_isFamilyManagerNotOwner() {
        // Notes MN-1 定案：角色詞彙是「家庭管理者／一般成員／只能看」，不是「Owner」／「擁有者」
        // （R1 誤用「擁有者」，merge-review R1 M3）。
        XCTAssertEqual(FamilyRole.owner.membersListDisplayLabel, "家庭管理者")
        XCTAssertEqual(FamilyRole.member.membersListDisplayLabel, "一般成員")
        XCTAssertEqual(FamilyRole.viewer.membersListDisplayLabel, "只能看")
    }

    func test_membersListIconName_matchesDesignRolePillOverrides() {
        // 稿 `cmp/Role Pill`（`AqN3F`）三個 override：crown／user／eye。
        XCTAssertEqual(FamilyRole.owner.membersListIconName, "crown")
        XCTAssertEqual(FamilyRole.member.membersListIconName, "person")
        XCTAssertEqual(FamilyRole.viewer.membersListIconName, "eye")
    }

    // MARK: - AppError.familyMemberActionMessage（R2 merge-review B1／M1）

    func test_familyMemberActionMessage_ls001_reusesOwnerTransferText() {
        // B1：唯一 owner 兼唯一成員退出時，client 端預判判斷成不需要轉移（03d），實際送出撞到
        // 既有的 LS001（`private.enforce_family_has_owner`）——用跟 LS057 同一句 03e 文案接住，
        // 不落回泛用「無法完成這個操作」。
        let error = AppError.rejected(message: "家庭必須至少保留一位 owner", code: LSErrorCode.familyMustHaveOwner.rawValue)
        XCTAssertEqual(error.familyMemberActionMessage, "需要先轉移家庭管理者身分")
    }

    func test_familyMemberActionMessage_ls057_reusesOwnerTransferText() {
        let error = AppError.rejected(
            message: "須先轉移 owner 身份", code: LSErrorCode.ownerMustTransferBeforeLeaving.rawValue
        )
        XCTAssertEqual(error.familyMemberActionMessage, "需要先轉移家庭管理者身分")
    }

    func test_familyMemberActionMessage_ls058_notFamilyOwner() {
        let error = AppError.rejected(message: "你不是這個家庭目前的 owner", code: LSErrorCode.notFamilyOwner.rawValue)
        XCTAssertEqual(error.familyMemberActionMessage, "你已經不是這個家庭的管理者了，請重新整理成員列表。")
    }

    func test_familyMemberActionMessage_ls059_transferTargetNotMember() {
        let error = AppError.rejected(
            message: "對方不是這個家庭目前的成員", code: LSErrorCode.transferTargetNotMember.rawValue
        )
        XCTAssertEqual(error.familyMemberActionMessage, "對方已經不在這個家庭了，請重新整理成員列表。")
    }

    func test_familyMemberActionMessage_ls060_cannotTransferToSelf() {
        let error = AppError.rejected(message: "不能把 owner 身份轉移給自己", code: LSErrorCode.cannotTransferToSelf.rawValue)
        XCTAssertEqual(error.familyMemberActionMessage, "不能把家庭管理者身分轉移給自己。")
    }

    func test_familyMemberActionMessage_unmappedCode_returnsNil() {
        // 沒有專屬文案的碼（例如網路錯誤、其餘 rejected 碼）回 nil，呼叫端退回
        // `userFacingMessage`，不是本方法的責任。
        let error = AppError.rejected(message: "沒有權限移除這位成員", code: "no_rows_deleted")
        XCTAssertNil(error.familyMemberActionMessage)
    }

    func test_familyMemberActionMessage_networkError_returnsNil() {
        XCTAssertNil(AppError.network(message: "offline").familyMemberActionMessage)
    }
}

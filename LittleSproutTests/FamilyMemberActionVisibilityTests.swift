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
}

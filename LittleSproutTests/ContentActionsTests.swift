import Foundation
@testable import LittleSprout
import XCTest

/// LS-189：內容操作表動作組成（`contentActions(for:viewerRole:viewerUserID:authorID:
/// authorDisplayName:)`，見 `ContentActions.swift` 文件註解）——依「這則內容是不是我自己的」
/// 「我是不是家庭管理者」「作者查不查得到」窮舉矩陣，同 `FamilyMemberActionVisibilityTests`
/// 既有慣例。
final class ContentActionsTests: XCTestCase {
    private let viewerUserID = UUID()
    private let authorUserID = UUID()
    private let familyID = UUID()

    private func makeTarget(type: ContentTargetType = .diary) -> ContentActionTarget {
        ContentActionTarget(type: type, id: UUID(), familyID: familyID, headline: "「測試內容」")
    }

    // MARK: - 自己的內容 → 只有刪除

    func test_ownContent_owner_onlyDeleteOwn() {
        let actions = contentActions(
            for: makeTarget(), viewerRole: .owner, viewerUserID: viewerUserID,
            authorID: viewerUserID, authorDisplayName: "我"
        )
        XCTAssertEqual(actions, [.deleteOwn])
    }

    func test_ownContent_member_onlyDeleteOwn() {
        let actions = contentActions(
            for: makeTarget(), viewerRole: .member, viewerUserID: viewerUserID,
            authorID: viewerUserID, authorDisplayName: "我"
        )
        XCTAssertEqual(actions, [.deleteOwn], "不管我在這個家庭是什麼角色，自己的內容一律只顯示刪除")
    }

    func test_ownContent_viewer_onlyDeleteOwn() {
        let actions = contentActions(
            for: makeTarget(), viewerRole: .viewer, viewerUserID: viewerUserID,
            authorID: viewerUserID, authorDisplayName: "我"
        )
        XCTAssertEqual(actions, [.deleteOwn])
    }

    // MARK: - 別人的內容、作者已知

    func test_othersContent_ownerViewing_reportsBlockAndRemove() {
        let actions = contentActions(
            for: makeTarget(), viewerRole: .owner, viewerUserID: viewerUserID,
            authorID: authorUserID, authorDisplayName: "陳志明"
        )
        XCTAssertEqual(actions, [.report, .block(memberID: authorUserID, memberName: "陳志明"), .removeAsOwner])
    }

    func test_othersContent_memberViewing_reportsAndBlockOnly_noRemove() {
        let actions = contentActions(
            for: makeTarget(), viewerRole: .member, viewerUserID: viewerUserID,
            authorID: authorUserID, authorDisplayName: "陳志明"
        )
        XCTAssertEqual(
            actions, [.report, .block(memberID: authorUserID, memberName: "陳志明")],
            "一般成員不是家庭管理者，看不到「移除這則內容」"
        )
    }

    func test_othersContent_viewerViewing_reportsAndBlockOnly_noRemove() {
        let actions = contentActions(
            for: makeTarget(), viewerRole: .viewer, viewerUserID: viewerUserID,
            authorID: authorUserID, authorDisplayName: "陳志明"
        )
        XCTAssertEqual(actions, [.report, .block(memberID: authorUserID, memberName: "陳志明")])
    }

    /// `docs/API.md` `block_user`：`p_blocked_id` 不驗證是否為該家庭成員，也沒有排除家庭管理者
    /// 的限制——封鎖家庭管理者本人一樣合法。
    func test_ownerAsAuthor_canStillBeBlockedAndReported() {
        let actions = contentActions(
            for: makeTarget(), viewerRole: .member, viewerUserID: viewerUserID,
            authorID: authorUserID, authorDisplayName: "陳爸爸（家庭管理者）"
        )
        XCTAssertEqual(actions, [.report, .block(memberID: authorUserID, memberName: "陳爸爸（家庭管理者）")])
    }

    // MARK: - 別人的內容、作者未知（例如作者已離開家庭）

    func test_othersContent_authorUnknown_ownerViewing_reportAndRemoveOnly_noBlock() {
        let actions = contentActions(
            for: makeTarget(), viewerRole: .owner, viewerUserID: viewerUserID,
            authorID: nil, authorDisplayName: "這位成員"
        )
        XCTAssertEqual(actions, [.report, .removeAsOwner], "作者未知時無法封鎖（block_user 需要確定的 p_blocked_id）")
    }

    func test_othersContent_authorUnknown_memberViewing_reportOnly() {
        let actions = contentActions(
            for: makeTarget(), viewerRole: .member, viewerUserID: viewerUserID,
            authorID: nil, authorDisplayName: "這位成員"
        )
        XCTAssertEqual(actions, [.report])
    }

    // MARK: - 目標類型不影響動作組成（純粹依身分）

    func test_targetType_doesNotAffectActionComposition() {
        let diaryActions = contentActions(
            for: makeTarget(type: .diary), viewerRole: .owner, viewerUserID: viewerUserID,
            authorID: authorUserID, authorDisplayName: "陳志明"
        )
        let commentActions = contentActions(
            for: makeTarget(type: .comment), viewerRole: .owner, viewerUserID: viewerUserID,
            authorID: authorUserID, authorDisplayName: "陳志明"
        )
        XCTAssertEqual(diaryActions, commentActions)
    }

    // MARK: - ContentAction 顯示屬性

    func test_action_icon_labelAndDanger() {
        XCTAssertEqual(ContentAction.report.icon, "flag.fill")
        XCTAssertEqual(ContentAction.report.label, "檢舉這則內容")
        XCTAssertFalse(ContentAction.report.isDanger)

        let block = ContentAction.block(memberID: authorUserID, memberName: "陳志明")
        XCTAssertEqual(block.icon, "person.fill.xmark")
        XCTAssertEqual(block.label, "封鎖陳志明")
        XCTAssertFalse(block.isDanger)

        XCTAssertEqual(ContentAction.removeAsOwner.icon, "trash")
        XCTAssertEqual(ContentAction.removeAsOwner.label, "移除這則內容")
        XCTAssertTrue(ContentAction.removeAsOwner.isDanger)

        XCTAssertEqual(ContentAction.deleteOwn.icon, "trash")
        XCTAssertEqual(ContentAction.deleteOwn.label, "刪除")
        XCTAssertTrue(ContentAction.deleteOwn.isDanger)
    }

    // MARK: - Mutation：拿掉 owner 判斷會讓非家庭管理者也看到「移除」

    /// 模擬「不小心把 `viewerRole == .owner` 判斷拿掉、一律附加 removeAsOwner」這種回歸——
    /// 這條測試在正確實作下應為綠，佐證矩陣有鑑別力（見 handoff mutation 段的實跑記錄）。
    func test_mutationGuard_memberNeverSeesRemoveAsOwner() {
        let actions = contentActions(
            for: makeTarget(), viewerRole: .member, viewerUserID: viewerUserID,
            authorID: authorUserID, authorDisplayName: "陳志明"
        )
        XCTAssertFalse(actions.contains(.removeAsOwner))
    }
}

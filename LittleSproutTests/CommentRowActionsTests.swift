import Foundation
@testable import LittleSprout
import XCTest

/// LS-218：留言列操作表動作組成（`commentRowActions`，見該檔文件註解為何不重用
/// `contentActions(for:...)`）——窮舉「自己的留言／owner 對別人留言／一般成員對別人留言／作者
/// 未知」四種身分組合，同 `ContentActionsTests` 既有慣例。
final class CommentRowActionsTests: XCTestCase {
    private let viewerUserID = UUID()
    private let authorUserID = UUID()

    // MARK: - 自己的留言 → 只有刪除（不管角色）

    func test_ownComment_owner_onlyDeleteOwn() {
        let actions = commentRowActions(
            authorID: viewerUserID, authorDisplayName: "我", viewerRole: .owner, viewerUserID: viewerUserID
        )
        XCTAssertEqual(actions, [.deleteOwn])
    }

    func test_ownComment_member_onlyDeleteOwn() {
        let actions = commentRowActions(
            authorID: viewerUserID, authorDisplayName: "我", viewerRole: .member, viewerUserID: viewerUserID
        )
        XCTAssertEqual(actions, [.deleteOwn])
    }

    // MARK: - Owner 對別人的留言 → 單一 danger 列（DUyg3），不含檢舉／封鎖

    func test_othersComment_ownerViewing_onlyRemoveAsOwner_noReportOrBlock() {
        let actions = commentRowActions(
            authorID: authorUserID, authorDisplayName: "陳志明", viewerRole: .owner, viewerUserID: viewerUserID
        )
        XCTAssertEqual(
            actions, [.removeAsOwner],
            "DUyg3 稿面只有一列「移除這則留言」——owner 對留言不應該同時看到檢舉／封鎖"
        )
    }

    func test_othersComment_ownerViewing_authorUnknown_stillOnlyRemoveAsOwner() {
        let actions = commentRowActions(
            authorID: nil, authorDisplayName: "這位成員", viewerRole: .owner, viewerUserID: viewerUserID
        )
        XCTAssertEqual(actions, [.removeAsOwner])
    }

    // MARK: - 一般成員對別人的留言 → 同 contentActions(for:...) 既有行為（檢舉＋封鎖，不含移除）

    func test_othersComment_memberViewing_reportAndBlock_noRemove() {
        let actions = commentRowActions(
            authorID: authorUserID, authorDisplayName: "陳志明", viewerRole: .member, viewerUserID: viewerUserID
        )
        XCTAssertEqual(actions, [.report, .block(memberID: authorUserID, memberName: "陳志明")])
    }

    func test_othersComment_viewerViewing_reportAndBlock_noRemove() {
        let actions = commentRowActions(
            authorID: authorUserID, authorDisplayName: "陳志明", viewerRole: .viewer, viewerUserID: viewerUserID
        )
        XCTAssertEqual(actions, [.report, .block(memberID: authorUserID, memberName: "陳志明")])
    }

    func test_othersComment_memberViewing_authorUnknown_reportOnly() {
        let actions = commentRowActions(
            authorID: nil, authorDisplayName: "這位成員", viewerRole: .member, viewerUserID: viewerUserID
        )
        XCTAssertEqual(actions, [.report], "作者未知時無法封鎖（block_user 需要確定的 p_blocked_id）")
    }

    // MARK: - Mutation guard：拿掉 owner 分支會讓 owner 也看到檢舉／封鎖

    func test_mutationGuard_ownerNeverSeesReportOrBlock() {
        let actions = commentRowActions(
            authorID: authorUserID, authorDisplayName: "陳志明", viewerRole: .owner, viewerUserID: viewerUserID
        )
        XCTAssertFalse(actions.contains(.report))
        XCTAssertFalse(actions.contains(where: { if case .block = $0 { true } else { false } }))
    }
}

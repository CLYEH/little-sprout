import os
@testable import LittleSprout
import XCTest

/// LS-245（池 `38a3c74b`，sweeper LS-218）：`StubCommentAPIClient.setSetCommentDeletedHandler`
/// ／backing 欄位／`setCommentDeleted` 原本無任何呼叫端用上（Owner 移除留言直呼 API client、
/// 不經 `CommentsStore`，見 `CommentDeleteConfirmationSheet` 文件註解）——這裡補一支測試用上
/// 它：驗證「Owner 移除留言」真的走 `CommentAPIClient.setCommentDeleted(commentID:deleted:true)`。
final class CommentDeleteConfirmationSheetTests: XCTestCase {
    private struct RecordedCall: Equatable {
        let commentID: UUID
        let deleted: Bool
    }

    @MainActor
    func test_performDelete_callsSetCommentDeletedWithCommentIDAndDeletedTrueOnAPIClient() async throws {
        let stub = StubCommentAPIClient()
        let commentID = UUID()
        let recorder = OSAllocatedUnfairLock<[RecordedCall]>(initialState: [])
        stub.setSetCommentDeletedHandler { id, deleted in
            recorder.withLock { $0.append(RecordedCall(commentID: id, deleted: deleted)) }
        }
        let sheet = CommentDeleteConfirmationSheet(commentID: commentID, commentAPIClient: stub)

        try await sheet.performDelete()

        XCTAssertEqual(
            recorder.withLock { $0 }, [RecordedCall(commentID: commentID, deleted: true)],
            "Owner 移除留言應該原樣把 commentID 與 deleted: true 轉呼叫 CommentAPIClient.setCommentDeleted"
        )
    }
}

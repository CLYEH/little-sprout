import Foundation
@testable import LittleSprout
import os

/// `DeleteConfirmationSheet`／`CommentDeleteConfirmationSheet` 測試用假 `CommentAPIClient`
/// ——不打真網路（同 `StubDiaryAPIClient` 的模式，見該檔）。
final class StubCommentAPIClient: CommentAPIClient, @unchecked Sendable {
    typealias SetDeletedHandler = @Sendable (UUID, Bool) async throws -> Void

    struct SetDeletedCall: Equatable {
        let commentID: UUID
        let deleted: Bool
    }

    private struct Box {
        var handler: SetDeletedHandler = { _, _ in }
        var calls: [SetDeletedCall] = []
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var calls: [SetDeletedCall] { box.withLock { $0.calls } }

    func setHandler(_ handler: @escaping SetDeletedHandler) {
        box.withLock { $0.handler = handler }
    }

    func setCommentDeleted(commentID: UUID, deleted: Bool) async throws {
        box.withLock { $0.calls.append(SetDeletedCall(commentID: commentID, deleted: deleted)) }
        let handler = box.withLock { $0.handler }
        try await handler(commentID, deleted)
    }
}

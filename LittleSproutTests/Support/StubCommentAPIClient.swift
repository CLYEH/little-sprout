import Foundation
@testable import LittleSprout
import os

/// `CommentsStore` 測試用假 `CommentAPIClient`——不打真網路，用可設定的 handler 決定各方法的
/// 表現（同 `StubTimelineAPIClient` 的模式，見該檔）。
final class StubCommentAPIClient: CommentAPIClient, @unchecked Sendable {
    typealias SetCommentDeletedHandler = @Sendable (UUID, Bool) async throws -> Void
    typealias ListCommentsHandler = @Sendable (UUID, String, UUID, CommentsCursor?, Int) async throws -> [CommentRecord]
    typealias CreateCommentHandler = @Sendable (UUID, String, UUID, String) async throws -> UUID

    struct ListCommentsCall: Equatable {
        let familyID: UUID
        let targetType: String
        let targetID: UUID
        let cursor: CommentsCursor?
        let limit: Int
    }

    struct CreateCommentCall: Equatable {
        let familyID: UUID
        let targetType: String
        let targetID: UUID
        let body: String
    }

    private struct Box {
        var setCommentDeletedHandler: SetCommentDeletedHandler = { _, _ in }
        var listCommentsHandler: ListCommentsHandler = { _, _, _, _, _ in [] }
        var listCommentsCalls: [ListCommentsCall] = []
        var createCommentHandler: CreateCommentHandler = { _, _, _, _ in UUID() }
        var createCommentCalls: [CreateCommentCall] = []
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var listCommentsCalls: [ListCommentsCall] {
        box.withLock { $0.listCommentsCalls }
    }

    var createCommentCalls: [CreateCommentCall] {
        box.withLock { $0.createCommentCalls }
    }

    func setSetCommentDeletedHandler(_ handler: @escaping SetCommentDeletedHandler) {
        box.withLock { $0.setCommentDeletedHandler = handler }
    }

    func setListCommentsHandler(_ handler: @escaping ListCommentsHandler) {
        box.withLock { $0.listCommentsHandler = handler }
    }

    func setCreateCommentHandler(_ handler: @escaping CreateCommentHandler) {
        box.withLock { $0.createCommentHandler = handler }
    }

    func setCommentDeleted(commentID: UUID, deleted: Bool) async throws {
        let handler = box.withLock { $0.setCommentDeletedHandler }
        try await handler(commentID, deleted)
    }

    func listComments(
        familyID: UUID, targetType: String, targetID: UUID, cursor: CommentsCursor?, limit: Int
    ) async throws -> [CommentRecord] {
        let call = ListCommentsCall(
            familyID: familyID, targetType: targetType, targetID: targetID, cursor: cursor, limit: limit
        )
        box.withLock { $0.listCommentsCalls.append(call) }
        let handler = box.withLock { $0.listCommentsHandler }
        return try await handler(familyID, targetType, targetID, cursor, limit)
    }

    func createComment(familyID: UUID, targetType: String, targetID: UUID, body: String) async throws -> UUID {
        let call = CreateCommentCall(familyID: familyID, targetType: targetType, targetID: targetID, body: body)
        box.withLock { $0.createCommentCalls.append(call) }
        let handler = box.withLock { $0.createCommentHandler }
        return try await handler(familyID, targetType, targetID, body)
    }
}

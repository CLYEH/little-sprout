import Foundation
import Supabase

/// `CommentAPIClient` 的 Supabase 實作。方法 ↔ RPC 對照見協定檔的文件註解。
final class SupabaseCommentAPIClient: CommentAPIClient {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func setCommentDeleted(commentID: UUID, deleted: Bool) async throws {
        do {
            let params = SetCommentDeletedParams(commentID: commentID, deleted: deleted)
            try await client.rpc("set_comment_deleted", params: params).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func listComments(
        familyID: UUID, targetType: String, targetID: UUID, cursor: CommentsCursor?, limit: Int
    ) async throws -> [CommentRecord] {
        do {
            let params = ListCommentsParams(
                familyID: familyID, targetType: targetType, targetID: targetID,
                cursorCreatedAt: cursor.map { Self.iso8601String(from: $0.createdAt) }, cursorID: cursor?.id,
                limit: limit
            )
            let response: PostgrestResponse<[CommentRecord]> = try await client
                .rpc("list_comments", params: params)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func createComment(familyID: UUID, targetType: String, targetID: UUID, body: String) async throws -> UUID {
        do {
            let params = CreateCommentParams(familyID: familyID, targetType: targetType, targetID: targetID, body: body)
            let response: PostgrestResponse<UUID> = try await client
                .rpc("create_comment", params: params)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    /// 明確帶 'Z' 的 ISO8601 字串——同 `SupabaseTimelineAPIClient.iso8601String` 的理由：SDK
    /// 預設 Date 編碼不帶時區指示，Postgres 收到不帶時區的 timestamptz 字面值會依 session
    /// timezone 解讀，不保證是 UTC。
    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct SetCommentDeletedParams: Encodable {
    let commentID: UUID
    let deleted: Bool

    enum CodingKeys: String, CodingKey {
        case commentID = "p_comment_id"
        case deleted = "p_deleted"
    }
}

/// `list_comments` 的具名參數皆有 SQL 預設值（`docs/API.md` §4）——`Optional` 屬性為 `nil` 時
/// 合成的 `Encodable` 會用 `encodeIfPresent` 整個省略該 key，PostgREST 套用 SQL 預設，同
/// `SupabaseTimelineAPIClient.TimelineParams` 既有慣例。
private struct ListCommentsParams: Encodable {
    let familyID: UUID
    let targetType: String
    let targetID: UUID
    let cursorCreatedAt: String?
    let cursorID: UUID?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case familyID = "p_family_id"
        case targetType = "p_target_type"
        case targetID = "p_target_id"
        case cursorCreatedAt = "p_cursor_created_at"
        case cursorID = "p_cursor_id"
        case limit = "p_limit"
    }
}

private struct CreateCommentParams: Encodable {
    let familyID: UUID
    let targetType: String
    let targetID: UUID
    let body: String

    enum CodingKeys: String, CodingKey {
        case familyID = "p_family_id"
        case targetType = "p_target_type"
        case targetID = "p_target_id"
        case body = "p_body"
    }
}

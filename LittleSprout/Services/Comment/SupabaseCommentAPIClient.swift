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
}

private struct SetCommentDeletedParams: Encodable {
    let commentID: UUID
    let deleted: Bool

    enum CodingKeys: String, CodingKey {
        case commentID = "p_comment_id"
        case deleted = "p_deleted"
    }
}

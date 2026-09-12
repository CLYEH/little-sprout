#if DEBUG
import Foundation

/// 只給 `TapTargetGateHarness`／`#Preview` 用的假 `CommentAPIClient`——不打真網路（同
/// `PreviewDiaryAPIClient` 的角色，見該檔）。生產路徑一律用 `SupabaseCommentAPIClient`。
final class PreviewCommentAPIClient: CommentAPIClient, @unchecked Sendable {
    func setCommentDeleted(commentID: UUID, deleted: Bool) async throws {}

    /// LS-218：固定回傳空陣列——需要非空清單的 harness／`#Preview` 用
    /// `CommentsStore.seedForPreview`（見該檔），不靠這裡的假資料（同 `PreviewTimelineAPIClient
    /// .fetchTimelinePointers` 固定回 `[]`、需要種子資料的 host 改用 `TimelineStore
    /// .seedForPreview` 的既有分工）。
    func listComments(
        familyID: UUID, targetType: String, targetID: UUID, cursor: CommentsCursor?, limit: Int
    ) async throws -> [CommentRecord] { [] }

    func createComment(familyID: UUID, targetType: String, targetID: UUID, body: String) async throws -> UUID {
        UUID()
    }
}
#endif

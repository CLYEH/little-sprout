#if DEBUG
import Foundation

/// 只給 `TapTargetGateHarness`／`#Preview` 用的假 `CommentAPIClient`——不打真網路（同
/// `PreviewDiaryAPIClient` 的角色，見該檔）。生產路徑一律用 `SupabaseCommentAPIClient`。
final class PreviewCommentAPIClient: CommentAPIClient, @unchecked Sendable {
    func setCommentDeleted(commentID: UUID, deleted: Bool) async throws {}
}
#endif

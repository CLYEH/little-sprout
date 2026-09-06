import Foundation

/// 留言（`comments`）的型別化 client 介面——目前只有 LS-190（刪除留言確認，10b）需要的最小
/// 切片：`create_comment`／`update_comment`／讀取清單留給 LS-22（留言 UI 本體）落地時擴充，
/// 不在這裡預先造沒有呼叫端的方法（Rule 2：最小可用）。
///
/// 方法 ↔ RPC 對照（供 `docs/API.md` §4 對帳）：
///   - `setCommentDeleted` → RPC `set_comment_deleted(p_comment_id, p_deleted)`
///
/// 錯誤一律映射為 `AppError`，不直接往外拋 PostgREST 的 error 型別。
protocol CommentAPIClient: Sendable {
    /// 軟刪（`deleted: true`）／還原（`deleted: false`）。作者本人（仍是該家庭成員即可，
    /// 角色不拘）或該家庭 owner 皆可呼叫；見 `docs/API.md` §4 `set_comment_deleted`。
    func setCommentDeleted(commentID: UUID, deleted: Bool) async throws
}

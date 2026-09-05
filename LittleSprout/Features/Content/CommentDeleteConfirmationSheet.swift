import SwiftUI

/// LS-190（依 LS-152 稿 `Qs7iE`，沿用 LS-142 `w0NxC` 15c 語彙）：刪除留言確認——
/// `DeleteConfirmationSheet` 的留言變體，組好文案＋呼叫
/// `CommentAPIClient.setCommentDeleted(commentID:deleted:true)`。
///
/// **目前沒有真實可達的產品入口**：留言 UI 本體（LS-22）與內容操作表（LS-189）都尚未實作
/// （時間軸日記詳情頁的「留言」區目前只有一句「留言功能即將推出」佔位，見
/// `DiaryDetailView.commentsPlaceholder`）——本票依票文提供這個可呼叫的 View／API，供 LS-22／
/// LS-189 日後直接接上；`TapTargetGateHarness.deleteCommentConfirmationHost` 是唯一目前能
/// 觸達它的入口，供 gate／UITest 覆蓋（見該檔文件註解與 handoff 風險欄）。
struct CommentDeleteConfirmationSheet: View {
    let commentID: UUID
    let commentAPIClient: CommentAPIClient
    /// 呼叫端負責本地移除這則留言與導覽收尾——`DeleteConfirmationSheet` 本身只負責呼叫 RPC
    /// 與關閉自己這張 sheet（同 `DiaryDeleteConfirmationSheet` 的分工）。
    let onDeleted: () -> Void

    var body: some View {
        DeleteConfirmationSheet(
            headTitle: "要刪除這則留言嗎？",
            bodyText: "這則留言刪除後，家人就看不到了。這個動作目前無法在 App 內復原。",
            confirmLabel: "刪除這則留言",
            confirmAction: {
                try await commentAPIClient.setCommentDeleted(commentID: commentID, deleted: true)
                onDeleted()
            }
        )
    }
}

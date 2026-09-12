import SwiftUI

/// LS-190（依 LS-152 稿 `Qs7iE`，沿用 LS-142 `w0NxC` 15c 語彙）：刪除留言確認——
/// `DeleteConfirmationSheet` 的留言變體，組好文案＋呼叫
/// `CommentAPIClient.setCommentDeleted(commentID:deleted:true)`。
///
/// 真實產品入口：`CommentsSheetView+Actions.swift` 留言列操作表的「刪除」（LS-218，日記詳情頁
/// 與時間軸卡片皆共用同一顆 `CommentsSheetView`，見 `DiaryDetailView` 文件註解 LS-241）；
/// `TapTargetGateHarness.deleteCommentConfirmationHost` 另外提供一個不依賴留言清單種子資料、
/// gate／UITest 可直接覆蓋的固定入口。
struct CommentDeleteConfirmationSheet: View {
    let commentID: UUID
    let commentAPIClient: CommentAPIClient
    /// RPC 成功、sheet 已關閉之後呼叫——本地移除與導覽收尾由呼叫端負責，順序保證見
    /// `DeleteConfirmationSheet.onSuccess` 文件註解（同 `DiaryDeleteConfirmationSheet` 的
    /// 分工）。
    var onDeleted: () -> Void = {}

    var body: some View {
        DeleteConfirmationSheet(
            headTitle: "要刪除這則留言嗎？",
            bodyText: "這則留言刪除後，家人就看不到了。這個動作目前無法在 App 內復原。",
            confirmLabel: "刪除這則留言",
            confirmAction: { try await commentAPIClient.setCommentDeleted(commentID: commentID, deleted: true) },
            onSuccess: onDeleted
        )
    }
}

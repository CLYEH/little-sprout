import SwiftUI

/// LS-190（依 LS-152 稿 `oFRMc`）：刪除日記確認——`DeleteConfirmationSheet` 的日記變體，組好
/// 文案＋呼叫 `DiaryAPIClient.setDiaryDeleted(diaryID:deleted:true)`。
///
/// 目前唯一呼叫端是 `DiaryDetailView` 的最小可達入口（票文「入口由內容操作表票（LS-189）接」
/// ——本票只提供這個可呼叫的 View，日後 LS-189 的內容操作表可以直接改叫這裡，不需要重寫）。
struct DiaryDeleteConfirmationSheet: View {
    let diaryID: UUID
    let diaryBody: String
    let diaryAPIClient: DiaryAPIClient
    /// 呼叫端負責本地移除這篇（例如 `TimelineStore.removeDiaryEntryLocally`）與導覽收尾（例如
    /// pop 回時間軸）——`DeleteConfirmationSheet` 本身只負責呼叫 RPC 與關閉自己這張 sheet。
    let onDeleted: () -> Void

    var body: some View {
        DeleteConfirmationSheet(
            headTitle: DiaryDeleteConfirmationCopy.title(forBody: diaryBody),
            bodyText: "這篇日記會從時間軸移除，家人也看不到；裡面附的照片不會被刪除，之後還能在相簿看到。這個動作目前無法在 App 內復原。",
            confirmLabel: "刪除這篇日記",
            confirmAction: {
                try await diaryAPIClient.setDiaryDeleted(diaryID: diaryID, deleted: true)
                onDeleted()
            }
        )
    }
}

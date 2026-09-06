import SwiftUI

/// LS-190（依 LS-152 稿 `oFRMc`）：刪除日記確認——`DeleteConfirmationSheet` 的日記變體，組好
/// 文案＋呼叫 `DiaryAPIClient.setDiaryDeleted(diaryID:deleted:true)`。
///
/// **目前沒有真實可達的產品入口**（LS-190 R2，merge-review R1 M1）：稿面 `vzYXz`（日記詳情）
/// 沒有畫任何操作列，票文明寫「入口由內容操作表票（LS-189）接」——R1 版在 `DiaryDetailView`
/// 常駐插了一顆紅色「刪除日記」列，且不判斷呼叫者是不是作者／owner（`set_diary_deleted` 對
/// 其他成員回 `42501`，UI 只會顯示通用「無法完成這個操作」，使用者不知道自己本來就沒有這個
/// 權限），與留言變體（一開始就只掛 harness）不一致，reviewer 裁定收回。真正的入口與身分
/// 判斷（依 LS-152 Notes `VAij1` 的既有裁決：操作入口本來就該依角色隱藏，不該讓使用者走到
/// 權限錯誤）留給 LS-189；`TimelineStore.removeDiaryEntryLocally`／`DiaryAPIClient.
/// setDiaryDeleted` 兩個底層方法已就緒，LS-189 落地時直接呼叫，不需要改。
/// `TapTargetGateHarness.deleteDiaryConfirmationHost` 是目前唯一能觸達它的入口，同
/// `CommentDeleteConfirmationSheet` 的既有理由。
struct DiaryDeleteConfirmationSheet: View {
    let diaryID: UUID
    let diaryBody: String
    let diaryAPIClient: DiaryAPIClient
    /// RPC 成功、sheet 已關閉之後呼叫——本地移除（例如 `TimelineStore.
    /// removeDiaryEntryLocally`）與導覽收尾（例如 pop 回時間軸）由呼叫端負責，順序保證見
    /// `DeleteConfirmationSheet.onSuccess` 文件註解。
    var onDeleted: () -> Void = {}

    var body: some View {
        DeleteConfirmationSheet(
            headTitle: DiaryDeleteConfirmationCopy.title(forBody: diaryBody),
            bodyText: "這篇日記會從時間軸移除，家人也看不到；裡面附的照片不會被刪除，之後還能在相簿看到。這個動作目前無法在 App 內復原。",
            confirmLabel: "刪除這篇日記",
            confirmAction: { try await diaryAPIClient.setDiaryDeleted(diaryID: diaryID, deleted: true) },
            onSuccess: onDeleted
        )
    }
}

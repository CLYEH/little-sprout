import SwiftUI

/// 刪除相簿確認（LS-166 票文範圍 2，`design/littlesprout.pen` `LS-142 / 15c 刪除相簿 · 確認
/// （Owner）`／`w0NxC`）——`DeleteConfirmationSheet` 的相簿變體，同 `DiaryDeleteConfirmationSheet`
/// 的既有分工：組好文案＋呼叫 `AlbumsAPIClient.setAlbumDeleted(albumID:deleted:true)`。
///
/// **不承諾 30 天可還原**（票文明文裁決，依 LS-152 Notes IN-1）：`w0NxC` 稿面文字「刪除，30
/// 天內可還原」與內文「30 天內你可以把它還原回來；過了 30 天，就不能再還原了」**不採用**——
/// `docs/API.md` §4 `set_album_deleted` 雖然是軟刪（DB 層資料還在），但 app 內沒有任何還原
/// 入口（同 `DeleteConfirmationSheet` 服務的日記／留言兩個既有變體），對使用者講「30 天可
/// 還原」是講了一個做不到的承諾。文案改沿用 `DeleteConfirmationSheet` 既有慣例的「這個動作
/// 目前無法在 App 內復原」收尾，「相片不會被刪除」這句稿面原意（只刪相簿列，不動 `media`／
/// `album_media`）仍保留。
struct AlbumDeleteConfirmationSheet: View {
    let albumID: UUID
    let albumTitle: String
    let apiClient: AlbumsAPIClient
    /// RPC 成功、sheet 已關閉之後呼叫——本地移除／導覽收尾（pop 回相簿列表）由呼叫端負責，
    /// 順序保證見 `DeleteConfirmationSheet.onSuccess` 文件註解。
    var onDeleted: () -> Void = {}

    var body: some View {
        DeleteConfirmationSheet(
            headTitle: "要刪除「\(albumTitle)」相簿嗎？",
            bodyText: "這本相簿會從相簿列表移除；裡面的照片不會被刪除，之後還能在時間軸看到。這個動作目前無法在 App 內復原。",
            confirmLabel: "刪除相簿",
            confirmAction: { try await apiClient.setAlbumDeleted(albumID: albumID, deleted: true) },
            onSuccess: onDeleted
        )
    }
}

#if DEBUG
#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        AlbumDeleteConfirmationSheet(
            albumID: UUID(), albumTitle: "阿公阿嬤家過年", apiClient: AlbumsStore.preview().apiClient
        )
    }
}
#endif

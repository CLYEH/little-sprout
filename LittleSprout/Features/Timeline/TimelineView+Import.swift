import SwiftUI

/// LS-315：Header「匯入」鈕——抽到獨立檔案（同 `TimelineView+Comments.swift` 既有先例：
/// `TimelineView.swift` 本體已經有卡片流／篩選／分頁三段邏輯，疊上這顆會超過 SwiftLint
/// `file_length`）。
extension TimelineView {
    /// Header「匯入」鈕（`ImportEntryButton`，`cmp/Button Import` `o8zYlX`）——沿
    /// `ImportEntrySource.timeline`（C3a：任何入口預設不放相簿）接上 LS-303 既有 PHPicker
    /// 流程，見型別文件註解「LS-315」段。三處 timeline instance 統一
    /// `accessibilityIdentifier`（Notes `MCbLu`：避免各自發明不同字串）。
    var importEntryButton: some View {
        ImportEntryButton(label: "匯入") {
            showsImportBatch = true
            // merge-review R2 M2：時間軸這條路徑上沒有任何人載過相簿清單（唯一填值來源
            // `AlbumsStore.refresh`／`loadMore` 只有 `AlbumsView` 呼叫）——冷啟動直接停在
            // 時間軸、沒逛過相簿 tab 就點「匯入」，整理頁每群的相簿選單只剩「不放相簿」。
            // `albums.isEmpty` 守門避免每次點擊都重打一次 RPC；`@Observable` 讓晚到的清單
            // 自動更新整理頁選單，不需要額外訂閱。
            if albumsStore.albums.isEmpty, let familyID = familyStore.myFamily?.id {
                Task { await albumsStore.refresh(familyID: familyID) }
            }
        }
        .accessibilityIdentifier(QAAccessibilityID.timelineImportPhotos)
    }
}

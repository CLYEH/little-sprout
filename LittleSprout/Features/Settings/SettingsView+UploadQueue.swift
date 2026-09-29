import SwiftUI

/// LS-404：上傳佇列入口列的掛載點（LS-397 暫定的「內容與安全」末列已移除）——列本體、四態、狀態機見
/// `UploadQueueEntryCard.swift`／`UploadQueueEntryPresentation.swift`；iPhone 放在 `compactBody` Content
/// 第一段，iPad 放在 `sidebar` 標題與 Nav List 之間（Notes `OT5n9`）。整棵沒有佇列（或目前態為隱藏）時
/// 不輸出任何視圖，也不佔 `VStack` 的間距。
extension SettingsView {
    @ViewBuilder
    var uploadQueueEntryCard: some View {
        if let store = albumsStore.sharedUploadQueueStoreInstance, uploadQueueEntry.state.phase != nil {
            UploadQueueEntryCard(store: store, model: uploadQueueEntry)
        }
    }
}

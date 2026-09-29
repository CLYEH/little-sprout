import SwiftUI

/// LS-397：上傳佇列 sheet（`UploadQueueSheetView`，LS-142 `16 上傳佇列`）的**暫定**正式入口。
///
/// LS-142 Notes（`cn84r`）只定義了「PhotosPicker 選完照片後彈出」這一條進入路徑，而那條路徑
/// 已被批次匯入（LS-249／LS-304 的 04 進度頁）取代；使用者按「在背景繼續」離開後，稿面沒有任何
/// 地方能回看未完成／失敗項。沒有設計稿就不自己設計新畫面——這裡只在既有「內容與安全」卡片
/// 末尾以既有 `SettingsRowView` 樣式加一列，開啟既有的 sheet，**待設計票定案正式入口**
/// （相簿頁 pill 之類）。只在還有未完成項時才出現，全部完成後自然消失，不需要空狀態版面；
/// sheet 開著時列保留（`|| showsUploadQueue`），否則最後一張傳完的瞬間列消失、sheet 跟著被收掉。
extension SettingsView {
    @ViewBuilder
    var uploadQueueRow: some View {
        if let store = albumsStore.sharedUploadQueueStoreInstance, store.remainingCount > 0 || showsUploadQueue {
            SettingsRowDivider()
            Button {
                showsUploadQueue = true
            } label: {
                SettingsRowView(
                    icon: "arrow.up.circle", label: "上傳進度", value: "還有 \(store.remainingCount) 張還沒完成"
                )
            }
            .accessibilityIdentifier(QAAccessibilityID.settingsUploadQueueRow)
            .sheet(isPresented: $showsUploadQueue) {
                UploadQueueSheetView(store: store, onViewStorage: {
                    showsUploadQueue = false
                    showsStorageFromUploadQueue = true
                })
            }
            .navigationDestination(isPresented: $showsStorageFromUploadQueue) {
                StorageUsageView(familyStore: familyStore)
            }
        }
    }
}

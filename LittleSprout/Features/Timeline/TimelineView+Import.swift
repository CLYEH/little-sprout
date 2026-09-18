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
            // R3（merge-review R2 m1／m2）：守門邏輯下沉到 `AlbumsStore.refreshIfEmpty(familyID:)`
            // （空且非 in-flight 才打）——`@Observable` 讓晚到的清單自動更新整理頁選單，不需要
            // 額外訂閱。
            if let familyID = familyStore.myFamily?.id {
                Task { await albumsStore.refreshIfEmpty(familyID: familyID) }
            }
        }
        .accessibilityIdentifier(QAAccessibilityID.timelineImportPhotos)
    }

    /// R3（merge-review R2 M1）：`.importBatchFlow` 的 `uploadCoordinator` 引數解析——抽出成
    /// 純函式，讓「NoOp 只在 `importUploadCoordinator` 還沒建立好之前當保底」這件事可以用
    /// 型別斷言驗證（`TimelineImportUploadCoordinatorTests`），不必靠原始碼字串比對（同
    /// `TimelineImportAlbumsRegressionTests` 被拿掉的理由——這裡一開始就換成能做到行為測試
    /// 的寫法，不重蹈那支測試的弱點）。
    static func resolveUploadCoordinator(_ real: AlbumImportUploadCoordinator?) -> ImportUploadCoordinator {
        real ?? NoOpImportUploadCoordinator()
    }

    /// `.task(id: familyStore.myFamily?.id)` 用（`TimelineView.swift`）——把 R3 新增的
    /// coordinator 建立塞進既有的那顆 `.task`，不另外疊一個（同一個 familyID 只需要跑一次）。
    /// guard 同 `AlbumDetailView.loadDetailStoreIfNeeded()` 既有寫法，避免同一個家庭時反覆
    /// 重建（`TimelineView` 是 tab-root，跟 `AlbumDetailView` 每次進場才建立一次不同壽命）。
    func refreshChildrenAndEnsureImportCoordinator(familyID: UUID) async {
        if importUploadCoordinator == nil {
            importUploadCoordinator = AlbumImportUploadCoordinator(
                familyID: familyID, mediaUploadService: mediaUploadService, albumsStore: albumsStore
            )
        }
        await childrenStore.refresh(familyID: familyID)
    }
}

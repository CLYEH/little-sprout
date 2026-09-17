import Foundation

/// LS-304：相機膠卷批次匯入「取消匯入」（04b 確認後）的清理——拆成獨立檔案，理由同
/// `UploadQueueStore+VideoExportSlot.swift` 檔頭：主檔 `UploadQueueStore.swift` 逼近
/// SwiftLint `file_length` 上限，這裡的方法會再加行數，才觸發拆檔。`entries`／`order`／
/// `compressedVideoCache`／`onUploadFailedTerminal`／`advance()`／`cleanupVideoTempFiles(_:_:)`
/// 因此不能是 `private`（同主檔文件註解）。
extension UploadQueueStore {
    /// 匯入進度頁「取消匯入」（04b 確認後）——移除還沒有終局完成（`.waiting`／`.uploading`／
    /// `.failed`）的批次項目，讓佇列的計數與畫面立刻反映「這些不會匯入」。
    ///
    /// **已知限制（不含真正的網路層級取消）**：`start(_:)` 建立的 `Task` 沒有保留參照可以
    /// `cancel()`（同檔頭「已知限制」段既有先例）——`.uploading` 這一筆背景仍可能繼續把
    /// 位元組送完並在 `media` 留一列，這裡只是讓它從本地簿記與畫面上消失；因此對 `.uploading`
    /// 項目**不**釋放 payload／清暫存檔（那個仍在飛行中的 `Task` 之後自己會做），只有
    /// `.waiting`／`.failed`（皆非飛行中）才在移除前做同 `finish(_:state:)` 終局清理那套
    /// payload／暫存檔釋放。`onUploadFailedTerminal` 對每一筆都照樣呼叫，讓呼叫端
    /// （`AlbumsStore`）解除相簿登記——即使 `.uploading` 那筆背景真的傳完，`onUploadSucceeded`
    /// 查表也會落空，不會被誤掛進相簿（見該屬性文件註解）。回傳實際移除的筆數。
    @discardableResult
    func cancelPendingImportItems(_ ids: Set<UUID>) -> Int {
        var removedCount = 0
        for id in ids {
            guard let entry = entries[id] else { continue }
            switch entry.state {
            case .completed:
                continue
            case .uploading:
                break
            case .waiting, .failed:
                if case .video(let fileURL, _)? = entry.payload {
                    let uploadedURL = compressedVideoCache[id]?.fileURL ?? fileURL
                    Self.cleanupVideoTempFiles(originalURL: fileURL, uploadedURL: uploadedURL)
                }
                compressedVideoCache.removeValue(forKey: id)
            }
            entries.removeValue(forKey: id)
            order.removeAll { $0 == id }
            onUploadFailedTerminal(id)
            removedCount += 1
        }
        advance()
        return removedCount
    }
}

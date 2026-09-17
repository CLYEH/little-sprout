import Foundation

/// LS-304：相機膠卷批次匯入「取消匯入」（04b 確認後）與「摘要頁離開」的清理——拆成獨立檔案，
/// 理由同 `UploadQueueStore+VideoExportSlot.swift` 檔頭：主檔 `UploadQueueStore.swift` 逼近
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

    /// merge-review R1 M3(c)：批次匯入摘要頁（05）「回到時間軸」離開時呼叫——這個批次已經
    /// 到終局狀態（完成／不可重試失敗）的項目不再需要顯示縮圖影像（畫面已經離開，使用者已經
    /// 在 05 看過一次），200 張批次的縮圖常駐到登出成本可觀（見 `Entry.thumbnail` 型別文件
    /// 註解估算，LS-96 池項 `a997f824`(2) 同一批記錄）。
    ///
    /// **只清縮圖，不移除整個 entry**：完成／終局失敗的列仍留在 `entries`／`order`，供
    /// `UploadQueueSheetView`（「加入照片」單張即傳的歷史列表）與這個批次自己顯示狀態文字
    /// ／時間戳——只是縮圖影像本身變成系統色塊佔位（同 `UploadQueueRowView.thumbnailView`
    /// 既有的 nil-thumbnail 退回邏輯，不是新分支）。真正的「entry 整筆移除」（LS-96 池項
    /// `ad900f14`(1) 的完整方案）需要先確認這樣做不會讓 `UploadQueueSheetView` 的歷史列表
    /// 少東西，範圍更大，本輪不做，見 handoff。
    ///
    /// 可重試失敗（`.failed` 且 `reason.isRetryable`）不清——使用者可能還會按「重試失敗項」，
    /// 縮圖仍需要顯示；`.waiting`／`.uploading` 同樣不清（還沒到終局）。
    func releaseThumbnails(for ids: Set<UUID>) {
        for id in ids {
            switch entries[id]?.state {
            case .completed:
                entries[id]?.thumbnail = nil
            case .failed(let reason) where !reason.isRetryable:
                entries[id]?.thumbnail = nil
            default:
                continue
            }
        }
    }
}
